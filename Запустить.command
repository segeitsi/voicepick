#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x "build/VoicePick.app/Contents/MacOS/VoicePick" ]; then
  bash scripts/build.sh
fi
open "build/VoicePick.app"
