#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
model_path="assets/face-mesh/face_landmarker.task"
model_sha="64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
verify_model() { [[ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$model_sha" ]]; }
if [[ -f "$model_path" ]]; then
  verify_model "$model_path" || { echo 'Ошибка: контрольная сумма модели не совпадает.' >&2; exit 1; }
  exit 0
fi
mkdir -p assets/face-mesh
model_temp="$(mktemp assets/face-mesh/model.XXXXXX)"
trap 'rm -f "$model_temp"' EXIT
curl --fail --location --retry 2 --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 \
  'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task' \
  --output "$model_temp"
verify_model "$model_temp" || { echo 'Ошибка: контрольная сумма скачанной модели не совпадает.' >&2; exit 1; }
mv "$model_temp" "$model_path"
