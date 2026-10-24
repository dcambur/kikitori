/// The script injected into the built-in player's page (YouTube, Twitch, any page with a
/// <video>). It runs in the page's own world so it can use the site's player.
///
/// - Audio is NOT taken here: WebKit gives Web Audio silence for cross-origin video (YouTube
///   streams from googlevideo.com) and a routed element goes quiet. The app taps its own WebKit
///   process instead (`AudioSources.ownWebKitProcesses`).
/// - State: `kkState` every 500 ms (time, paused, rate, live, title, url, channel, video id, and
///   whether the media tap has this video's audio: `MediaTapScript`).
/// - Audio track: YouTube may play an AI dub in the viewer's language (auto-dubbing); once per
///   video, an auto-dubbed track is switched to the original, so we hear the streamers themselves.
/// - Subtitles: `__kikitori.show(lines, live)` draws the Japanese as heard (the newest lines, then
///   the words still being heard) in a layer inside the player element (so they follow theatre
///   mode, the miniplayer and full screen), bottom-centre on the picture itself.
/// - Synced subtitles (`__kikitori.sync(true, lines)`): `__kikitori.cues(list, reset)` hands over
///   cues ready before they are spoken, and each character appears when the video reaches its
///   time (`currentTime`, every frame). A cue is final: it is drawn as it came, never changed.
///   When a line begins, `kkReveal` {id, line} tells the app (the transcript gets it then; also
///   checked every 500 ms, since frames stop while the window is hidden). Lines a seek jumps over
///   are never posted. A cue that arrives after its start (just after a seek) is not drawn on the
///   video; it still goes to the transcript. Seeking back before a cue makes it drawable again.
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
        // The key cues belong to: the media tap's for the MediaSource playing (video id and track,
        // see MediaTapScript), else the video id.
        const currentVid = () => {
          if (window.__kikitoriMedia && window.__kikitoriMedia.key) return window.__kikitoriMedia.key;
          try { const p = document.getElementById('movie_player'), d = p && p.getVideoData && p.getVideoData(); if (d && d.video_id) return d.video_id; } catch (e) {}
          return new URLSearchParams(location.search).get('v') || location.pathname;
        };
        const channel = () => {
          const a = document.querySelector('ytd-watch-metadata ytd-channel-name a, #owner #channel-name a, [data-a-target="stream-title"] ~ * a');
          return a ? a.textContent.trim() : '';
        };

        // ---- state -------------------------------------------------------------
        setInterval(() => {
          const v = video();
          let data = null; try { const p = document.getElementById('movie_player'); data = p && p.getVideoData ? p.getVideoData() : null; } catch (e) {}
          const live = !!(data && data.isLive) || !!document.querySelector('.ytp-live') || !!document.querySelector('[data-a-target="player-live-indicator"]');
          const media = window.__kikitoriMedia ? window.__kikitoriMedia.status() : null;
          post('kkState', { t: v ? v.currentTime : -1, paused: v ? v.paused : true, rate: v ? v.playbackRate : 1,
                            live, title: document.title, url: location.href, hasVideo: !!v, channel: channel(),
                            vid: currentVid(), media: !!(media && media.ok),
                            ad: !!document.querySelector('#movie_player.ad-showing') });
          // Lines pushed while there was no video (a search page, a video still loading) or before
          // the site rebuilt its player are drawn as soon as the player is there.
          if (lastShow && !sync.on) { const v = video(); if (v && (!layer || layer.parentElement !== playerBox(v))) kk.show(...lastShow); }
          place();
          keepOriginalAudio();
          if (sync.on) { const v = video(); if (v && !v.seeking && !document.querySelector('#movie_player.ad-showing')) postReveals(v.currentTime); }
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
          #kikitori-subs .kk-c { opacity: 0; transition: opacity 60ms linear; }
          #kikitori-subs .kk-spk { font-size: 62%; font-weight: 700; margin-right: .5em; }
          #kikitori-subs .kk-c.on { opacity: 1; }
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

        // A speaker tag before a line: [label or name, colour], or nothing.
        const speakerTag = who => {
          if (!who || !who[0]) return null;
          const tag = document.createElement('span');
          tag.className = 'kk-spk'; tag.textContent = who[0]; tag.style.color = who[1];
          return tag;
        };
        const line = (cls, text, who) => {
          const row = document.createElement('div'), main = document.createElement('div');
          row.className = cls; main.className = 'kk-main'; main.textContent = text;
          const tag = speakerTag(who); if (tag) main.prepend(tag);
          row.append(main);
          return row;
        };
        // lines: [{ja, who?}], the newest lines as heard; live: words still being heard, drawn last.
        kk.show = (lines, live) => {
          if (sync.on) return;
          lastShow = lines.length || live ? [lines, live] : null;
          try {
            const l = ensureLayer(); if (!l) return;
            const rows = lines.map((x, i) => line('kk-line' + (i < lines.length - 1 || live ? ' old' : ''), x.ja, x.who));
            if (live) rows.push(line('kk-line live', live));
            l.replaceChildren(...rows);
            place();
          } catch (e) { log('show failed: ' + e); }
        };

        // ---- synced subtitles --------------------------------------------------------------
        // cue: { id, vid, chars: [[text, start, end]], lines: [[from, to]], who?: [[speaker, colour]] per line },
        // times in video seconds.
        // Every frame: the newest lines that have begun (up to `lines`), each until 8 s after its
        // last character, its characters shown from their own times. Unrevealed characters keep
        // their place (transparent), so a line never moves while it fills.
        const sync = { on: false, lines: 1, cues: [], posted: new Set(), lastT: null, postedT: null, skips: [], skipsVid: null, raf: 0, rows: '', spans: [], els: new Map() };
        // Lines that have begun by `t`, once each, to the app; never those a forward seek jumped
        // over (`skips`, also for cues that arrive later). Not while the video is seeking: its
        // currentTime is already the new one before the 'seeking' event says so.
        function postReveals(t) {
          const vid = currentVid();
          if (vid !== sync.skipsVid) { sync.skips = []; sync.skipsVid = vid; }
          for (const c of sync.cues) {
            if (c.vid !== vid || c.chars[0][1] > t) continue;
            c.lines.forEach(([from, to], i) => {
              const key = c.id + ':' + i;
              if (from >= to || sync.posted.has(key)) return;
              const start = c.chars[from][1];
              if (start > t || sync.skips.some(([a, b]) => start > a && start < b)) return;
              sync.posted.add(key);
              post('kkReveal', { id: c.id, line: i });
            });
          }
          sync.postedT = t;
        }
        document.addEventListener('seeking', e => {
          const v = video();
          if (!sync.on || e.target !== v || sync.postedT === null || document.querySelector('#movie_player.ad-showing')) return;
          const from = sync.postedT, to = v.currentTime;
          postReveals(from);   // what had begun before the seek
          // Seeking back before a skipped stretch makes it playable again; forward adds one.
          sync.skips = sync.skips.filter(([a]) => a < to).map(([a, b]) => [a, Math.min(b, to)]);
          if (to > from) sync.skips.push([from, to]);
          sync.postedT = to;
        }, true);
        kk.sync = (on, lines) => {
          sync.lines = Math.max(1, lines || 1);
          if (on === sync.on) return;
          sync.on = on; sync.rows = ''; sync.spans = []; sync.els = new Map();
          cancelAnimationFrame(sync.raf);
          if (layer) layer.replaceChildren();
          if (on) { lastShow = null; sync.raf = requestAnimationFrame(frame); }
        };
        kk.cues = (list, reset) => {
          if (reset) { sync.cues = []; sync.posted.clear(); sync.rows = ''; sync.els = new Map(); sync.postedT = null; sync.skips = []; }
          const v = video(), t = v ? v.currentTime : 0, vid = currentVid(), ad = !!document.querySelector('#movie_player.ad-showing');
          for (const c of list) { c.late = !ad && c.vid === vid && c.chars[0][1] < t - 0.05; sync.cues.push(c); }
          sync.cues.sort((a, b) => a.chars[0][1] - b.chars[0][1]);
        };
        function frame() {
          sync.raf = requestAnimationFrame(frame);
          try {
            const v = video(); if (!v) return;
            // An ad plays in the same element on its own clock: nothing of the video shows meanwhile.
            if (document.querySelector('#movie_player.ad-showing')) { if (sync.rows) { sync.rows = ''; sync.spans = []; sync.els = new Map(); if (layer) layer.replaceChildren(); } sync.lastT = null; return; }
            const t = v.currentTime, vid = currentVid();
            // A seek (or the end of an ad): the cues ahead of the new position are on time again.
            if (sync.lastT === null || t < sync.lastT - 0.3 || t > sync.lastT + 1.5) for (const c of sync.cues) if (c.chars[0][1] >= t) c.late = false;
            sync.lastT = t;
            if (sync.cues.length > 2000) sync.cues = sync.cues.filter(c => c.chars[c.chars.length - 1][2] > t - 1800);
            if (!v.seeking) postReveals(t);
            const shown = [];
            for (const c of sync.cues) {
              if (c.vid !== vid || c.chars[0][1] > t) continue;
              c.lines.forEach(([from, to], i) => {
                if (from >= to) return;
                const start = c.chars[from][1], end = c.chars[to - 1][2], key = c.id + ':' + i;
                if (start <= t && !c.late && t < end + 8) shown.push({ c, from, to, key, i });
              });
            }
            const rows = shown.slice(-sync.lines);
            const key = rows.map(r => r.key).join('|');
            const l = ensureLayer(); if (!l) return;
            if (key !== sync.rows) {
              // A line already on screen keeps its element, so its characters don't fade in again.
              const made = new Map();
              sync.rows = key; sync.spans = [];
              l.replaceChildren(...rows.map((r, i) => {
                let el = sync.els.get(r.key);
                if (!el) {
                  const row = document.createElement('div'), main = document.createElement('div'), spans = [];
                  main.className = 'kk-main';
                  const tag = speakerTag(r.c.who && r.c.who[r.i]); if (tag) main.append(tag);
                  for (let k = r.from; k < r.to; k++) {
                    const span = document.createElement('span'), start = r.c.chars[k][1];
                    span.className = start <= t ? 'kk-c on' : 'kk-c';   // already due: shown at once, no fade
                    span.textContent = r.c.chars[k][0];
                    span.dataset.t = start;   // its time, for checks (--player-test, kk-check-sync)
                    main.append(span); spans.push([span, start]);
                  }
                  row.append(main);
                  el = { row, spans };
                }
                el.row.className = 'kk-line' + (i < rows.length - 1 ? ' old' : '');
                made.set(r.key, el); sync.spans.push(...el.spans);
                return el.row;
              }));
              sync.els = made;
              place();
            }
            for (const [span, start] of sync.spans) { const on = start <= t; if (span.classList.contains('on') !== on) span.classList.toggle('on', on); }
          } catch (e) { log('sync frame: ' + e); }
        }
        })();
        """
}
