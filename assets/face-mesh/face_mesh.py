"""Local-only MediaPipe face mesh worker. One image on stdin, one JSON on stdout."""
import base64
import io
import json
import math
import os
import sys
from pathlib import Path

os.environ.setdefault('GLOG_minloglevel', '2')
# PyInstaller's plotting hook replaces MPLCONFIGDIR on every launch. Restore our
# private persistent font-list cache before importing MediaPipe's drawing module.
if os.environ.get('BBDV_MESH_CACHE'):
    os.environ['MPLCONFIGDIR'] = os.environ['BBDV_MESH_CACHE']
import mediapipe as mp
import numpy as np
from PIL import Image, ImageOps
from mediapipe.tasks import python
from mediapipe.tasks.python import vision


def analyze(image, model):
    image = ImageOps.exif_transpose(image).convert('RGB')
    width, height = image.size
    options = vision.FaceLandmarkerOptions(
        base_options=python.BaseOptions(model_asset_path=str(model), delegate=python.BaseOptions.Delegate.CPU),
        running_mode=vision.RunningMode.IMAGE, num_faces=12,
        min_face_detection_confidence=0.5, min_face_presence_confidence=0.5,
        output_face_blendshapes=False, output_facial_transformation_matrixes=False,
    )
    with vision.FaceLandmarker.create_from_options(options) as detector:
        result = detector.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=np.asarray(image)))
        analyzed = image
        angle = 0
        if not result.face_landmarks:
            for degrees in (-30, 30, -60, 60, -90, 90):
                analyzed = image.rotate(degrees, resample=Image.Resampling.BICUBIC, expand=True)
                result = detector.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=np.asarray(analyzed)))
                angle = math.radians(degrees)
                if result.face_landmarks:
                    break
    edges = sorted({tuple(sorted((int(a.start), int(a.end)))) for a in vision.FaceLandmarksConnections.FACE_LANDMARKS_CONTOURS})
    faces = []
    for landmarks in result.face_landmarks:
        # Undo Pillow's expanded rotation in top-left pixels, then use Swift's bottom-left pixels.
        points = []
        for p in landmarks:
            x = p.x * analyzed.width - analyzed.width / 2
            y = p.y * analyzed.height - analyzed.height / 2
            source_x = math.cos(angle) * x - math.sin(angle) * y + width / 2
            source_y = math.sin(angle) * x + math.cos(angle) * y + height / 2
            points.append([float(source_x), float(height - source_y)])
        if len(points) != 478 or not all(math.isfinite(c) for p in points for c in p):
            continue
        faces.append({'points': points})
    return {'version': 1, 'width': width, 'height': height, 'faces': faces, 'edges': edges}


def main():
    folder = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
    if len(sys.argv) == 2:
        image = Image.open(sys.argv[1])
    else:
        # stdin contains only PNG/JPEG bytes encoded as base64, never commands or paths.
        encoded = sys.stdin.buffer.read(32 * 1024 * 1024 + 1)
        if len(encoded) > 32 * 1024 * 1024:
            raise ValueError('Image is too large')
        image = Image.open(io.BytesIO(base64.b64decode(encoded, validate=True)))
    print(json.dumps(analyze(image, folder / 'face_landmarker.task'), allow_nan=False, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)
