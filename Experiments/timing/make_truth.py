#!/usr/bin/env python3
# EXPERIMENT (spike for docs/design/realtime-sync.md), not product code.
#
#   python3 Experiments/timing/make_truth.py <out dir>
#
# Builds a synthetic Japanese recording with known word times: each word is spoken separately by
# macOS `say` (voice Kyoko), trimmed to where its sound starts and ends, and joined into sentences
# (0–60 ms between words, 250–900 ms between sentences) over quiet noise. Writes
# <out>/truth.wav (16 kHz mono) and <out>/truth.json ([{text, start, end}] per word).
import json, os, random, struct, subprocess, sys, tempfile, wave, math

SENTENCES = [
    "今日 は 雑談 配信 を やって いきます",
    "みんな 元気 だった",
    "ちょっと 待って マジで やばい",
    "昨日 の ゲーム すごく 楽しかった",
    "えっと 何 の 話 だっけ",
    "ありがとう ございます 本当 に 嬉しい",
    "それ は 無理 でしょ",
    "次 は 歌 を 歌い ます",
    "コメント 見て ます よ",
    "うわ 怖い 怖い",
    "お腹 すいた から ラーメン 食べたい",
    "明日 も 配信 する から 来て ね",
    "え 嘘 でしょ 本当 に",
    "皆さん こんばんは",
    "ここ で セーブ し とこう",
]

RATE = 16000

def say(word, path):
    subprocess.run(["say", "-v", "Kyoko", "-o", path, word], check=True)

def read_aiff_or_wav(path):
    wav = path + ".wav"
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, wav], check=True)
    with wave.open(wav) as w:
        data = w.readframes(w.getnframes())
    return list(struct.unpack("<%dh" % (len(data) // 2), data))

def trim(s):
    # first/last 10 ms frame louder than -40 dBFS
    hop = 160
    def loud(i):
        f = s[i:i + hop]
        rms = math.sqrt(sum(x * x for x in f) / max(1, len(f))) / 32768
        return rms > 0.01
    frames = range(0, len(s) - hop, hop)
    on = [i for i in frames if loud(i)]
    if not on:
        return s
    return s[on[0]:on[-1] + hop]

def main(out):
    os.makedirs(out, exist_ok=True)
    random.seed(7)
    audio, truth = [], []
    def silence(sec):
        audio.extend(int(random.gauss(0, 30)) for _ in range(int(sec * RATE)))
    silence(0.8)
    with tempfile.TemporaryDirectory() as tmp:
        for si, sentence in enumerate(SENTENCES):
            for wi, word in enumerate(sentence.split()):
                p = os.path.join(tmp, f"{si}_{wi}.aiff")
                say(word, p)
                s = trim(read_aiff_or_wav(p))
                start = len(audio) / RATE
                audio.extend(s)
                truth.append({"text": word, "start": round(start, 3), "end": round(len(audio) / RATE, 3)})
                silence(random.uniform(0.0, 0.06))
            silence(random.uniform(0.25, 0.9))
    silence(1.0)
    with wave.open(os.path.join(out, "truth.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack("<%dh" % len(audio), *[max(-32768, min(32767, x)) for x in audio]))
    json.dump(truth, open(os.path.join(out, "truth.json"), "w"), ensure_ascii=False, indent=1)
    print(f"{len(truth)} words, {len(audio) / RATE:.1f} s → {out}/truth.wav, truth.json")

main(sys.argv[1])
