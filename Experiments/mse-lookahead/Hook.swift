// EXPERIMENT (spike for docs/design/realtime-sync.md), not product code.
//
// Injected at document start, before YouTube's player script runs: wraps
// MediaSource.addSourceBuffer and SourceBuffer.appendBuffer so we see every byte the site's own
// player hands to the media pipeline (no extra requests), with the container's timestamps.
enum Hook {
    static let source = #"""
    (() => {
    const post = (n, b) => { try { window.webkit.messageHandlers[n].postMessage(b); } catch (e) {} };
    const log = m => post('log', String(m));
    const S = window.__kkspike = { bufs: [], sources: [], urls: new Map() };
    const player = () => document.getElementById('movie_player');
    const isAd = () => { const p = player(); return !!(p && p.classList.contains('ad-showing')); };
    const video = () => document.querySelector('#movie_player video') || document.querySelector('video');

    // ---- containers: just enough to read timestamps ------------------------------------
    // fMP4: init has moov/trak/mdia/mdhd (timescale); a media segment has moof/traf/tfdt.
    function mp4Boxes(u8, start, end, out, depth) {
      const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
      let p = start;
      while (p + 8 <= end) {
        let size = dv.getUint32(p); const type = String.fromCharCode(u8[p+4], u8[p+5], u8[p+6], u8[p+7]);
        let header = 8;
        if (size === 1) { size = Number(dv.getBigUint64(p + 8)); header = 16; }
        if (size === 0) size = end - p;
        if (size < header || p + size > end) { out.push({ type, partial: true }); break; }
        out.push({ type, p, size, depth });
        if (['moov','trak','mdia','moof','traf','mvex','minf','stbl'].includes(type)) mp4Boxes(u8, p + header, p + size, out, depth + 1);
        if (type === 'mdhd') { const v = u8[p+8]; out.timescale = v === 1 ? dv.getUint32(p + 8 + 4 + 16) : dv.getUint32(p + 8 + 4 + 8); }
        if (type === 'tfdt') { const v = u8[p+8]; const t = v === 1 ? Number(dv.getBigUint64(p + 12)) : dv.getUint32(p + 12); (out.tfdt = out.tfdt || []).push(t); }
        if (type === 'trun') { const n = dv.getUint32(p + 12); out.samples = (out.samples || 0) + n; }
        p += size;
      }
      return out;
    }
    // WebM: EBML elements; descend into Segment and Cluster, read TimecodeScale and Cluster Timecode.
    function ebmlId(u8, p) { const b = u8[p]; let len = b & 0x80 ? 1 : b & 0x40 ? 2 : b & 0x20 ? 3 : b & 0x10 ? 4 : 0; if (!len) return null; let id = 0; for (let i = 0; i < len; i++) id = id * 256 + u8[p+i]; return { id, len }; }
    function ebmlSize(u8, p) { const b = u8[p]; let len = 1, mask = 0x80; while (len <= 8 && !(b & mask)) { len++; mask >>= 1; } if (len > 8) return null; let v = b & (mask - 1), all = v === mask - 1; for (let i = 1; i < len; i++) { v = v * 256 + u8[p+i]; if (u8[p+i] !== 0xff) all = false; } return { size: all ? -1 : v, len }; }
    function webmScan(u8, start, end, out) {
      let p = start;
      while (p < end) {
        const id = ebmlId(u8, p); if (!id) break; const sz = ebmlSize(u8, p + id.len); if (!sz) break;
        const body = p + id.len + sz.len, stop = sz.size < 0 ? end : Math.min(end, body + sz.size);
        const hex = id.id.toString(16);
        if (hex === '1a45dfa3') out.init = true;
        if (hex === '18538067' || hex === '1f43b675' || hex === '1549a966' || hex === '1654ae6b') { if (hex === '1f43b675') out.clusters = (out.clusters || 0) + 1; webmScan(u8, body, stop, out); }
        else if (hex === '2ad7b1') { let v = 0; for (let i = body; i < stop; i++) v = v * 256 + u8[i]; out.timecodeScale = v; }
        else if (hex === 'e7') { let v = 0; for (let i = body; i < stop; i++) v = v * 256 + u8[i]; (out.timecodes = out.timecodes || []).push(v); }
        else if (hex === 'a3') out.blocks = (out.blocks || 0) + 1;
        else if (hex === '86') out.codec = String.fromCharCode(...u8.subarray(body, stop));
        if (sz.size < 0) break;
        p = stop;
      }
      return out;
    }
    function describe(rec, u8) {
      if (rec.type.includes('mp4')) { const o = mp4Boxes(u8, 0, u8.length, [], 0); if (o.timescale) rec.timescale = o.timescale;
        return { kind: 'mp4', boxes: o.filter(b => b.depth === 0).map(b => b.type).join(','), init: o.some(b => b.type === 'moov'),
                 t: o.tfdt && rec.timescale ? o.tfdt[0] / rec.timescale : null, samples: o.samples || 0 }; }
      const o = webmScan(u8, 0, u8.length, {}); if (o.timecodeScale) rec.timecodeScale = o.timecodeScale;
      return { kind: 'webm', init: !!o.init, codec: o.codec, clusters: o.clusters || 0, blocks: o.blocks || 0,
               t: o.timecodes ? o.timecodes[0] * (rec.timecodeScale || 1e6) / 1e9 : null };
    }

    // ---- hooks ---------------------------------------------------------------------------
    const origURL = URL.createObjectURL;
    URL.createObjectURL = function(obj) { const u = origURL.apply(this, arguments); if (obj && obj.addSourceBuffer) S.urls.set(u, obj); return u; };
    function wrap(proto, name) {
      if (!proto || !Object.prototype.hasOwnProperty.call(proto, 'addSourceBuffer')) return;
      const orig = proto.addSourceBuffer;
      proto.addSourceBuffer = function(type) {
        const sb = orig.call(this, type);
        if (!this.__kkid) { this.__kkid = S.sources.length + 1; S.sources.push(this); }
        const rec = { id: S.bufs.length, type, ms: this.__kkid, appends: 0, bytes: 0, segs: [], sb, made: performance.now(), madeInAd: isAd() };
        S.bufs.push(rec); sb.__kk = rec;
        log(`addSourceBuffer #${rec.id} on ${this.constructor.name} ms${rec.ms} ad=${rec.madeInAd} ${type}`);
        return sb;
      };
    }
    wrap(MediaSource.prototype, 'MediaSource');
    if (window.ManagedMediaSource) wrap(ManagedMediaSource.prototype, 'ManagedMediaSource');
    const origAppend = SourceBuffer.prototype.appendBuffer;
    SourceBuffer.prototype.appendBuffer = function(data) {
      const rec = this.__kk;
      if (rec) {
        const u8 = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        rec.appends++; rec.bytes += u8.length;
        if (rec.type.startsWith('audio')) {
          let d = null; try { d = describe(rec, u8); } catch (e) { d = { error: String(e) }; }
          const v = video();
          rec.segs.push({ at: performance.now(), bytes: u8.slice(), ad: isAd(), ct: v ? v.currentTime : -1, d, offset: this.timestampOffset });
        }
      }
      return origAppend.call(this, data);
    };
    log('hook installed; AudioDecoder=' + (typeof AudioDecoder) + ' ManagedMediaSource=' + (typeof ManagedMediaSource));

    // ---- report ---------------------------------------------------------------------------
    S.state = () => {
      const v = video(), p = player();
      const ranges = b => { try { const r = b.buffered; return [...Array(r.length).keys()].map(i => [+r.start(i).toFixed(2), +r.end(i).toFixed(2)]); } catch (e) { return 'gone'; } };
      const attached = v && v.src ? S.urls.get(v.src) : null;
      let prog = null; try { prog = p && p.getProgressState ? p.getProgressState() : null; } catch (e) {}
      return {
        t: v ? +v.currentTime.toFixed(2) : null, paused: v ? v.paused : null, rate: v ? v.playbackRate : null, muted: v ? v.muted : null,
        ad: isAd(), attachedMs: attached ? attached.__kkid : null,
        seekable: v && v.seekable.length ? [+v.seekable.start(0).toFixed(1), +v.seekable.end(v.seekable.length - 1).toFixed(1)] : null,
        liveEdge: prog ? { seekableEnd: prog.seekableEnd, ingestion: prog.ingestionTime, current: prog.current, isAtLiveHead: p.isAtLiveHead ? p.isAtLiveHead() : null } : null,
        audio: S.bufs.filter(b => b.type.startsWith('audio')).map(b => ({ id: b.id, ms: b.ms, appends: b.appends, kb: Math.round(b.bytes / 1024), buffered: ranges(b.sb),
                                                                          last: b.segs.length ? b.segs[b.segs.length - 1].d : null })),
        video: S.bufs.filter(b => b.type.startsWith('video')).map(b => ({ id: b.id, ms: b.ms, kb: Math.round(b.bytes / 1024), buffered: ranges(b.sb) })),
      };
    };
    // The audio SourceBuffer's bytes as one file (init + media segments in append order), base64
    // in pieces through the 'bytes' handler; returns the number of pieces.
    S.dump = (id) => {
      const rec = S.bufs[id]; if (!rec) return 0;
      let first = 0; rec.segs.forEach((s, i) => { if (s.d && s.d.init) first = i; });
      const segs = rec.segs.slice(first);
      const total = segs.reduce((n, s) => n + s.bytes.length, 0);
      const all = new Uint8Array(total); let o = 0; for (const s of segs) { all.set(s.bytes, o); o += s.bytes.length; }
      const piece = 1 << 18; let n = 0;
      for (let i = 0; i < all.length; i += piece) {
        let bin = ''; const sub = all.subarray(i, i + piece); for (let j = 0; j < sub.length; j += 8192) bin += String.fromCharCode.apply(null, sub.subarray(j, j + 8192));
        post('bytes', { id, i: n++, b64: btoa(bin) });
      }
      return n;
    };
    S.segments = (id) => (S.bufs[id] ? S.bufs[id].segs.map(s => ({ at: Math.round(s.at), ct: +s.ct.toFixed(2), kb: +(s.bytes.length / 1024).toFixed(1), ad: s.ad, off: s.offset, d: s.d })) : []);
    // Decode with Web Audio (no playback): init + the first `count` media segments at 16 kHz mono.
    S.decode = async (id, count) => {
      const rec = S.bufs[id]; if (!rec) return { error: 'no buffer' };
      let first = 0; rec.segs.forEach((s, i) => { if (s.d && s.d.init) first = i; });
      const segs = rec.segs.slice(first, first + count + 1);
      const total = segs.reduce((n, s) => n + s.bytes.length, 0);
      const all = new Uint8Array(total); let o = 0; for (const s of segs) { all.set(s.bytes, o); o += s.bytes.length; }
      try {
        const ctx = new OfflineAudioContext(1, 16000, 16000);
        const buf = await ctx.decodeAudioData(all.buffer);
        const ch = buf.getChannelData(0); let peak = 0; for (let i = 0; i < ch.length; i++) peak = Math.max(peak, Math.abs(ch[i]));
        S.decoded = ch;
        return { ok: true, seconds: buf.duration, rate: buf.sampleRate, channels: buf.numberOfChannels, peak };
      } catch (e) { return { ok: false, error: String(e) }; }
    };
    S.sendDecoded = () => {
      const ch = S.decoded; if (!ch) return 0; const piece = 16000 * 10; let n = 0;
      for (let i = 0; i < ch.length; i += piece) {
        const sub = ch.subarray(i, i + piece), i16 = new Int16Array(sub.length);
        for (let j = 0; j < sub.length; j++) i16[j] = Math.max(-32768, Math.min(32767, Math.round(sub[j] * 32767)));
        const u8 = new Uint8Array(i16.buffer); let bin = ''; for (let j = 0; j < u8.length; j += 8192) bin += String.fromCharCode.apply(null, u8.subarray(j, j + 8192));
        post('pcm', { i: n++, b64: btoa(bin) });
      }
      return n;
    };
    // fMP4 (AAC): timescale and AudioSpecificConfig from the init segment, then per fragment the
    // tfdt base time and trun sample sizes/durations over the following mdat.
    function mp4Demux(u8, track, blocks) {
      const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
      const fourcc = p => String.fromCharCode(u8[p], u8[p+1], u8[p+2], u8[p+3]);
      let timescale = 0, defDur = 0, defSize = 0, base = 0, samples = [], dataOffset = 0, moofStart = 0;
      (function walk(start, end) {
        let p = start;
        while (p + 8 <= end) {
          let size = dv.getUint32(p); const type = fourcc(p + 4); let h = 8;
          if (size === 1) { size = Number(dv.getBigUint64(p + 8)); h = 16; } if (size === 0) size = end - p;
          if (p + size > end) return;
          const b = p + h;
          if (['moov','trak','mdia','minf','stbl','mvex','traf'].includes(type)) walk(b, p + size);
          else if (type === 'moof') { moofStart = p; samples = []; walk(b, p + size); }
          else if (type === 'mdhd') { const v = u8[b]; timescale = v === 1 ? dv.getUint32(b + 20) : dv.getUint32(b + 12); track.rate = timescale; }
          else if (type === 'stsd') walk(b + 8, p + size);
          else if (type === 'mp4a') { track.codec = 'mp4a'; track.channels = dv.getUint16(b + 16); walk(b + 28, p + size); }
          else if (type === 'esds') {
            // find DecoderSpecificInfo (tag 5)
            for (let q = b + 4; q < p + size - 2; q++) if (u8[q] === 0x05) { let len = 0, r = q + 1; for (let k = 0; k < 4; k++) { const c = u8[r++]; len = len << 7 | (c & 0x7f); if (!(c & 0x80)) break; } if (len > 0 && len < 64 && r + len <= p + size) { track.priv = u8.slice(r, r + len); break; } }
          }
          else if (type === 'trex') { defDur = dv.getUint32(b + 12); defSize = dv.getUint32(b + 16); }
          else if (type === 'tfhd') { const f = dv.getUint32(b) & 0xffffff; let q = b + 8; if (f & 1) q += 8; if (f & 2) q += 4; if (f & 8) { defDur = dv.getUint32(q); q += 4; } if (f & 0x10) { defSize = dv.getUint32(q); q += 4; } }
          else if (type === 'tfdt') { base = u8[b] === 1 ? Number(dv.getBigUint64(b + 4)) : dv.getUint32(b + 4); }
          else if (type === 'trun') {
            const f = dv.getUint32(b) & 0xffffff, n = dv.getUint32(b + 4); let q = b + 8;
            dataOffset = 0; if (f & 1) { dataOffset = dv.getInt32(q); q += 4; } if (f & 4) q += 4;
            for (let i = 0; i < n; i++) { let d = defDur, z = defSize; if (f & 0x100) { d = dv.getUint32(q); q += 4; } if (f & 0x200) { z = dv.getUint32(q); q += 4; } if (f & 0x400) q += 4; if (f & 0x800) q += 4; samples.push({ d, z }); }
          }
          else if (type === 'mdat') {
            let q = dataOffset ? moofStart + dataOffset : b, t = base;
            for (const smp of samples) { if (q + smp.z > p + size) break; blocks.push({ t: t / timescale, data: u8.slice(q, q + smp.z) }); q += smp.z; t += smp.d; }
            samples = [];
          }
          p += size;
        }
      })(0, u8.length);
    }

    // Production-style decode: demux WebM (SimpleBlocks with the cluster's timecode) and decode
    // with WebCodecs, keeping each frame's media time. Checks the output is continuous.
    S.webcodecs = async (id) => {
      const rec = S.bufs[id]; if (!rec) return { error: 'no buffer' };
      const first = Math.max(0, rec.segs.findIndex(s => s.d && s.d.init));   // live fMP4 repeats its init in every fragment
      const segs = rec.segs.slice(first);
      const total = segs.reduce((n, s) => n + s.bytes.length, 0);
      const u8 = new Uint8Array(total); let o = 0; for (const s of segs) { u8.set(s.bytes, o); o += s.bytes.length; }
      const track = { scale: 1e6 }, blocks = [];
      let cluster = 0;
      if (rec.type.includes('mp4')) mp4Demux(u8, track, blocks); else
      (function walk(start, end) {
        let p = start;
        while (p < end) {
          const id = ebmlId(u8, p); if (!id) return; const sz = ebmlSize(u8, p + id.len); if (!sz) return;
          const body = p + id.len + sz.len, stop = sz.size < 0 ? end : Math.min(end, body + sz.size);
          const hex = id.id.toString(16);
          const uint = () => { let v = 0; for (let i = body; i < stop; i++) v = v * 256 + u8[i]; return v; };
          if (['18538067','1f43b675','1654ae6b','ae','e1','1549a966','a0'].includes(hex)) { walk(body, stop); if (sz.size < 0) return; }
          else if (hex === '2ad7b1') track.scale = uint();
          else if (hex === 'e7') cluster = uint();
          else if (hex === '63a2') track.priv = u8.slice(body, stop);
          else if (hex === '9f') track.channels = uint();
          else if (hex === 'b5') { const dv = new DataView(u8.buffer, body, stop - body); track.rate = stop - body === 4 ? dv.getFloat32(0) : dv.getFloat64(0); }
          else if (hex === '86') track.codec = String.fromCharCode(...u8.subarray(body, stop));
          else if (hex === 'a3' || hex === 'a1') {
            const tn = ebmlSize(u8, body); const q = body + tn.len;
            const rel = (u8[q] << 8 | u8[q + 1]) << 16 >> 16;
            if (stop <= end) blocks.push({ t: (cluster + rel) * track.scale / 1e9, data: u8.slice(q + 3, stop) });
          }
          p = stop;
        }
      })(0, u8.length);
      const config = { codec: track.codec === 'A_OPUS' ? 'opus' : track.codec === 'mp4a' ? 'mp4a.40.2' : track.codec, sampleRate: track.rate || 48000, numberOfChannels: track.channels || 2, description: track.priv };
      const support = await AudioDecoder.isConfigSupported(config).catch(e => ({ supported: false, error: String(e) }));
      if (!support.supported) return { track: { codec: track.codec, rate: track.rate, channels: track.channels }, support };
      const out = []; let error = null;
      const pcm = [];
      const dec = new AudioDecoder({ output: a => {
        out.push({ t: a.timestamp / 1e6, n: a.numberOfFrames, rate: a.sampleRate });
        const ch = new Float32Array(a.numberOfFrames); a.copyTo(ch, { planeIndex: 0, format: 'f32-planar' }); pcm.push(ch); a.close();
      }, error: e => { error = String(e); } });
      dec.configure(config);
      for (const b of blocks) dec.decode(new EncodedAudioChunk({ type: 'key', timestamp: Math.round(b.t * 1e6), data: b.data }));
      await dec.flush();
      let gaps = 0, maxJump = 0;
      for (let i = 1; i < out.length; i++) { const expect = out[i-1].t + out[i-1].n / out[i-1].rate; const j = Math.abs(out[i].t - expect); maxJump = Math.max(maxJump, j); if (j > 0.001) gaps++; }
      const seconds = out.reduce((n, a) => n + a.n / a.rate, 0);
      // 16 kHz mono for the speech engine (Web Audio's resampler), kept for sendDecoded().
      if (out.length) {
        const rate = out[0].rate, len = pcm.reduce((n, c) => n + c.length, 0);
        const ctx = new OfflineAudioContext(1, Math.ceil(len * 16000 / rate), 16000);
        const buf = ctx.createBuffer(1, len, rate); let o = 0; for (const c of pcm) { buf.copyToChannel(c, 0, o); o += c.length; }
        const src = ctx.createBufferSource(); src.buffer = buf; src.connect(ctx.destination); src.start();
        S.decoded = (await ctx.startRendering()).getChannelData(0);
      }
      return { track: { codec: track.codec, rate: track.rate, channels: track.channels, scale: track.scale }, blocks: blocks.length, frames: out.length,
               first: out.length ? out[0].t : null, last: out.length ? out[out.length - 1].t : null, seconds, gaps, maxJumpMs: maxJump * 1000, error };
    };

    // The original audio, not YouTube's auto-dub (same rule as PlayerScript.keepOriginalAudio).
    let audioCheckedFor = null;
    setInterval(() => {
      const p = player(); if (!p || typeof p.getAvailableAudioTracks !== 'function' || p.classList.contains('ad-showing')) return;
      const data = p.getVideoData ? p.getVideoData() : null; const vid = data && data.video_id;
      if (!vid || vid === audioCheckedFor) return;
      const tracks = p.getAvailableAudioTracks() || [], current = p.getAudioTrack ? p.getAudioTrack() : null;
      if (!current || tracks.length < 2) return;
      audioCheckedFor = vid;
      const id = t => { try { return t.getLanguageInfo().getId(); } catch (e) { return ''; } };
      const dubbed = t => { try { return !!t.isAutoDubbed(); } catch (e) { return false; } };
      if (!dubbed(current)) { log('audio track: ' + id(current) + ' (original)'); return; }
      const original = tracks.find(t => id(t).split('.')[1] === '4') || tracks.find(t => !dubbed(t));
      if (original) { S.switchedAt = performance.now(); p.setAudioTrack(original); log('audio track: ' + id(current) + ' is an auto-dub; switched to ' + id(original)); }
    }, 500);
    // Keep the spike silent: mute every video as soon as it exists.
    setInterval(() => { document.querySelectorAll('video').forEach(v => { if (!v.muted) v.muted = true; }); }, 100);
    })();
    """#
}
