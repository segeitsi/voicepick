"""Offline Russian speech recognition, with a brief window for revised commands."""
from functools import lru_cache
import json
from queue import Empty, Full, Queue
import re
import time


NUMBERS = {
    "один": 1, "единица": 1, "два": 2, "двойка": 2, "три": 3, "тройка": 3,
    "четыре": 4, "четверка": 4, "пять": 5, "пятерка": 5, "шесть": 6, "шестерка": 6,
    "семь": 7, "семерка": 7, "восемь": 8, "восьмерка": 8, "девять": 9, "девятка": 9,
    "десять": 10, "десятка": 10,
}


def command(text, rating):
    words = re.findall(r"(?<!\w)[+-]?\d+(?:[.,]\d+)?(?!\w)|[^\W\d_]+", text.lower().replace("ё", "е"))
    if {"стоп", "пауза", "остановись"}.intersection(words):
        return "stop"
    if rating:
        for word in reversed(words):
            if word in NUMBERS:
                return str(NUMBERS[word])
            if word in {str(i) for i in range(1, 11)}:
                return word
        return None
    pairs = set(zip(words, words[1:]))
    if ({"дизлайк", "дислайк", "пропуск", "пропустить", "пас"}.intersection(words)
            or {("не", "нравится"), ("не", "лайк"), ("диз", "лайк"), ("дис", "лайк")}.intersection(pairs)):
        return "dislike"
    if {"лайк", "нравится", "сердце", "сердечко"}.intersection(words):
        return "like"
    return None


@lru_cache(maxsize=1)
def model_at(path):
    from vosk import Model, SetLogLevel
    SetLogLevel(-1)
    return Model(str(path))


def listen(path, rating, cancelled, emit):
    import sounddevice as sd
    from vosk import KaldiRecognizer

    model = model_at(path)
    if cancelled.is_set():
        return
    rate = int(sd.query_devices(kind="input")["default_samplerate"])
    recognizer = KaldiRecognizer(model, rate)
    audio = Queue(maxsize=20)

    def on_audio(data, frames, timing, status):
        try:
            audio.put_nowait(bytes(data))
        except Full:
            pass

    candidate = None
    deadline = 0.0
    previous = None
    with sd.RawInputStream(samplerate=rate, blocksize=rate // 10,
                           channels=1, dtype="int16", callback=on_audio):
        emit("ready", "Слушаю голосовые команды")
        while not cancelled.is_set():
            try:
                chunk = audio.get(timeout=0.05)
            except Empty:
                chunk = None
            if chunk is not None:
                final = recognizer.AcceptWaveform(chunk)
                result = recognizer.Result() if final else recognizer.PartialResult()
                text = json.loads(result).get("text" if final else "partial", "")
                if text and text != previous:
                    previous = text
                    emit("heard", text)
                    parsed = command(text, rating)
                    if parsed and candidate != "stop" and not (candidate == "dislike" and parsed == "like"):
                        if candidate is None:
                            deadline = time.monotonic() + 0.35
                        candidate = parsed
                if final:
                    previous = None
            if candidate and time.monotonic() >= deadline:
                emit("command", candidate)
                candidate = previous = None
                recognizer.Reset()
