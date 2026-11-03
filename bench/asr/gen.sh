#!/bin/bash
# Regenerate the test set: ElevenLabs TTS of texts.tsv, then three conditions.
#   clean  - TTS as-is (16k mono)
#   noisy  - pink noise mixed in at roughly 1dB SNR
#   cheap  - 300-3400Hz band, -20dB, 8kHz, 16kbps mp3 (a bad laptop mic over a bad link)
# Needs ELEVENLABS_API_KEY and ffmpeg; the apple engine needs: swiftc -O -parse-as-library apple/sa.swift -o apple/sa. Then: python3 bench.py [engine...] && uv run --with jiwer --with whisper-normalizer python score.py
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ref tts clean noisy cheap
voices=(CwhRBWXzGAHq8TQ4Fs17 IKne3meq5aSn9XLyUdCD JBFqnCBsd6RMkjVDRZzb FGY2WhTYpPnrIDTdsKH5 bIHbv24MWmeRgasZH58o XrExE9yKIg1WjnnlVkGX CwhRBWXzGAHq8TQ4Fs17 EXAVITQu4vr4xnSDxMaL)
i=0
while IFS=$'\t' read -r id text; do
  printf '%s' "$text" > "ref/$id.txt"
  body=$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"model_id":"eleven_multilingual_v2"}))' "$text")
  curl -sf -X POST "https://api.elevenlabs.io/v1/text-to-speech/${voices[$i]}?output_format=pcm_16000" \
    -H "xi-api-key: $ELEVENLABS_API_KEY" -H "Content-Type: application/json" -d "$body" -o "tts/$id.pcm"
  i=$((i+1))
  ffmpeg -loglevel error -y -f s16le -ar 16000 -ac 1 -i "tts/$id.pcm" "clean/$id.wav"
  ffmpeg -loglevel error -y -i "clean/$id.wav" -f lavfi -i "anoisesrc=color=pink:amplitude=0.3:sample_rate=16000:seed=7" \
    -filter_complex "[0][1]amix=inputs=2:duration=first:normalize=0" -ar 16000 -ac 1 "noisy/$id.wav"
  ffmpeg -loglevel error -y -i "clean/$id.wav" -af "highpass=f=300,lowpass=f=3400,volume=-20dB,aresample=8000" -c:a libmp3lame -b:a 16k "cheap/$id.mp3"
  ffmpeg -loglevel error -y -i "cheap/$id.mp3" -ar 16000 -ac 1 "cheap/$id.wav" && rm "cheap/$id.mp3"
done < texts.tsv
