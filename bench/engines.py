"""One interface over every speech engine in the benchmark.

transcribe(engine, paths, prompts=None, beam=1) -> list of (text, seconds), one per path.
Engines:
  mlx:<hf-repo>      MLX Whisper on the GPU (prompts supported: Whisper initial prompt)
  apple              Apple SpeechTranscriber via swift/apple_speech (Neural Engine)
  wcpp               whisper.cpp large-v3-turbo on Metal (beam > 1 supported)
  k2                 ReazonSpeech-k2-v2 transducer via sherpa-onnx (CPU)
  hf:<hf-repo>       transformers Whisper on MPS (e.g. litagin/anime-whisper)
"""

import json
import re
import subprocess
import tempfile
import time
from functools import cache
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).parent
MLX_OPTS = dict(language="ja", task="transcribe", condition_on_previous_text=False, verbose=None,
                temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0), compression_ratio_threshold=2.4,
                logprob_threshold=-1.0, no_speech_threshold=0.6)


def transcribe(engine, paths, prompts=None, beam=1):
    prompts = prompts or [None] * len(paths)
    if engine.startswith("mlx:"):
        return _mlx(engine[4:], paths, prompts)
    if engine == "apple":
        return _apple(paths)
    if engine == "wcpp":
        return _wcpp(paths, beam)
    if engine == "k2":
        return _k2(paths)
    if engine.startswith("hf:"):
        return _hf(engine[3:], paths)
    raise ValueError(engine)


def _mlx(repo, paths, prompts):
    import mlx_whisper
    mlx_whisper.transcribe(np.zeros(16_000, np.float32), path_or_hf_repo=repo, **MLX_OPTS)
    out = []
    for p, prompt in zip(paths, prompts):
        audio, _ = sf.read(p, dtype="float32")
        t = time.perf_counter()
        r = mlx_whisper.transcribe(audio, path_or_hf_repo=repo, initial_prompt=prompt, **MLX_OPTS)
        out.append((r["text"].strip(), time.perf_counter() - t))
    return out


def _apple(paths):
    with tempfile.TemporaryDirectory() as d:
        man, res = Path(d, "m.jsonl"), Path(d, "r.jsonl")
        man.write_text("".join(json.dumps({"id": str(i), "path": str(Path(p).resolve())}) + "\n"
                               for i, p in enumerate(paths)))
        subprocess.run([HERE / "swift/apple_speech", man, res], check=True, capture_output=True)
        got = {r["id"]: r for r in map(json.loads, res.read_text().splitlines())}
    return [(got[str(i)]["hyp"], got[str(i)]["sec"]) for i in range(len(paths))]


def _wcpp(paths, beam):
    model = _hf_file("ggerganov/whisper.cpp", "ggml-large-v3-turbo.bin")
    # One process for the whole batch keeps the model loaded; whisper-cli writes <input>.txt
    # next to each input. Time is spread evenly over the batch.
    cmd = ["whisper-cli", "-m", model, "-l", "ja", "-bs", str(beam), "-nt", "-np", "-otxt"]
    for p in paths:
        cmd += ["-f", str(p)]
    t = time.perf_counter()
    subprocess.run(cmd, check=True, capture_output=True)
    per = (time.perf_counter() - t) / max(len(paths), 1)
    out = []
    for p in paths:
        txt = Path(str(p) + ".txt")
        out.append((txt.read_text().strip().replace("\n", "") if txt.exists() else "", per))
        txt.unlink(missing_ok=True)
    return out


@cache
def _hf_file(repo, name):
    from huggingface_hub import hf_hub_download
    return hf_hub_download(repo, name)


@cache
def _k2_model():
    import sherpa_onnx
    from huggingface_hub import snapshot_download
    d = Path(snapshot_download("reazon-research/reazonspeech-k2-v2",
                               allow_patterns=["*epoch-99-avg-1.onnx", "tokens.txt"]))
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=str(d / "encoder-epoch-99-avg-1.onnx"), decoder=str(d / "decoder-epoch-99-avg-1.onnx"),
        joiner=str(d / "joiner-epoch-99-avg-1.onnx"), tokens=str(d / "tokens.txt"),
        num_threads=6, sample_rate=16_000, feature_dim=80, decoding_method="greedy_search")


def _k2(paths):
    rec, out = _k2_model(), []
    for p in paths:
        audio, sr = sf.read(p, dtype="float32")
        t = time.perf_counter()
        s = rec.create_stream()
        s.accept_waveform(sr, audio)
        rec.decode_stream(s)
        out.append((s.result.text.strip(), time.perf_counter() - t))
    return out


@cache
def _hf_pipe(repo):
    import torch
    from transformers import pipeline
    return pipeline("automatic-speech-recognition", model=repo, torch_dtype=torch.float16,
                    device="mps")


def _hf(repo, paths):
    pipe, out = _hf_pipe(repo), []
    kw = dict(language="Japanese", do_sample=False, num_beams=1, no_repeat_ngram_size=5,
              repetition_penalty=1.0)
    for p in paths:
        audio, _ = sf.read(p, dtype="float32")
        t = time.perf_counter()
        r = pipe(audio, generate_kwargs=kw)
        out.append((r["text"].strip(), time.perf_counter() - t))
    return out


HALLUCINATIONS = re.compile(r"ご視聴ありがとうございました|チャンネル登録|次回予告|字幕.{0,10}(作成|提供)")
