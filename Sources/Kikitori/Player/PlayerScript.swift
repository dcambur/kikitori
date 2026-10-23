/// The script injected into the built-in player's page (YouTube, Twitch, any page with a
/// <video>). It runs in the page's own world so it can use the site's player.
///
/// - Audio: the video element is routed through Web Audio; a ScriptProcessor mixes to mono,
///   resamples to 16 kHz and posts base64 Int16 packets (~100 ms) to `kkAudio`, each with the
///   video time. `hear: false` (the lookahead player) keeps the audio away from the speakers.
/// - State: `kkState` every 500 ms (time, paused, rate, live, title, url).
/// - Subtitles: `__kikitori.show(lines)` draws them in a layer inside the player element, so
///   they follow theatre mode and full screen.
enum PlayerScript {
    static func source(hear: Bool) -> String {
        """
        (() => {
        if (window.__kikitori) return;
        const HEAR = \(hear ? "true" : "false");
        const kk = window.__kikitori = {};
        const post = (name, body) => { try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {} };
        const video = () => document.querySelector('video.html5-main-video') || document.querySelector('video');
        const playerBox = v => v.closest('#movie_player') || v.closest('.html5-video-player')
            || v.closest('[data-a-target="video-player"]') || v.parentElement;

        // ---- audio -------------------------------------------------------------
        let ctx = null, pending = [], attached = new WeakSet(), ratio = 3;
        function attach(v) {
          if (attached.has(v)) return;
          attached.add(v);
          ctx = ctx || new AudioContext();
          ratio = ctx.sampleRate / 16000;
          const src = ctx.createMediaElementSource(v);
          if (HEAR) src.connect(ctx.destination);
          const proc = ctx.createScriptProcessor(4096, 2, 1);
          const mute = ctx.createGain(); mute.gain.value = 0;
          src.connect(proc); proc.connect(mute); mute.connect(ctx.destination);
          let carry = 0;
          proc.onaudioprocess = e => {
            if (v.paused) return;
            const ch = e.inputBuffer.numberOfChannels;
            const a = e.inputBuffer.getChannelData(0), b = ch > 1 ? e.inputBuffer.getChannelData(1) : a;
            for (let pos = carry; pos < a.length; pos += ratio) {
              const i = Math.floor(pos);
              pending.push((a[i] + b[i]) / 2);
            }
            carry = (carry + Math.ceil((a.length - carry) / ratio) * ratio) - a.length;
            if (pending.length >= 1600) {
              const pcm = new Int16Array(pending.length);
              for (let i = 0; i < pending.length; i++) pcm[i] = Math.max(-1, Math.min(1, pending[i])) * 32767;
              let bin = ''; const bytes = new Uint8Array(pcm.buffer);
              for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
              post('kkAudio', { pcm: btoa(bin), t: v.currentTime });
              pending = [];
            }
          };
        }
        document.addEventListener('play', e => {
          if (e.target instanceof HTMLVideoElement) { attach(e.target); if (ctx && ctx.state !== 'running') ctx.resume(); }
        }, true);

        // ---- state -------------------------------------------------------------
        setInterval(() => {
          const v = video();
          const live = !!document.querySelector('.ytp-live') || !!document.querySelector('[data-a-target="player-live-indicator"]');
          post('kkState', { t: v ? v.currentTime : -1, paused: v ? v.paused : true, rate: v ? v.playbackRate : 1,
                            live, title: document.title, url: location.href, hasVideo: !!v });
        }, 500);

        // ---- subtitles ---------------------------------------------------------
        const style = document.createElement('style');
        style.textContent = `
          #kikitori-subs { position: absolute; left: 0; right: 0; bottom: 9%; z-index: 60; pointer-events: none;
                           display: flex; flex-direction: column; align-items: center; gap: 4px; }
          #kikitori-subs .kk-line { max-width: 86%; padding: 3px 14px 5px; border-radius: 10px; text-align: center;
                           background: rgba(16,16,22,.72); color: #fff; }
          #kikitori-subs .kk-line.old { opacity: .62; }
          #kikitori-subs .kk-main { font: 600 clamp(15px, 2.4vw, 34px)/1.3 "Hiragino Sans", -apple-system, sans-serif; }
          #kikitori-subs .kk-sub  { font: 500 clamp(11px, 1.45vw, 20px)/1.3 -apple-system, "Hiragino Sans", sans-serif;
                                    color: rgba(255,255,255,.82); }
          #kikitori-subs .kk-note { pointer-events: auto; cursor: pointer; margin-left: 8px; padding: 0 5px; border-radius: 5px;
                                    font: 700 .8em -apple-system; color: #FFCB7A; background: rgba(255,190,90,.24); }
          #kikitori-subs .kk-dots::after { content: '…'; opacity: .7; }
        `;
        document.documentElement.appendChild(style);
        let layer = null;
        function ensureLayer() {
          const v = video(); if (!v) return null;
          const box = playerBox(v);
          if (!layer) { layer = document.createElement('div'); layer.id = 'kikitori-subs'; }
          if (layer.parentElement !== box) { box.appendChild(layer); if (getComputedStyle(box).position === 'static') box.style.position = 'relative'; }
          return layer;
        }
        const esc = s => (s || '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
        // lines: [{id, ja, en, note, term, pending}], mode: japaneseMain | englishMain | englishOnly | japaneseOnly
        kk.show = (lines, mode) => {
          const l = ensureLayer(); if (!l) return;
          l.innerHTML = lines.map((x, i) => {
            const old = i < lines.length - 1 ? ' old' : '';
            const note = x.term ? `<span class="kk-note" data-id="${esc(x.id)}">注</span>` : '';
            const en = x.en ? esc(x.en) : (x.pending ? '<span class="kk-dots"></span>' : '');
            const ja = esc(x.ja);
            let main, sub;
            switch (mode) {
              case 'englishOnly':  main = en || ja; sub = ''; break;
              case 'japaneseOnly': main = ja; sub = ''; break;
              case 'englishMain':  main = en || ja; sub = x.en ? ja : ''; break;
              default:             main = ja; sub = en;
            }
            return `<div class="kk-line${old}"><div class="kk-main">${main}${note}</div>${sub ? `<div class="kk-sub">${sub}</div>` : ''}</div>`;
          }).join('');
        };
        document.addEventListener('click', e => {
          const t = e.target.closest && e.target.closest('#kikitori-subs .kk-note');
          if (t) { e.stopPropagation(); e.preventDefault(); post('kkExplain', { id: t.dataset.id }); }
        }, true);
        })();
        """
    }
}
