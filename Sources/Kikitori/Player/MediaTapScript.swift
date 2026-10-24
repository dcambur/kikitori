/// Injected into the built-in player's page at document start, before the site's own scripts:
/// the audio for synced subtitles (docs/design/realtime-sync.md, approach A).
///
/// The site's player downloads its media ahead of playback and hands it to Media Source
/// Extensions. This wraps `addSourceBuffer` and `appendBuffer` (always calling the originals, so
/// playback is untouched) and so sees the audio bytes the player already fetched, 15–120 s
/// before they play on a video. No extra requests are made and nothing is stored beyond memory.
///
/// - Ads play in the same `<video>` from their own MediaSource, on their own timeline, and while
///   they do, the site's player still reports the video's id. So each MediaSource is classified
///   when it is attached to the video (`src` blob URL or `srcObject`): attached while
///   `#movie_player` has `ad-showing`, it is an ad and never decoded; otherwise it is the video's.
///   Until then its bytes are only kept.
/// - Each of the video's MediaSources gets its own key, "<video id>~<page>.<n>": the site makes a new one
///   when the audio track changes (the auto-dub switched back to the original) and after an ad, so
///   audio, cues and work done under an old key are never mixed with the new track's. `key` is
///   the one playing now; packets carry their stream's key as `vid`.
/// - While `active` (a player session), each buffer's bytes are demuxed (WebM/Opus, fragmented
///   MP4/AAC; appends split frames anywhere, so both parsers are incremental and resync at the
///   next cluster or fragment after a gap), decoded with WebCodecs, mixed to mono and posted as
///   `kkMedia` {vid, s: stream, t: video time of the first sample, r: rate, pcm: base64 Int16}.
/// - While not active, the newest bytes of each buffer are kept (up to 8 MB, ~8 minutes) so a
///   session started later still gets the audio already buffered ahead.
enum MediaTapScript {
    static let source = #"""
        (() => {
        if (window.__kikitoriMedia) return;
        const M = window.__kikitoriMedia = { active: false, streams: [], lastEnd: null, urls: new Map(), made: 0, key: null, keys: new Map(),
                                             page: Date.now().toString(36) };   // a reload starts new keys
        const post = (name, body) => { try { window.webkit.messageHandlers[name].postMessage(body); } catch (e) {} };
        const log = m => post('kkLog', 'media: ' + m);
        const player = () => document.getElementById('movie_player');
        const isAd = () => { const p = player(); return !!(p && p.classList.contains('ad-showing')); };
        const videoID = () => {
          try { const p = player(), d = p && p.getVideoData && p.getVideoData(); if (d && d.video_id) return d.video_id; } catch (e) {}
          return new URLSearchParams(location.search).get('v') || location.pathname;
        };
        const KEEP = 8 << 20;
        const concat = (a, b) => { if (!a.length) return b; const o = new Uint8Array(a.length + b.length); o.set(a); o.set(b, a.length); return o; };

        // ---- WebM (Matroska) ---------------------------------------------------------------
        // Parsed whole: EBML header, Info, Tracks, Cluster Timecode, SimpleBlock, BlockGroup.
        // Entered: Segment, Cluster (their size may be unknown on live streams). Others skipped.
        function WebM(onConfig, onFrame) {
          const SEGMENT = 0x18538067, CLUSTER = 0x1F43B675, EBML = 0x1A45DFA3, INFO = 0x1549A966, TRACKS = 0x1654AE6B;
          const whole = new Set([EBML, INFO, TRACKS, 0xE7, 0xA3, 0xA0]);
          let buf = new Uint8Array(0), pos = 0, skip = 0, scale = 1e6, cluster = 0, synced = true, track = 0, warned = false;
          const id = p => {
            if (p >= buf.length) return null; const b = buf[p];
            const len = b & 0x80 ? 1 : b & 0x40 ? 2 : b & 0x20 ? 3 : b & 0x10 ? 4 : 0;
            if (!len) return { bad: true }; if (p + len > buf.length) return null;
            let v = 0; for (let i = 0; i < len; i++) v = v * 256 + buf[p + i]; return { v, len };
          };
          const size = (u8, p, end) => {
            if (p >= end) return null; const b = u8[p]; let len = 1, mask = 0x80;
            while (len <= 8 && !(b & mask)) { len++; mask >>= 1; }
            if (len > 8) return { bad: true }; if (p + len > end) return null;
            let v = b & (mask - 1), ones = v === mask - 1;
            for (let i = 1; i < len; i++) { v = v * 256 + u8[p + i]; if (u8[p + i] !== 0xff) ones = false; }
            return { v: ones ? -1 : v, len };
          };
          const uint = (s, e) => { let v = 0; for (let i = s; i < e; i++) v = v * 256 + buf[i]; return v; };
          // Complete child elements of [s, e).
          function each(s, e, fn) {
            let p = s;
            while (p < e) {
              const b = buf[p]; const len = b & 0x80 ? 1 : b & 0x40 ? 2 : b & 0x20 ? 3 : b & 0x10 ? 4 : 0; if (!len) return;
              let v = 0; for (let i = 0; i < len; i++) v = v * 256 + buf[p + i];
              const z = size(buf, p + len, e); if (!z || z.bad || z.v < 0) return;
              const body = p + len + z.len; fn(v, body, Math.min(e, body + z.v)); p = body + z.v;
            }
          }
          function tracks(s, e) {
            each(s, e, (v, b, f) => {
              if (v !== 0xAE) return;
              const t = { number: 0, type: 0, codec: '', priv: null, rate: 48000, channels: 2 };
              each(b, f, (w, c, g) => {
                if (w === 0xD7) t.number = uint(c, g);
                else if (w === 0x83) t.type = uint(c, g);
                else if (w === 0x86) t.codec = String.fromCharCode(...buf.subarray(c, g));
                else if (w === 0x63A2) t.priv = buf.slice(c, g);
                else if (w === 0xE1) each(c, g, (x, d, h) => {
                  if (x === 0x9F) t.channels = uint(d, h);
                  else if (x === 0xB5) { const dv = new DataView(buf.buffer, buf.byteOffset + d, h - d); t.rate = h - d === 4 ? dv.getFloat32(0) : dv.getFloat64(0); }
                });
              });
              if (track || (t.type && t.type !== 2)) return;   // the first audio track
              track = t.number;
              const codec = t.codec === 'A_OPUS' ? 'opus' : t.codec === 'A_VORBIS' ? 'vorbis' : t.codec === 'A_AAC' ? 'mp4a.40.2' : null;
              if (!codec) { log('unsupported WebM codec ' + t.codec); return; }
              onConfig({ codec, rate: Math.round(t.rate), channels: t.channels, description: t.priv });
            });
          }
          function block(s, e) {
            const n = size(buf, s, e); if (!n || n.bad) return;
            const q = s + n.len; if (q + 3 > e) return;
            if (track && n.v !== track) return;
            const rel = (buf[q] << 8 | buf[q + 1]) << 16 >> 16, flags = buf[q + 2];
            if (flags & 0x06) { if (!warned) { warned = true; log('laced WebM blocks are not supported'); } return; }
            onFrame((cluster + rel) * scale / 1e9, buf.slice(q + 3, e));
          }
          function step() {
            for (;;) {
              if (skip) { const n = Math.min(skip, buf.length - pos); pos += n; skip -= n; if (skip) return; }
              if (!synced) {   // look for the next Cluster, or a new init (after abort() the site often sends one)
                let i = pos;
                for (; i + 4 <= buf.length; i++) {
                  if (buf[i] === 0x1F && buf[i + 1] === 0x43 && buf[i + 2] === 0xB6 && buf[i + 3] === 0x75) break;
                  if (buf[i] === 0x1A && buf[i + 1] === 0x45 && buf[i + 2] === 0xDF && buf[i + 3] === 0xA3) break;
                }
                if (i + 4 > buf.length) { pos = Math.max(pos, buf.length - 3); return; }
                pos = i; synced = true;
              }
              const h = id(pos); if (!h) return; if (h.bad) { synced = false; pos++; continue; }
              const z = size(buf, pos + h.len, buf.length); if (!z) return; if (z.bad) { synced = false; pos++; continue; }
              const body = pos + h.len + z.len;
              if (h.v === SEGMENT || h.v === CLUSTER) { pos = body; continue; }
              if (z.v < 0 || z.v > (64 << 20)) { synced = false; pos = body; continue; }
              if (!whole.has(h.v)) { pos = body; skip = z.v; continue; }
              if (body + z.v > buf.length) return;   // wait for the rest
              const end = body + z.v;
              if (h.v === EBML) { track = 0; scale = 1e6; }
              else if (h.v === INFO) each(body, end, (v, b, f) => { if (v === 0x2AD7B1) scale = uint(b, f); });
              else if (h.v === TRACKS) tracks(body, end);
              else if (h.v === 0xE7) cluster = uint(body, end);
              else if (h.v === 0xA3) block(body, end);
              else if (h.v === 0xA0) each(body, end, (v, b, f) => { if (v === 0xA1) block(b, f); });
              pos = end;
            }
          }
          return {
            push(u8) { buf = concat(buf.subarray(pos), u8); pos = 0; step(); },
            reset() { buf = new Uint8Array(0); pos = 0; skip = 0; synced = false; },
          };
        }

        // ---- fragmented MP4 -----------------------------------------------------------------
        // Whole top-level boxes: moov (timescale, AudioSpecificConfig, trex defaults), moof
        // (tfhd, tfdt, trun), mdat (the samples). Others skipped.
        function MP4(codec, onConfig, onFrame) {
          let buf = new Uint8Array(0), pos = 0, base = 0, synced = true;   // base: stream offset of buf[0]
          let timescale = 0, trexDur = 0, trexSize = 0, frag = null;
          const dv = () => new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
          const type = p => String.fromCharCode(buf[p], buf[p + 1], buf[p + 2], buf[p + 3]);
          function boxes(s, e, fn) {
            const d = dv(); let p = s;
            while (p + 8 <= e) {
              let z = d.getUint32(p), h = 8; const t = type(p + 4);
              if (z === 1) { z = Number(d.getBigUint64(p + 8)); h = 16; } else if (z === 0) z = e - p;
              if (z < h || p + z > e) return; fn(t, p + h, p + z, p); p += z;
            }
          }
          function moov(s, e) {
            // An audio SourceBuffer's init has one track.
            const d = dv(); let rate = 0, channels = 2, asc = null;
            boxes(s, e, function walk(t, b, f) {
              if (['trak', 'mdia', 'minf', 'stbl', 'mvex'].includes(t)) boxes(b, f, walk);
              else if (t === 'mdhd') timescale = buf[b] === 1 ? d.getUint32(b + 20) : d.getUint32(b + 12);
              else if (t === 'stsd') boxes(b + 8, f, walk);
              else if (t === 'mp4a') { channels = d.getUint16(b + 16); rate = d.getUint32(b + 24) >>> 16; boxes(b + 28, f, walk); }
              else if (t === 'enca') log('encrypted audio: not decoded');
              else if (t === 'esds') {   // DecoderSpecificInfo, tag 5
                for (let q = b + 4; q < f - 2; q++) if (buf[q] === 0x05) {
                  let len = 0, r = q + 1; for (let k = 0; k < 4; k++) { const c = buf[r++]; len = len << 7 | (c & 0x7f); if (!(c & 0x80)) break; }
                  if (len > 0 && len < 64 && r + len <= f) { asc = buf.slice(r, r + len); break; }
                }
              }
              else if (t === 'trex') { trexDur = d.getUint32(b + 12); trexSize = d.getUint32(b + 16); }
            });
            if (asc) onConfig({ codec: codec || 'mp4a.40.2', rate: rate || timescale, channels, description: asc });
          }
          function moof(s, e, at) {
            const d = dv(); const f = { moof: base + at, dataBase: base + at, offset: null, t: 0, dur: trexDur, size: trexSize, samples: [] };
            boxes(s, e, function walk(t, b, g) {
              if (t === 'traf') boxes(b, g, walk);
              else if (t === 'tfhd') {
                const fl = d.getUint32(b) & 0xffffff; let q = b + 8;
                if (fl & 0x1) { f.dataBase = Number(d.getBigUint64(q)); q += 8; }
                if (fl & 0x2) q += 4; if (fl & 0x8) { f.dur = d.getUint32(q); q += 4; } if (fl & 0x10) { f.size = d.getUint32(q); q += 4; }
              }
              else if (t === 'tfdt') f.t = buf[b] === 1 ? Number(d.getBigUint64(b + 4)) : d.getUint32(b + 4);
              else if (t === 'trun') {
                const fl = d.getUint32(b) & 0xffffff, n = d.getUint32(b + 4); let q = b + 8;
                if (fl & 0x1) { f.offset = d.getInt32(q); q += 4; } if (fl & 0x4) q += 4;
                for (let i = 0; i < n; i++) {
                  let du = f.dur, sz = f.size;
                  if (fl & 0x100) { du = d.getUint32(q); q += 4; } if (fl & 0x200) { sz = d.getUint32(q); q += 4; }
                  if (fl & 0x400) q += 4; if (fl & 0x800) q += 4;
                  f.samples.push([du, sz]);
                }
              }
            });
            frag = f;
          }
          function mdat(s, e) {
            if (!frag || !timescale) return;
            let q = (frag.offset !== null ? frag.dataBase + frag.offset : base + s) - base, t = frag.t;
            for (const [du, sz] of frag.samples) {
              if (q < s || q + sz > e) break;
              onFrame(t / timescale, buf.slice(q, q + sz)); q += sz; t += du;
            }
            frag = null;
          }
          function step() {
            const d = dv();
            while (buf.length - pos >= 8) {
              if (!synced) {   // look for the next fragment or init
                let i = pos + 4;
                for (; i + 4 <= buf.length; i++) { const t = type(i); if (t === 'moof' || t === 'moov' || t === 'styp' || t === 'ftyp') break; }
                if (i + 4 > buf.length) { pos = Math.max(pos, buf.length - 7); return; }
                pos = i - 4; synced = true;
              }
              let z = d.getUint32(pos), h = 8; const t = type(pos + 4);
              if (z === 1) { if (buf.length - pos < 16) return; z = Number(d.getBigUint64(pos + 8)); h = 16; }
              if (z < h || z > (64 << 20) || !/^[a-z0-9 ]{4}$/i.test(t)) { synced = false; pos++; continue; }
              if (pos + z > buf.length) return;   // wait for the rest
              if (t === 'moov') moov(pos + h, pos + z);
              else if (t === 'moof') moof(pos + h, pos + z, pos);
              else if (t === 'mdat') mdat(pos + h, pos + z);
              pos += z;
            }
          }
          return {
            push(u8) { base += pos; buf = concat(buf.subarray(pos), u8); pos = 0; step(); },
            reset() { base += buf.length; buf = new Uint8Array(0); pos = 0; synced = false; frag = null; },
          };
        }

        // ---- decoding ---------------------------------------------------------------------------
        // A parser that throws on damaged bytes drops what it holds and resyncs at the next cluster
        // or fragment, instead of failing on every later append.
        function feed(st, bytes) {
          try { st.demux.push(bytes); } catch (e) { log('demux: ' + e); try { st.demux.reset(); } catch (e2) {} }
        }
        function open(st) {
          close(st);
          // Live fMP4 repeats its init in every fragment: the same config keeps the decoder. A new
          // one (a track switch) lets the old decoder finish what it was given before closing.
          const config = c => {
            const cfg = { codec: c.codec, sampleRate: c.rate, numberOfChannels: c.channels };
            if (c.description) cfg.description = c.description;
            const key = [cfg.codec, cfg.sampleRate, cfg.numberOfChannels, cfg.description ? Array.from(cfg.description).join(',') : ''].join('|');
            if (key === st.cfgKey) return;
            st.cfgKey = key; st.cfg = cfg;
            const old = st.decoder; st.decoder = null;
            if (old) old.flush().catch(() => {}).finally(() => { try { old.close(); } catch (e) {} });
          };
          // A decoder error (a damaged frame) loses that decoder: the next frame gets a new one.
          const frame = (t, data) => {
            if (!st.decoder && st.cfg) {
              try {
                const dec = new AudioDecoder({ output: a => output(st, a), error: e => { log('decoder: ' + e); if (st.decoder === dec) st.decoder = null; } });
                dec.configure(st.cfg);
                st.decoder = dec;
              } catch (e) { log('decoder setup: ' + e); st.cfg = null; }
            }
            if (!st.decoder || st.decoder.state !== 'configured') return;
            // The SourceBuffer's timestampOffset moves its media onto the video's timeline.
            try { st.decoder.decode(new EncodedAudioChunk({ type: 'key', timestamp: Math.round((t + st.offset) * 1e6), data })); } catch (e) {}
          };
          st.demux = st.type.includes('mp4') ? MP4(st.codec, config, frame) : WebM(config, frame);
        }
        function close(st) {
          flush(st);
          if (st.decoder) { try { st.decoder.close(); } catch (e) {} st.decoder = null; }
          st.demux = null; st.cfg = null; st.cfgKey = null;
        }
        // Mono, batched into runs of up to 0.5 s that follow on in time.
        function output(st, a) {
          const n = a.numberOfFrames, ch = a.numberOfChannels, rate = a.sampleRate, t = a.timestamp / 1e6;
          const mono = new Float32Array(n), plane = new Float32Array(n);
          try {
            for (let c = 0; c < ch; c++) { a.copyTo(plane, { planeIndex: c, format: 'f32-planar' }); for (let i = 0; i < n; i++) mono[i] += plane[i] / ch; }
          } catch (e) { a.close(); return; }
          a.close();
          let o = st.out;
          if (o && (o.rate !== rate || Math.abs(t - (o.t + o.n / o.rate)) > 0.02)) { flush(st); o = null; }
          if (!o) o = st.out = { t, rate, parts: [], n: 0 };
          o.parts.push(mono); o.n += n;
          clearTimeout(st.timer);
          if (o.n >= rate * 0.5) flush(st); else st.timer = setTimeout(() => flush(st), 250);
        }
        function flush(st) {
          const o = st.out; st.out = null; clearTimeout(st.timer);
          if (!o || !o.n) return;
          const pcm = new Int16Array(o.n); let k = 0;
          for (const part of o.parts) for (let i = 0; i < part.length; i++) pcm[k++] = Math.max(-32768, Math.min(32767, Math.round(part[i] * 32767)));
          const u8 = new Uint8Array(pcm.buffer); let bin = '';
          for (let i = 0; i < u8.length; i += 8192) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 8192));
          post('kkMedia', { vid: st.ms.__kkKey, s: st.id, t: o.t, r: o.rate, pcm: btoa(bin) });
          st.decoded += o.n / o.rate;
          st.until = Math.max(st.until, o.t + o.n / o.rate);
          M.lastEnd = o.t + o.n / o.rate;
        }

        // ---- hooks --------------------------------------------------------------------------
        function wrap(proto) {
          if (!proto || !Object.prototype.hasOwnProperty.call(proto, 'addSourceBuffer')) return;
          const original = proto.addSourceBuffer;
          proto.addSourceBuffer = function (type) {
            const sb = original.apply(this, arguments);
            try {
              if (String(type).startsWith('audio')) {
                const codec = (/codecs="?([^",]+)/.exec(type) || [])[1] || '';
                // ad: null until the MediaSource is seen attached (classify, below).
                const st = { id: ++M.made, sb, ms: this, type: String(type), codec, ad: null,
                             head: null, kept: [], keptBytes: 0, trimmed: false, demux: null, decoder: null, cfg: null,
                             out: null, timer: 0, decoded: 0, until: -1, offset: 0 };
                sb.__kikitori = st;
                M.streams.push(st);
                const ms = this;
                this.addEventListener('sourceclose', () => {
                  close(st); st.head = null; st.kept = []; st.keptBytes = 0;
                  M.streams = M.streams.filter(x => x !== st);
                  for (const [url, obj] of M.urls) if (obj === ms) M.urls.delete(url);
                });
                classify();
              }
            } catch (e) { log('addSourceBuffer: ' + e); }
            return sb;
          };
        }
        wrap(window.MediaSource && MediaSource.prototype);
        wrap(window.ManagedMediaSource && ManagedMediaSource.prototype);
        const append = SourceBuffer.prototype.appendBuffer;
        SourceBuffer.prototype.appendBuffer = function (data) {
          try {
            const st = this.__kikitori;
            if (st) {
              const u8 = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
              const bytes = u8.slice();
              if (!st.head) st.head = bytes;
              else {
                st.kept.push(bytes); st.keptBytes += bytes.length;
                while (st.keptBytes > KEEP && st.kept.length > 1) { const old = st.kept.shift(); st.keptBytes -= old ? old.length : 0; st.trimmed = true; }
              }
              try { st.offset = this.timestampOffset || 0; } catch (e) {}
              if (M.active && st.ad === false) { if (!st.demux) open(st); feed(st, bytes); }
            }
          } catch (e) { log('appendBuffer: ' + e); }
          return append.apply(this, arguments);
        };
        for (const name of ['abort', 'changeType']) {
          const original = SourceBuffer.prototype[name]; if (!original) continue;
          SourceBuffer.prototype[name] = function (type) {
            try {
              const st = this.__kikitori;
              if (st && name === 'changeType') { st.type = String(type); st.codec = (/codecs="?([^",]+)/.exec(type) || [])[1] || ''; if (st.demux) open(st); }
              else if (st) {   // abort(): the partial segment is dropped; replays of kept bytes reset here too
                st.kept.push(null);
                if (st.demux) { flush(st); st.demux.reset(); }
              }
            } catch (e) {}
            return original.apply(this, arguments);
          };
        }

        const createURL = URL.createObjectURL;
        URL.createObjectURL = function (obj) {
          const url = createURL.apply(this, arguments);
          try { if (obj && typeof obj.addSourceBuffer === 'function') M.urls.set(url, obj); } catch (e) {}
          return url;
        };
        // Which MediaSource the video plays from now, and whether an ad shows: its streams are
        // ads (dropped) or the video's (decoded, starting with what was kept).
        function classify() {
          const v = document.querySelector('#movie_player video') || document.querySelector('video');
          if (!v) return;
          const ms = v.srcObject && typeof v.srcObject.addSourceBuffer === 'function' ? v.srcObject : M.urls.get(v.src);
          if (!ms) return;
          const ad = isAd();
          if (!ad && !ms.__kkKey) {
            const vid = videoID(), n = (M.keys.get(vid) || 0) + 1;
            M.keys.set(vid, n); ms.__kkKey = vid + '~' + M.page + '.' + n;
          }
          if (!ad) M.key = ms.__kkKey;
          for (const st of M.streams) {
            if (st.ms !== ms || st.ad === ad) continue;
            st.ad = ad;
            if (ad) close(st);   // its bytes stay (ads are short), in case this call is undone
            else if (M.active) replay(st);
          }
        }
        setInterval(classify, 250);
        function replay(st) {
          open(st);
          if (st.head) feed(st, st.head);
          if (st.trimmed) st.demux.reset();   // a gap after the init: resync at the next cluster or fragment
          for (const bytes of st.kept) { if (bytes) feed(st, bytes); else st.demux.reset(); }
        }

        // ---- control (from the app) -------------------------------------------------------------
        // On: decode from now on, first what was kept (the audio already buffered ahead).
        M.setActive = on => {
          if (on === M.active) return;
          M.active = on;
          for (const st of M.streams) {
            if (!on) close(st); else if (st.ad === false) replay(st);
          }
          classify();
          log((on ? 'on' : 'off') + ', ' + M.streams.filter(s => s.ad === false).length + ' audio stream(s) of the video');
        };
        // For kkState: whether the video playing has decoded audio.
        // ok: decoded audio reaches the playhead (it stops being true if decoding stops).
        M.status = () => {
          const v = document.querySelector('#movie_player video') || document.querySelector('video');
          const t = v ? v.currentTime : 0;
          return { key: M.key, ok: M.active && M.streams.some(s => s.ad === false && s.ms.__kkKey === M.key && s.until >= t - 2),
                   until: M.lastEnd };
        };
        })();
        """#
}
