#!/bin/zsh
# Fetch the captioned VTuber clips slowly: one at a time, long random pauses, and a
# 10-minute back-off whenever YouTube asks for verification. Gives up after 4 back-offs.
# Output: data/vtcc/<id>.ja.vtt (human captions) and <id>.wav (first 5 min, 16 kHz mono).
cd "${0:A:h}/data/vtcc" || exit 1
ids=(nCq3U71DrC4 37SglCd4roc z_Qg9rqznMc r51WvJ3flS8 SuQNVIFkio4 jEBYHR3lM9k
     CpC7INko5uU lW4D8pbsW0g fTVCqNTkfPk UNtM9xiT0qA ReepAmWmScI 136xxR8AzgI N2vHsbWSBoQ)
slow=(--sleep-requests 3 --sleep-interval 15 --max-sleep-interval 40)
backoffs=0

fetch() {  # $1 = id; returns 2 when YouTube asks for verification
  local id=$1 log
  if [[ ! -f $id.ja.vtt ]]; then
    log=$(yt-dlp -q $slow --skip-download --write-subs --sub-langs ja --sub-format vtt \
          -o "$id" "https://www.youtube.com/watch?v=$id" 2>&1)
    [[ $log == *"not a bot"* ]] && return 2
  fi
  if [[ ! -f $id.wav ]]; then
    log=$(yt-dlp -q $slow -f bestaudio --download-sections "*0-300" \
          -o "$id.%(ext)s" "https://www.youtube.com/watch?v=$id" 2>&1)
    [[ $log == *"not a bot"* ]] && return 2
    local f=$(ls $id.* 2>/dev/null | grep -v -E '\.(vtt|wav)$' | head -1)
    [[ -n $f ]] && ffmpeg -loglevel error -y -i "$f" -ac 1 -ar 16000 $id.wav && rm "$f"
  fi
  return 0
}

for id in $ids; do
  while true; do
    fetch $id; rc=$?
    if (( rc == 2 )); then
      (( ++backoffs > 4 )) && { echo "$(date +%T) still blocked after 4 back-offs, stopping"; exit 1; }
      echo "$(date +%T) $id: verification wall, waiting 10 min (back-off $backoffs)"
      sleep 600
    else
      echo "$(date +%T) $id: vtt=$([[ -f $id.ja.vtt ]] && echo ok || echo -) wav=$([[ -f $id.wav ]] && echo ok || echo -)"
      sleep $(( 30 + RANDOM % 60 ))
      break
    fi
  done
done
echo "$(date +%T) done: $(ls *.wav 2>/dev/null | wc -l | tr -d ' ') clips with audio"
