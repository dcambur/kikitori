/// The script injected into the built-in player's page (YouTube, Twitch, any page with a
/// <video>). It runs in the page's own world so it can use the site's player.
///
/// - Audio is NOT taken here: WebKit gives Web Audio silence for cross-origin video (YouTube
///   streams from googlevideo.com) and a routed element goes quiet. The app taps its own WebKit
///   process instead (`AudioSources.ownWebKitProcesses`).
/// - State: `kkState` every 500 ms (time, paused, rate, live, title, url, channel).
/// - Audio track: YouTube may play an AI dub in the viewer's language (auto-dubbing); once per
///   video, an auto-dubbed track is switched to the original, so we hear the streamers themselves.
/// - Subtitles: `__kikitori.show(lines, live)` draws the Japanese as heard (the newest lines, then
///   the words still being heard) in a layer inside the player element (so they follow theatre
///   mode, the miniplayer and full screen), bottom-centre on the picture itself.
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
        const channel = () => {
          const a = document.querySelector('ytd-watch-metadata ytd-channel-name a, #owner #channel-name a, [data-a-target="stream-title"] ~ * a');
          return a ? a.textContent.trim() : '';
        };

        // ---- state -------------------------------------------------------------
        setInterval(() => {
          const v = video();
          const live = !!document.querySelector('.ytp-live') || !!document.querySelector('[data-a-target="player-live-indicator"]');
          post('kkState', { t: v ? v.currentTime : -1, paused: v ? v.paused : true, rate: v ? v.playbackRate : 1,
                            live, title: document.title, url: location.href, hasVideo: !!v, channel: channel() });
          // Lines pushed while there was no video (a search page, a video still loading) or before
          // the site rebuilt its player are drawn as soon as the player is there.
          if (lastShow) { const v = video(); if (v && (!layer || layer.parentElement !== playerBox(v))) kk.show(...lastShow); }
          place();
          keepOriginalAudio();
        }, 500);

        // ---- audio track ---------------------------------------------------------
        // YouTube's player marks the original track with an id ending in ".4" (e.g. "ja.4"); dubs
        // say isAutoDubbed(). Decided once per video, so a track the viewer picks later is kept.
        let audioCheckedFor = null;
        function keepOriginalAudio() {
          const p = document.getElementById('movie_player');
          if (!p || typeof p.getAvailableAudioTracks !== 'function' || typeof p.setAudioTrack !== 'function') return;
          if (p.classList.contains('ad-showing')) return;          // an ad's tracks are not the video's
          const data = typeof p.getVideoData === 'function' ? p.getVideoData() : null;
          const vid = (data && data.video_id) || new URLSearchParams(location.search).get('v');
          if (!vid || vid === audioCheckedFor) return;
          const tracks = p.getAvailableAudioTracks() || [];
          const current = typeof p.getAudioTrack === 'function' ? p.getAudioTrack() : null;
          // Decide only once the video's own tracks are known: while it loads (or for a single
          // track) the player reports one placeholder track, which says nothing about dubbing.
          if (!current || tracks.length < 2) return;
          audioCheckedFor = vid;
          const info = t => { try { return t.getLanguageInfo(); } catch (e) { return null; } };
          const id = t => { const i = info(t); return (i && typeof i.getId === 'function' && i.getId()) || ''; };
          const name = t => { const i = info(t); return (i && typeof i.getName === 'function' && i.getName()) || id(t); };
          const dubbed = t => { try { return !!t.isAutoDubbed(); } catch (e) { return false; } };
          if (!dubbed(current)) return;
          const original = tracks.find(t => id(t).split('.')[1] === '4') || tracks.find(t => !dubbed(t));
          if (!original || id(original) === id(current)) return;
          p.setAudioTrack(original);
          log('audio: ' + name(current) + ' is an auto-dub; switched to ' + name(original));
        }

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
          #kikitori-subs .kk-line.live { opacity: .86; }
          #kikitori-subs .kk-main { font: 600 clamp(14px, 3.4cqw, 40px)/1.3 "Hiragino Sans", -apple-system, sans-serif; }
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

        const line = (cls, text) => {
          const row = document.createElement('div'), main = document.createElement('div');
          row.className = cls; main.className = 'kk-main'; main.textContent = text;
          row.append(main);
          return row;
        };
        // lines: [{ja}], the newest lines as heard; live: words still being heard, drawn last.
        kk.show = (lines, live) => {
          lastShow = lines.length || live ? [lines, live] : null;
          try {
            const l = ensureLayer(); if (!l) return;
            const rows = lines.map((x, i) => line('kk-line' + (i < lines.length - 1 || live ? ' old' : ''), x.ja));
            if (live) rows.push(line('kk-line live', live));
            l.replaceChildren(...rows);
            place();
          } catch (e) { log('show failed: ' + e); }
        };
        })();
        """
}
