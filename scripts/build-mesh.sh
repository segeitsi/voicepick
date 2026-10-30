#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/fetch-mesh-model.sh
worker="build/mesh-dist/face-mesh/face-mesh"
if [[ -x "$worker" && "$worker" -nt assets/face-mesh/face_mesh.py && "$worker" -nt assets/face-mesh/face_landmarker.task && "$worker" -nt assets/face-mesh/requirements-lock.txt ]]; then
  exit 0
fi
if [[ ! -x build/mesh-venv/bin/python ]]; then
  python="${BBDV_BUILD_PYTHON:-python3.12}"
  "$python" -m venv build/mesh-venv
  build/mesh-venv/bin/python -m pip install -r assets/face-mesh/requirements-lock.txt
fi
mkdir -p build/mesh-cache build/mesh-build
PYINSTALLER_CONFIG_DIR="$PWD/build/mesh-cache" build/mesh-venv/bin/python -m PyInstaller \
  --noconfirm --onedir --name face-mesh \
  --distpath build/mesh-dist --workpath build/mesh-build --specpath build/mesh-build \
  --collect-all mediapipe --add-data "$PWD/assets/face-mesh/face_landmarker.task:." \
  --exclude-module tkinter --exclude-module pytest --exclude-module IPython \
  --noupx assets/face-mesh/face_mesh.py
