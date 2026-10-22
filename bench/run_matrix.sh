#!/bin/zsh
# Real-stream matrix: engines × segmentation × options. One run at a time; skips finished runs.
cd "${0:A:h}"
S=data/vtcc/seg
run() {  # label engine variant [extra args]
  local label=$1 engine=$2 variant=$3; shift 3
  [[ -s results/vtcc/$label.jsonl ]] && return
  echo "$(date +%T) $label"
  uv run python vtcc.py run $engine $label $S/$variant/manifest.jsonl "$@" 2>&1 | grep -v -E "Warning|warn|^$" | tail -2
}
TURBO=mlx:mlx-community/whisper-large-v3-turbo
# 1. Engines on clean caption segments (pure accuracy)
run apple-oracle        apple  oracle
run k2-oracle           k2     oracle
run wcpp-beam5-oracle   wcpp   oracle --beam 5
run wcpp-greedy-oracle  wcpp   oracle
run turbo-mlx-oracle    $TURBO oracle
run kotoba-oracle       mlx:kaiinui/kotoba-whisper-v2.0-mlx oracle
run anime-oracle        hf:litagin/anime-whisper oracle
# 2. Context prompts (Whisper only)
run turbo-mlx-gloss-oracle $TURBO oracle --prompt gloss
run turbo-mlx-prev-oracle  $TURBO oracle --prompt prev
# 3. Vocal isolation
run apple-oracle+demucs      apple oracle+demucs
run k2-oracle+demucs         k2    oracle+demucs
run wcpp-beam5-oracle+demucs wcpp  oracle+demucs --beam 5
# 4. Whole pipeline: blind windows vs speech-aware cuts, with and without isolation
for e in apple k2; do
  run $e-fixed15 $e fixed15; run $e-vad $e vad; run $e-vad+demucs $e vad+demucs
done
run wcpp-beam5-fixed15    wcpp fixed15 --beam 5
run wcpp-beam5-vad        wcpp vad --beam 5
run wcpp-beam5-vad+demucs wcpp vad+demucs --beam 5
# 5. Latency: speech-aware cuts capped at 6 s instead of 15 s
run apple-vad6      apple vad6
run k2-vad6         k2    vad6
run wcpp-beam5-vad6 wcpp  vad6 --beam 5
echo "$(date +%T) done"
uv run python vtcc.py score
