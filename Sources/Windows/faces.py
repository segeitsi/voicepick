"""Local face geometry and a Windows-specific reference bank."""
import base64
import io
import json
from pathlib import Path
from uuid import uuid4

import numpy as np
from PIL import Image, ImageDraw, ImageOps

TIERS = ("sub 3", "sub 5", "LTB", "MTB", "HTB", "stacy", "true eve")
METHOD = "windows-face-crop-gradients-v1"


def analyze(image, model):
    from face_mesh import analyze as face_mesh

    image = ImageOps.exif_transpose(image).convert("RGB")
    image.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
    return image, face_mesh(image, model)


def face_crop(image, report, index):
    points = np.asarray(report["faces"][index]["points"])
    x, y = points[:, 0], image.height - points[:, 1]
    side = max(np.ptp(x), np.ptp(y)) * 1.24
    cx, cy = (x.min() + x.max()) / 2, (y.min() + y.max()) / 2
    rect = (max(0, int(cx - side / 2)), max(0, int(cy - side / 2)),
            min(image.width, int(cx + side / 2)), min(image.height, int(cy + side / 2)))
    if min(rect[2] - rect[0], rect[3] - rect[1]) < 35:
        raise ValueError("Лицо слишком маленькое для сравнения.")
    return image.crop(rect)


def feature(crop):
    gray = ImageOps.fit(crop.convert("L"), (64, 64))
    dy, dx = np.gradient(np.asarray(gray, dtype=np.float32) / 255)
    magnitude = np.hypot(dx, dy)
    orientation = (np.arctan2(dy, dx) % np.pi * (8 / np.pi)).astype(int) % 8
    values = []
    for y in range(0, 64, 16):
        for x in range(0, 64, 16):
            cell = np.s_[y:y + 16, x:x + 16]
            hist = np.bincount(orientation[cell].ravel(), weights=magnitude[cell].ravel(), minlength=8)
            values.extend(hist / max(0.0001, np.linalg.norm(hist)))
    vector = np.asarray(values)
    return vector / max(0.0001, np.linalg.norm(vector))


def draw_preview(image, report, index, show_map, max_size):
    preview = image.copy()
    preview.thumbnail(max_size, Image.Resampling.LANCZOS)
    if not show_map:
        return preview
    sx, sy = preview.width / image.width, preview.height / image.height
    draw = ImageDraw.Draw(preview)
    for i, face in enumerate(report["faces"]):
        color = "#68e2bc" if i == index else "#8cd4fa"
        points = [(x * sx, (image.height - y) * sy) for x, y in face["points"]]
        for a, b in report["edges"]:
            draw.line((points[a], points[b]), fill=color, width=1)
        x, y = zip(*points)
        box = (min(x), min(y), max(x), max(y))
        draw.rectangle(box, outline=color, width=2)
        draw.text((box[0] + 4, box[1] + 4), str(i + 1), fill=color)
    return preview


class ReferenceBank:
    def __init__(self, path):
        self.path = Path(path)
        self.entries = []
        if self.path.is_file():
            bank = json.loads(self.path.read_text(encoding="utf-8"))
            if bank["method"] != METHOD:
                raise ValueError("Формат базы эталонов не поддерживается.")
            self.entries = bank["references"]

    def save(self, entries):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps({"method": METHOD, "references": entries}, ensure_ascii=False), encoding="utf-8")
        temp.replace(self.path)
        self.entries = entries

    def add(self, crop, tier, kind):
        image = ImageOps.fit(crop, (120, 120))
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=84)
        item = {"id": str(uuid4()), "kind": kind, "tier": tier, "vector": feature(crop).tolist(),
                "thumbnail": base64.b64encode(buffer.getvalue()).decode("ascii")}
        self.save(self.entries + [item])

    def remove(self, entry_id):
        self.save([entry for entry in self.entries if entry["id"] != entry_id])

    def compare(self, crop, kind):
        entries = [item for item in self.entries if item["kind"] == kind]
        if not entries:
            return None, [], "Добавь свои эталоны для этого типа изображения."
        vectors = np.asarray([item["vector"] for item in entries])
        distances = np.linalg.norm(vectors - feature(crop), axis=1)
        alternatives = {}
        for i in np.argsort(distances):
            alternatives.setdefault(entries[i]["tier"], int(i))
        ordered = list(alternatives.values())
        nearest = [(entries[i], float(distances[i])) for i in ordered[:3]]
        if len(ordered) < 2:
            return None, nearest, "Для выбора категории добавь эталон другой категории."
        first, second = ordered[:2]
        best = entries[first]["tier"]
        other = [i for i, item in enumerate(entries) if item["tier"] != best]
        spacing = np.linalg.norm(vectors[other] - vectors[first], axis=1).min()
        if spacing <= 0.0001 or distances[first] > spacing / 2:
            return None, nearest, "Сходство слабое. Показан ближайший эталон."
        if distances[second] - distances[first] <= max(0.015, distances[second] * 0.08):
            return None, nearest, "Две категории близки по сходству."
        return best, nearest, "Совпадение среди добавленных категорий."
