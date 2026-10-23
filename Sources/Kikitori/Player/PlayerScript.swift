/// The script injected into the built-in player's page (YouTube, Twitch, any page with a
/// <video>). It runs in the page's own world so it can use the site's player.
///
/// - Audio is NOT taken here: WebKit gives Web Audio silence for cross-origin video (YouTube
///   streams from googlevideo.com) and a routed element goes quiet. The app taps its own WebKit
///   process instead (`AudioSources.ownWebKitProcesses`).
/// - State: `kkState` every 500 ms (time, paused, rate, live, title, url).
/// - Subtitles: `__kikitori.show(lines)` draws them in a layer inside the player element (so they
///   follow theatre mode, the miniplayer and full screen), bottom-centre on the picture itself.
///   Built with DOM calls, never HTML strings: YouTube requires Trusted Types, so assigning
///   `innerHTML` throws and the layer would stay empty.
enum PlayerScript {
    static let source = """
        (() => {
        if (window.__kikitori) return;
        const kk = window.__kikitori = {};
        const post = (name, body) => { try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {} };
        // The watch page's player first: YouTube's home feed has inline previews with the same class.
        const video = () => document.querySelector('#movie_player video') || document.querySelector('video.html5-main-video')
            || document.querySelector('video');
        const playerBox = v => v.closest('#movie_player') || v.closest('.html5-video-player')
            || v.closest('[data-a-target="video-player"]') || v.parentElement;

        const log = m => post('kkLog', String(m));

        // ---- state -------------------------------------------------------------
        setInterval(() => {
          const v = video();
          const live = !!document.querySelector('.ytp-live') || !!document.querySelector('[data-a-target="player-live-indicator"]');
          post('kkState', { t: v ? v.currentTime : -1, paused: v ? v.paused : true, rate: v ? v.playbackRate : 1,
                            live, title: document.title, url: location.href, hasVideo: !!v });
          // Lines pushed while there was no video (a search page, a video still loading) or before
          // the site rebuilt its player are drawn as soon as the player is there.
          if (lastShow) { const v = video(); if (v && (!layer || layer.parentElement !== playerBox(v))) kk.show(...lastShow); }
          place();
        }, 500);

        // ---- subtitles ---------------------------------------------------------
        // Sizes are in cqw: a percentage of the layer, which is as wide as the picture.
        const style = document.createElement('style');
        style.textContent = `
          #kikitori-subs { position: absolute; left: 0; right: 0; bottom: 9%; z-index: 60; pointer-events: none;
                           container-type: inline-size; display: flex; flex-direction: column; align-items: center;
                           gap: 4px; transition: bottom .15s ease-out; }
          #kikitori-subs .kk-line { max-width: 86%; padding: 3px 14px 5px; border-radius: 10px; text-align: center;
                           background: rgba(16,16,22,.72); color: #fff; }
          #kikitori-subs .kk-line.old { opacity: .62; }
          #kikitori-subs .kk-main { font: 600 clamp(14px, 3.4cqw, 40px)/1.3 "Hiragino Sans", -apple-system, sans-serif; }
          #kikitori-subs .kk-sub  { font: 500 clamp(11px, 2.1cqw, 24px)/1.3 -apple-system, "Hiragino Sans", sans-serif;
                                    color: rgba(255,255,255,.82); }
          #kikitori-subs .kk-note { pointer-events: auto; cursor: pointer; margin-left: 8px; padding: 0 5px; border-radius: 5px;
                                    font: 700 .8em -apple-system; color: #FFCB7A; background: rgba(255,190,90,.24); }
          #kikitori-subs .kk-dots::after { content: '…'; opacity: .7; }
        `;
        document.documentElement.appendChild(style);

        let layer = null, watched = null, lastShow = null;
        const resized = new ResizeObserver(() => place());
        const classes = new MutationObserver(() => place());   // YouTube's control bar showing or hiding
        function ensureLayer() {
          const v = video(); if (!v) return null;
          const box = playerBox(v);
          if (!layer) { layer = document.createElement('div'); layer.id = 'kikitori-subs'; }
          if (layer.parentElement !== box) { box.appendChild(layer); if (getComputedStyle(box).position === 'static') box.style.position = 'relative'; }
          if (watched !== v) {
            resized.disconnect(); resized.observe(v); resized.observe(box);
            classes.disconnect(); classes.observe(box, { attributes: true, attributeFilter: ['class'] });
            watched = v;
          }
          return layer;
        }

        // Fit the layer to the picture: the video element's box, minus letterboxing when the
        // picture is contained in it, with the lines' bottom 8 % of its height above its bottom edge,
        // and above YouTube's control bar while it shows. Until the picture has a size, the CSS
        // default (the player's full width) applies.
        function place() {
          const v = video();
          if (!layer || !v || !layer.parentElement || !layer.firstChild) return;
          const box = layer.parentElement;
          const vb = v.getBoundingClientRect(), bb = box.getBoundingClientRect();
          if (vb.width < 2 || vb.height < 2) return;
          let w = vb.width, h = vb.height;
          const fit = getComputedStyle(v).objectFit;
          if ((fit === 'contain' || fit === 'scale-down') && v.videoWidth && v.videoHeight) {
            const s = Math.min(vb.width / v.videoWidth, vb.height / v.videoHeight);
            w = v.videoWidth * s; h = v.videoHeight * s;
          }
          const left = vb.left - bb.left - box.clientLeft + (vb.width - w) / 2;
          const bottom = vb.top - bb.top - box.clientTop + (vb.height + h) / 2;
          let gap = box.clientHeight - bottom + h * 0.08;
          const bar = box.querySelector('.ytp-chrome-bottom');
          if (bar && !box.classList.contains('ytp-autohide')) {
            const r = bar.getBoundingClientRect();
            if (r.height) gap = Math.max(gap, bb.bottom - r.top + 6);
          }
          layer.style.left = left + 'px';
          layer.style.right = 'auto';
          layer.style.width = w + 'px';
          layer.style.bottom = gap + 'px';
        }
        window.addEventListener('resize', place);
        document.addEventListener('fullscreenchange', place);
        document.addEventListener('webkitfullscreenchange', place);

        const el = (tag, cls, text) => {
          const e = document.createElement(tag);
          if (cls) e.className = cls;
          if (text) e.textContent = text;
          return e;
        };
        // lines: [{id, ja, en, term, pending}], mode: japaneseMain | englishMain | englishOnly | japaneseOnly
        kk.show = (lines, mode) => {
          lastShow = lines.length ? [lines, mode] : null;
          try {
            const l = ensureLayer(); if (!l) return;
            l.replaceChildren(...lines.map((x, i) => {
              // English, or dots while it is on its way, or nothing.
              const en = () => x.en ? el('span', null, x.en) : (x.pending ? el('span', 'kk-dots') : null);
              const ja = () => el('span', null, x.ja);
              let main, sub = null;
              switch (mode) {
                case 'englishOnly':  main = en() || ja(); break;
                case 'japaneseOnly': main = ja(); break;
                case 'englishMain':  main = en() || ja(); if (x.en) sub = ja(); break;
                default:             main = ja(); sub = en();
              }
              const row = el('div', 'kk-line' + (i < lines.length - 1 ? ' old' : ''));
              const top = el('div', 'kk-main');
              top.append(main);
              if (x.term) { const chip = el('span', 'kk-note', '注'); chip.dataset.id = x.id; top.append(chip); }
              row.append(top);
              if (sub) { const below = el('div', 'kk-sub'); below.append(sub); row.append(below); }
              return row;
            }));
            place();
          } catch (e) { log('show failed: ' + e); }
        };
        document.addEventListener('click', e => {
          const t = e.target.closest && e.target.closest('#kikitori-subs .kk-note');
          if (t) { e.stopPropagation(); e.preventDefault(); post('kkExplain', { id: t.dataset.id }); }
        }, true);
        })();
        """
}
