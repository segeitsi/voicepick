#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x "build/ББ ДВ.app/Contents/MacOS/BBDV" ]; then
  bash scripts/build.sh
fi
open "build/ББ ДВ.app"
