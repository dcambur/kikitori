/// The script injected into the built-in player's page (YouTube, Twitch, any page with a
/// <video>). It runs in the page's own world so it can use the site's player.
///
/// - Audio is NOT taken here: WebKit gives Web Audio silence for cross-origin video (YouTube
///   streams from googlevideo.com) and a routed element goes quiet. The app taps its own WebKit
///   process instead (`AudioSources.ownWebKitProcesses`).
/// - State: `kkState` every 500 ms (time, paused, rate, live, title, url).
/// - Subtitles: `__kikitori.show(lines)` draws them in a layer inside the player element, so
///   they follow theatre mode and full screen.
enum PlayerScript {
    static let source = """
        (() => {
        if (window.__kikitori) return;
        const kk = window.__kikitori = {};
        const post = (name, body) => { try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {} };
        const video = () => document.querySelector('video.html5-main-video') || document.querySelector('video');
        const playerBox = v => v.closest('#movie_player') || v.closest('.html5-video-player')
            || v.closest('[data-a-target="video-player"]') || v.parentElement;

        const log = m => post('kkLog', String(m));

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
