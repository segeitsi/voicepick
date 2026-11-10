"""Download and verify the public models used by the standalone build."""
import hashlib
from importlib.metadata import distributions
from pathlib import Path, PurePosixPath
import shutil
import sys
from tempfile import TemporaryDirectory
from urllib.request import urlopen
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build" / "windows-models"
SPEECH = "vosk-model-small-ru-0.22"
FACE = "face_landmarker.task"
SPEECH_URL = f"https://alphacephei.com/vosk/models/{SPEECH}.zip"
FACE_URL = "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"
SPEECH_SHA = "961d5ff98a17f4aa6de69864d0aa71fa5bac682301d2b5d17a3f24c5c99a46d4"
FACE_SHA = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"


def verified(source, output, url, expected):
    if output.is_file() and hashlib.sha256(output.read_bytes()).hexdigest() == expected:
        return
    print(f"Preparing {output.name}", flush=True)
    temp = output.with_suffix(".part")
    if source.is_file():
        shutil.copyfile(source, temp)
    else:
        with urlopen(url, timeout=90) as response, temp.open("wb") as file:
            shutil.copyfileobj(response, file)
    if hashlib.sha256(temp.read_bytes()).hexdigest() != expected:
        temp.unlink()
        raise ValueError(f"Unexpected SHA-256 for {output.name}")
    temp.replace(output)


def package_speech(archive):
    destination = OUTPUT / SPEECH
    if (destination / "am" / "final.mdl").is_file() and (destination / "conf" / "model.conf").is_file():
        return
    with TemporaryDirectory(dir=OUTPUT.parent) as directory, ZipFile(archive) as source:
        for item in source.infolist():
            parts = PurePosixPath(item.filename).parts
            if not parts or parts[0] != SPEECH or ".." in parts or any(":" in part or "\\" in part for part in parts):
                raise ValueError("Unexpected path in the Vosk model archive")
        source.extractall(directory)
        if destination.exists():
            shutil.rmtree(destination)
        (Path(directory) / SPEECH).replace(destination)


def package_notices():
    notices = OUTPUT / "licenses"
    notices.mkdir(exist_ok=True)
    for distribution in distributions():
        folder = notices / distribution.metadata["Name"]
        for item in distribution.files or ():
            name = item.name.lower()
            if name.startswith(("license", "copying", "notice", "copyright")) and not name.endswith((".py", ".pyc")):
                original = distribution.locate_file(item)
                if original.is_file():
                    folder.mkdir(exist_ok=True)
                    shutil.copyfile(original, folder / item.name)
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if python_license.is_file():
        shutil.copyfile(python_license, notices / "Python-LICENSE.txt")
    shutil.copyfile(ROOT / "assets" / "face-mesh" / "NOTICE.md", notices / "MediaPipe-model-NOTICE.md")
    (notices / "Vosk-model-NOTICE.txt").write_text(
        f"{SPEECH}\n{SPEECH_URL}\nSHA-256: {SPEECH_SHA}\nApache License 2.0\n",
        encoding="utf-8")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    cache = OUTPUT.parent / "windows-cache"
    cache.mkdir(exist_ok=True)
    archive = cache / f"{SPEECH}.zip"
    verified(ROOT / "build" / "windows-input" / archive.name, archive, SPEECH_URL, SPEECH_SHA)
    verified(ROOT / "assets" / "face-mesh" / FACE, OUTPUT / FACE, FACE_URL, FACE_SHA)
    package_speech(archive)
    package_notices()


if __name__ == "__main__":
    main()
