"""VoicePick for Windows. All desktop and Tk calls run on the main thread."""
import base64
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
from pathlib import Path
from queue import Empty, SimpleQueue
import random
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import numpy as np
from PIL import Image, ImageTk
from pynput import keyboard
import win32api
import win32con
import win32gui

import desktop
import faces
import voice

ROOT = Path(__file__).resolve().parents[2]
if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(ROOT / "assets" / "face-mesh"))
MODELS = Path(sys._MEIPASS) / "models" if getattr(sys, "frozen", False) else ROOT / "build" / "windows-models"
DATA = Path(os.environ["LOCALAPPDATA"]) / "VoicePick"
SETTINGS = DATA / "settings.json"

BACKGROUND = "#12161b"
SIDEBAR = "#171b21"
PANEL = "#1c2128"
INK = "#eef2f6"
MUTED = "#a7b3bf"
ACCENT = "#8cd4fa"
BUTTON = "#303b46"
MODES = {"voice": "Голосовой ввод", "random": "Рандомайзер", "face": "Анализ лица"}


def label(parent, text=None, *, variable=None, size=11, bold=False, color=INK, background=PANEL, wrap=0):
    return tk.Label(parent, text=text, textvariable=variable, font=("Segoe UI", size, "bold" if bold else "normal"),
                    background=background, foreground=color, anchor="w", justify="left", wraplength=wrap)


def button(parent, text, callback, *, primary=False, selected=False):
    background = ACCENT if primary else BUTTON if selected else "#28313a"
    foreground = BACKGROUND if primary else ACCENT if selected else INK
    return tk.Button(parent, text=text, command=callback, borderwidth=0, highlightthickness=1,
                     highlightbackground=background, highlightcolor=ACCENT,
                     padx=13, pady=7, anchor="w", background=background, foreground=foreground,
                     activebackground="#b8e7ff" if primary else "#3b4a57", activeforeground=foreground,
                     font=("Segoe UI", 10, "bold"), cursor="hand2")


def fingerprint(image):
    pixels = image.convert("L").resize((24, 24), Image.Resampling.BILINEAR)
    return np.asarray(pixels, dtype=np.float32) / 255


def distance(first, second):
    return float(np.abs(first - second).mean())


class RegionPicker:
    def __init__(self, root, point, title, complete):
        self.complete = complete
        self.point = point
        self.start = None
        self.rect = None
        self.window = tk.Toplevel(root)
        self.window.overrideredirect(True)
        self.window.attributes("-topmost", True)
        self.window.attributes("-alpha", 0.33)
        x, y, right, bottom = win32api.GetMonitorInfo(
            win32api.MonitorFromPoint(win32api.GetCursorPos(), win32con.MONITOR_DEFAULTTONEAREST)
        )["Monitor"]
        width, height = right - x, bottom - y
        self.canvas = tk.Canvas(self.window, bg="#172735", borderwidth=0, highlightthickness=0, cursor="crosshair")
        self.canvas.pack(fill="both", expand=True)
        self.canvas.create_text(width / 2, 48, text=title + "   ·   Esc — отмена",
                                fill="white", font=("Segoe UI", 20, "bold"))
        self.window.geometry(f"{width}x{height}+0+0")
        self.window.update_idletasks()
        hwnd = win32gui.GetAncestor(self.window.winfo_id(), win32con.GA_ROOT)
        win32gui.SetWindowPos(hwnd, win32con.HWND_TOPMOST, x, y, width, height, win32con.SWP_SHOWWINDOW)
        self.window.bind("<Escape>", lambda _: self.finish(None))
        self.canvas.bind("<ButtonPress-1>", self.press)
        self.canvas.bind("<B1-Motion>", self.move)
        self.canvas.bind("<ButtonRelease-1>", self.release)
        self.window.grab_set()
        self.window.focus_force()

    def press(self, event):
        self.start = (event.x, event.y, *win32api.GetCursorPos())
        if not self.point:
            if self.rect is not None:
                self.canvas.delete(self.rect)
            self.rect = self.canvas.create_rectangle(event.x, event.y, event.x, event.y, outline="white", width=3)

    def move(self, event):
        if self.start and self.rect is not None:
            self.canvas.coords(self.rect, *self.start[:2], event.x, event.y)

    def release(self, _):
        if self.start is None:
            return
        x, y = win32api.GetCursorPos()
        if self.point:
            self.finish((x, y))
            return
        sx, sy = self.start[2:]
        rect = (min(sx, x), min(sy, y), max(sx, x), max(sy, y))
        if min(desktop.size(rect)) >= 80:
            self.finish(rect)

    def finish(self, value):
        self.window.destroy()
        self.complete(value)


class VoicePick:
    def __init__(self, root):
        self.root = root
        self.settings = self.load_settings()
        self.mode = "voice"
        self.kind = tk.StringVar(value=self.settings.get("kind", "rating"))
        self.like = tk.StringVar(value=self.settings.get("like", "❤️"))
        self.dislike = tk.StringVar(value=self.settings.get("dislike", "👎"))
        self.enter = tk.BooleanVar(value=self.settings.get("enter", False))
        self.minimum = tk.StringVar(value=self.settings.get("minimum", "1"))
        self.maximum = tk.StringVar(value=self.settings.get("maximum", "10"))
        self.percent = tk.DoubleVar(value=self.settings.get("percent", 50))
        self.threshold = tk.DoubleVar(value=self.settings.get("threshold", 9))
        self.status = tk.StringVar(value="Укажи поле для ответа")
        self.target_label = tk.StringVar()
        self.targets = {}
        self.writer = desktop.Writer()
        self.active = None
        self.cancelled = threading.Event()
        self.events = SimpleQueue()
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.voice_thread = None
        self.picker = None
        self.generation = 0
        self.watched = None
        self.face_region = None
        self.face_result = None
        self.face_images = []
        self.face_index = tk.StringVar(value="1")
        self.show_map = tk.BooleanVar(value=True)
        self.face_kind = tk.StringVar(value="Фотографии")
        self.face_tier = tk.StringVar(value="MTB")
        self.reference_status = tk.StringVar()
        self.bank = None
        try:
            self.bank = faces.ReferenceBank(DATA / "reference-bank-windows.json")
        except (OSError, ValueError, KeyError) as error:
            messagebox.showerror("Эталоны VoicePick", f"Не удалось открыть локальную базу.\n{error}", parent=root)

        root.title("VoicePick")
        root.configure(background=BACKGROUND)
        root.geometry("940x710")
        root.minsize(790, 550)
        root.protocol("WM_DELETE_WINDOW", self.close)
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure(".", background=PANEL, foreground=INK, fieldbackground=BACKGROUND,
                        bordercolor=BUTTON, font=("Segoe UI", 10))
        style.configure("TEntry", insertcolor=INK, padding=5)
        style.configure("TCombobox", arrowcolor=INK, padding=4)
        style.map("TCombobox", fieldbackground=[("readonly", BACKGROUND)],
                  foreground=[("readonly", INK)])
        style.map("TCheckbutton", background=[("active", PANEL)], foreground=[("active", INK)])
        root.option_add("*TCombobox*Listbox.background", BACKGROUND)
        root.option_add("*TCombobox*Listbox.foreground", INK)

        self.sidebar = tk.Frame(root, bg=SIDEBAR, width=170)
        self.sidebar.pack(side="left", fill="y")
        self.sidebar.pack_propagate(False)
        self.body = tk.Frame(root, bg=BACKGROUND)
        self.body.pack(side="left", fill="both", expand=True)
        self.render()
        self.install_hotkeys()
        root.after(45, self.poll_events)

    @staticmethod
    def load_settings():
        try:
            data = json.loads(SETTINGS.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def save_settings(self):
        DATA.mkdir(parents=True, exist_ok=True)
        fields = ("kind", "like", "dislike", "enter", "minimum", "maximum", "percent", "threshold")
        data = {key: getattr(self, key).get() for key in fields}
        temp = SETTINGS.with_suffix(".tmp")
        temp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        temp.replace(SETTINGS)

    @property
    def target(self):
        return self.targets.get(self.kind.get())

    def install_hotkeys(self):
        enter_down = False

        def stop():
            self.cancelled.set()
            self.events.put(("stop", None, None))

        def press(key):
            nonlocal enter_down
            hotkey.press(listener.canonical(key))
            if key == keyboard.Key.enter and not enter_down:
                enter_down = True
                if not desktop.modifiers_down():
                    self.events.put(("enter", None, desktop.foreground()))

        def release(key):
            nonlocal enter_down
            hotkey.release(listener.canonical(key))
            if key == keyboard.Key.enter:
                enter_down = False

        hotkey = keyboard.HotKey(keyboard.HotKey.parse("<ctrl>+<alt>+s"), stop)
        listener = keyboard.Listener(on_press=press, on_release=release)
        self.listener = listener
        listener.start()

    def render(self):
        for parent in (self.sidebar, self.body):
            for child in parent.winfo_children():
                child.destroy()
        label(self.sidebar, "VoicePick", size=19, bold=True, background=SIDEBAR).pack(fill="x", padx=16, pady=(18, 22))
        for mode, title in (("voice", "Голос"), ("random", "Рандомайзер"), ("face", "Анализ лица")):
            button(self.sidebar, title, lambda value=mode: self.navigate(value),
                   selected=mode == self.mode).pack(fill="x", padx=12, pady=3)
        label(self.sidebar, "Стоп  ·  Ctrl+Alt+S", size=9, color=MUTED, background=SIDEBAR).pack(
            side="bottom", fill="x", padx=13, pady=15)

        header = tk.Frame(self.body, bg=BACKGROUND)
        header.pack(fill="x", padx=23, pady=(19, 13))
        label(header, MODES[self.mode], size=23, bold=True, background=BACKGROUND).pack(side="left")
        if self.mode == "face":
            button(header, "Открыть фото", self.open_photo, primary=True).pack(side="right")
        else:
            button(header, "Запустить", self.start_input, primary=True).pack(side="right")
        label(self.body, variable=self.status, color=MUTED, background=BACKGROUND, wrap=560).pack(
            fill="x", padx=24, pady=(0, 12))

        viewport = tk.Frame(self.body, bg=BACKGROUND)
        viewport.pack(fill="both", expand=True, padx=(23, 8), pady=(0, 10))
        canvas = tk.Canvas(viewport, bg=BACKGROUND, highlightthickness=0)
        scroll = ttk.Scrollbar(viewport, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True, padx=(0, 10))
        self.content = tk.Frame(canvas, bg=BACKGROUND)
        item = canvas.create_window(0, 0, anchor="nw", window=self.content)
        self.content.bind("<Configure>", lambda _: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda event: canvas.itemconfigure(item, width=event.width))
        self.root.bind("<MouseWheel>", lambda event: canvas.yview_scroll(-int(event.delta / 120), "units"))
        if self.mode == "face":
            self.render_faces()
        else:
            self.render_input()

    def panel(self, title):
        frame = tk.Frame(self.content, bg=PANEL, padx=16, pady=13,
                         highlightthickness=1, highlightbackground="#313945")
        frame.pack(fill="x", pady=(0, 12))
        label(frame, title, size=13, bold=True).pack(fill="x", pady=(0, 9))
        return frame

    def navigate(self, mode):
        if mode == self.mode:
            return
        self.stop(quiet=True)
        self.mode = mode
        self.status.set("Открой фото или выдели область экрана" if mode == "face" else "Укажи поле для ответа")
        self.render()

    def refresh_target_label(self):
        target = self.target
        if target and target.point is not None and win32gui.IsWindow(target.hwnd):
            text = target.name
        else:
            text = "Поле ещё не выбрано"
        self.target_label.set(text)

    def render_input(self):
        response = self.panel("Формат ответа")
        row = tk.Frame(response, bg=PANEL)
        row.pack(fill="x", pady=(0, 8))
        for key, title in (("rating", "Число 1–10"), ("reaction", "Лайк / дизлайк")):
            def choose(value=key):
                if self.active:
                    self.stop(quiet=True)
                self.kind.set(value)
                self.render()
            button(row, title, choose, selected=self.kind.get() == key).pack(side="left", padx=(0, 8))
        if self.kind.get() == "reaction":
            row = tk.Frame(response, bg=PANEL)
            row.pack(fill="x", pady=(0, 8))
            for i, (title, variable) in enumerate((("Лайк", self.like), ("Дизлайк", self.dislike))):
                row.columnconfigure(i, weight=1)
                field = tk.Frame(row, bg=PANEL)
                field.grid(row=0, column=i, sticky="ew", padx=(0, 10))
                label(field, title, color=MUTED).pack(fill="x")
                ttk.Entry(field, textvariable=variable).pack(fill="x")
        if self.mode == "voice":
            ttk.Checkbutton(response, text="Нажимать Enter после ввода", variable=self.enter).pack(anchor="w", pady=(2, 7))
            hint = "Например, «поставь пять»." if self.kind.get() == "rating" else "Например, «ну эту дизлайк» или «не нравится»."
        elif self.kind.get() == "rating":
            row = tk.Frame(response, bg=PANEL)
            row.pack(fill="x", pady=(0, 6))
            for title, variable in (("От", self.minimum), ("До", self.maximum)):
                label(row, title).pack(side="left", padx=(0, 4))
                ttk.Spinbox(row, from_=1, to=10, width=4, textvariable=variable).pack(side="left", padx=(0, 12))
            hint = "Рандомайзер оставляет черновик. Enter нажимаешь ты."
        else:
            self.scale(response, "Вероятность лайка", self.percent, 0, 100)
            hint = "Рандомайзер оставляет черновик. Enter нажимаешь ты."
        label(response, hint, color=MUTED, wrap=550).pack(fill="x")

        target = self.panel("Куда вводить")
        self.refresh_target_label()
        label(target, variable=self.target_label, color=MUTED, wrap=550).pack(fill="x", pady=(0, 7))
        row = tk.Frame(target, bg=PANEL)
        row.pack(fill="x")
        button(row, "Указать поле ввода", lambda: self.select("field")).pack(side="left", padx=(0, 8))
        if self.mode == "random":
            button(row, "Выделить карточку", lambda: self.select("card")).pack(side="left")
            self.scale(target, "Порог изменения карточки", self.threshold, 4, 20)
        label(target, "После нажатия открой нужное окно за 4 секунды.", color=MUTED).pack(fill="x", pady=(8, 0))
        button(target, "Остановить", self.stop).pack(anchor="w", pady=(8, 0))

    @staticmethod
    def scale(parent, title, variable, lower, upper):
        row = tk.Frame(parent, bg=PANEL)
        row.pack(fill="x", pady=(5, 0))
        label(row, title).pack(side="left", padx=(0, 7))
        tk.Scale(row, orient="horizontal", from_=lower, to=upper, resolution=1,
                 variable=variable, bg=PANEL, fg=INK, troughcolor=BACKGROUND,
                 activebackground=ACCENT, highlightthickness=0, length=170).pack(side="left")

    def select(self, purpose):
        self.stop(quiet=True)
        token = self.generation
        window_state = None

        def restore_window():
            if window_state is not None:
                self.root.state(window_state)

        def countdown(seconds):
            nonlocal window_state
            if token != self.generation:
                return
            if seconds:
                self.status.set(f"Открой нужное окно · {seconds}")
                self.root.after(1000, lambda: countdown(seconds - 1))
                return
            try:
                target = None if purpose == "face" else desktop.Target.current()
                title = {"face": "Обведи область экрана", "field": "Кликни в поле ввода", "card": "Обведи карточку"}[purpose]
                window_state = self.root.state()
                self.root.withdraw()
                self.picker = RegionPicker(self.root, purpose == "field", title,
                                           lambda selection: selected(target, selection))
            except Exception as error:
                restore_window()
                self.status.set(str(error))

        def selected(target, selection):
            self.picker = None
            try:
                if selection is None:
                    self.status.set("Выбор отменён")
                elif purpose == "face":
                    self.face_region = selection
                    restore_window()
                    self.start_watch()
                    return
                else:
                    self.save_target(target, purpose, selection)
            except Exception as error:
                self.status.set(str(error))
            restore_window()

        countdown(4)

    def save_target(self, target, purpose, selection):
        previous = self.target
        if previous and previous.hwnd == target.hwnd and previous.identity == target.identity:
            if desktop.size(previous.rect) == desktop.size(target.rect):
                dx = target.rect[0] - previous.rect[0]
                dy = target.rect[1] - previous.rect[1]
                if previous.point:
                    target.point = (previous.point[0] + dx, previous.point[1] + dy)
                    target.element_id = previous.element_id
                if previous.region:
                    a, b, c, d = previous.region
                    target.region = (a + dx, b + dy, c + dx, d + dy)
        if purpose == "field":
            if not desktop.contains(target.rect, selection):
                raise ValueError("Укажи поле внутри выбранного окна.")
            field = desktop.text_field(selection, target.identity[0])
            target.point = selection
            target.element_id = tuple(field.element_info.element.GetRuntimeId())
        else:
            a, b, c, d = selection
            if not desktop.contains(target.rect, (a, b)) or not desktop.contains(target.rect, (c - 1, d - 1)):
                raise ValueError("Выдели карточку внутри того же окна.")
            target.region = selection
        self.targets[self.kind.get()] = target
        self.refresh_target_label()
        self.status.set("Поле сохранено" if purpose == "field" else "Область карточки сохранена")

    def start_input(self):
        target = self.target
        if self.active:
            return
        if self.mode == "voice" and self.voice_thread and self.voice_thread.is_alive():
            self.status.set("Микрофон ещё останавливается. Попробуй через секунду.")
            return
        if not target or target.point is None or not win32gui.IsWindow(target.hwnd):
            self.status.set("Сначала укажи поле ввода")
            return
        if self.mode == "random" and target.region is None:
            self.status.set("Выдели область карточки")
            return
        try:
            rating = self.kind.get() == "rating"
            like, dislike = self.like.get().strip(), self.dislike.get().strip()
            if not rating and any(not text or len(text) > 80 or any(ord(c) < 32 for c in text)
                                  for text in (like, dislike)):
                raise ValueError("Задай две реакции длиной до 80 символов.")
            low, high = (int(self.minimum.get()), int(self.maximum.get())) if rating and self.mode == "random" else (1, 10)
            if not 1 <= low <= high <= 10:
                raise ValueError("Диапазон должен быть от 1 до 10.")
            self.save_settings()
        except (ValueError, OSError, tk.TclError) as error:
            self.status.set(str(error))
            return

        self.cancelled = threading.Event()
        self.active = "starting"
        token = self.generation
        mode = self.mode
        options = (rating, like, dislike, self.enter.get(), low, high, self.percent.get() / 100, self.threshold.get() / 100)

        def wait_for_window(seconds):
            if token != self.generation or self.cancelled.is_set():
                return
            if not win32gui.IsWindow(target.hwnd):
                self.fail(ValueError("Окно закрыто. Укажи поле заново."))
                return
            if seconds:
                self.status.set(f"Открой {target.name} · {seconds}")
                self.root.after(1000, lambda: wait_for_window(seconds - 1))
                return
            try:
                if target.position() is None:
                    self.status.set("Жду выбранное окно")
                    self.root.after(250, lambda: wait_for_window(0))
                    return
                self.running_target = target
                self.options = options
                self.active = mode
                if mode == "voice":
                    self.begin_voice(token, rating)
                else:
                    self.random_armed = True
                    self.committed = self.candidate = None
                    self.stable = 0
                    self.status.set("Жду стабильную карточку")
                    self.random_tick(token)
            except Exception as error:
                self.fail(error)

        wait_for_window(4)

    def begin_voice(self, token, rating):
        self.status.set("Загружаю модель речи")
        cancelled = self.cancelled

        def work():
            try:
                voice.listen(MODELS / "vosk-model-small-ru-0.22", rating, cancelled,
                             lambda event, value: self.events.put((event, token, value)))
            except Exception as error:
                self.events.put(("error", token, error))

        self.voice_thread = threading.Thread(target=work, daemon=True)
        self.voice_thread.start()

    def random_tick(self, token):
        if token != self.generation or self.cancelled.is_set():
            return
        try:
            target = self.running_target
            if self.random_armed and target.position() is not None:
                frame = fingerprint(desktop.capture(target.offset(target.region)))
                rating, like, dislike, _, low, high, probability, threshold = self.options
                changed = self.committed is None or distance(frame, self.committed) >= threshold
                if frame.var() <= 0.002 or not changed:
                    self.stable, self.candidate = 0, None
                else:
                    self.stable = self.stable + 1 if self.candidate is not None and distance(frame, self.candidate) < 0.025 else 1
                    self.candidate = frame
                    if self.stable >= 3:
                        answer = str(random.randint(low, high)) if rating else (like if random.random() < probability else dislike)
                        self.writer.write(target, answer, False, self.cancelled)
                        self.committed, self.random_armed = frame, False
                        self.status.set(f"Черновик {answer} · нажми Enter")
        except Exception as error:
            self.fail(error)
            return
        self.root.after(260, lambda: self.random_tick(token))

    def poll_events(self):
        while True:
            try:
                event, token, value = self.events.get_nowait()
            except Empty:
                break
            if event == "stop":
                self.stop()
            elif event == "enter":
                if self.active == "random" and value == self.running_target.hwnd and not self.random_armed:
                    self.random_armed = True
                    self.stable, self.candidate = 0, None
                    self.status.set("Жду изменения карточки")
            elif token == self.generation:
                if event == "error":
                    self.fail(value)
                elif event == "ready":
                    self.status.set(value)
                elif event == "heard":
                    self.status.set(f"Распознано · {value[-120:]}")
                elif event == "command":
                    if value == "stop":
                        self.stop()
                    elif self.active == "voice":
                        try:
                            if self.running_target.position() is None:
                                self.status.set("Вернись в выбранное окно")
                                continue
                            _, like, dislike, enter, *_ = self.options
                            answer = {"like": like, "dislike": dislike}.get(value, value)
                            self.writer.write(self.running_target, answer, enter, self.cancelled)
                            self.status.set(f"Введено · {answer}")
                        except Exception as error:
                            self.fail(error)
                elif event == "face":
                    self.face_pending = False
                    self.face_result = value
                    self.face_index.set("1")
                    count = len(value[1]["faces"])
                    if self.watched is None or not self.watch_blocked:
                        self.status.set(f"Лиц на изображении: {count}" if count else "Лица не найдены")
                    self.update_preview()
        self.root.after(45, self.poll_events)

    def fail(self, error):
        self.stop(quiet=True)
        self.status.set(str(error))

    def stop(self, quiet=False):
        self.generation += 1
        self.cancelled.set()
        self.active = None
        self.watched = None
        self.face_pending = False
        if self.picker:
            picker, self.picker = self.picker, None
            picker.finish(None)
        if not quiet:
            self.status.set("Остановлено")

    def render_faces(self):
        preview = self.panel("Фото и разметка")
        row = tk.Frame(preview, bg=PANEL)
        row.pack(fill="x")
        for title, action in (("Выделить область", lambda: self.select("face")),
                              ("Продолжить", self.start_watch), ("Остановить", self.stop)):
            button(row, title, action).pack(side="left", padx=(0, 7))
        self.preview = label(preview, "Карта лица появится после анализа", color=MUTED,
                             background=BACKGROUND, wrap=520)
        self.preview.pack(fill="x", pady=(10, 8), ipady=12)
        row = tk.Frame(preview, bg=PANEL)
        row.pack(fill="x")
        ttk.Checkbutton(row, text="Показать карту лица", variable=self.show_map,
                        command=self.update_preview).pack(side="left")
        self.face_selector = ttk.Combobox(row, state="readonly", width=4, textvariable=self.face_index)
        self.face_selector.pack(side="left", padx=10)
        self.face_selector.bind("<<ComboboxSelected>>", lambda _: self.update_preview())
        button(row, "Сохранить разбор", self.save_report).pack(side="right")

        refs = self.panel("Сравнение с эталонами")
        row = tk.Frame(refs, bg=PANEL)
        row.pack(fill="x")
        kind = ttk.Combobox(row, state="readonly", width=14, textvariable=self.face_kind,
                            values=("Фотографии", "Рисунки"))
        kind.pack(side="left", padx=(0, 8))
        kind.bind("<<ComboboxSelected>>", lambda _: self.update_preview())
        ttk.Combobox(row, state="readonly", width=10, textvariable=self.face_tier,
                     values=faces.TIERS).pack(side="left", padx=(0, 8))
        button(row, "Добавить эталон", self.add_reference).pack(side="left", padx=(0, 8))
        button(row, "Мои эталоны", self.manage_references).pack(side="left")
        label(refs, variable=self.reference_status, wrap=530).pack(fill="x", pady=(9, 0))
        self.neighbors = tk.Frame(refs, bg=PANEL)
        self.neighbors.pack(fill="x", pady=(7, 0))
        label(refs, "Категории показывают сходство с твоими эталонами.", color=MUTED).pack(fill="x", pady=(5, 0))
        self.update_preview()

    def open_photo(self):
        self.stop(quiet=True)
        path = filedialog.askopenfilename(parent=self.root, title="Открыть фото",
                                         filetypes=[("Изображения", "*.jpg *.jpeg *.png *.webp *.bmp *.tif *.tiff"),
                                                    ("Все файлы", "*.*")])
        if not path:
            return
        self.status.set("Анализирую фото")
        self.analyze(Path(path), self.generation)

    def analyze(self, source, token):
        self.face_pending = True

        def work():
            if isinstance(source, Path):
                with Image.open(source) as image:
                    return faces.analyze(image, MODELS / "face_landmarker.task")
            return faces.analyze(source, MODELS / "face_landmarker.task")

        def done(job):
            try:
                self.events.put(("face", token, job.result()))
            except Exception as error:
                self.events.put(("error", token, error))

        self.executor.submit(work).add_done_callback(done)

    def start_watch(self):
        if self.face_region is None:
            self.status.set("Сначала выдели область экрана")
            return
        self.stop(quiet=True)
        self.watched = self.face_region
        self.watch_frame = self.watch_candidate = None
        self.watch_blocked = False
        self.status.set("Наблюдаю за областью экрана")
        self.watch_tick(self.generation)

    def watch_tick(self, token):
        if token != self.generation or self.watched is None:
            return
        try:
            blocked = self.covers_region(self.watched)
            if blocked != self.watch_blocked:
                self.watch_blocked = blocked
                self.watch_candidate = None
                self.status.set("Окно VoicePick перекрывает область. Передвинь или сверни его."
                                if blocked else "Наблюдаю за областью экрана")
            if not blocked and not self.face_pending:
                image = desktop.capture(self.watched)
                frame = fingerprint(image)
                changed = self.watch_frame is None or distance(frame, self.watch_frame) >= 0.04
                stable = self.watch_candidate is not None and distance(frame, self.watch_candidate) < 0.025
                self.watch_candidate = frame
                if changed and stable:
                    self.watch_frame = frame
                    self.analyze(image, token)
        except Exception as error:
            self.fail(error)
            return
        self.root.after(650, lambda: self.watch_tick(token))

    def covers_region(self, region):
        if self.root.state() != "normal" and self.root.state() != "zoomed":
            return False
        hwnd = win32gui.GetAncestor(self.root.winfo_id(), win32con.GA_ROOT)
        a, b, c, d = desktop.bounds(hwnd)
        x, y, right, bottom = region
        return a < right and b < bottom and c > x and d > y

    @property
    def image_kind(self):
        return "photo" if self.face_kind.get() == "Фотографии" else "drawing"

    def current_crop(self):
        image, report = self.face_result
        return faces.face_crop(image, report, int(self.face_index.get()) - 1)

    def update_preview(self):
        self.face_images = []
        for child in self.neighbors.winfo_children():
            child.destroy()
        entries = [entry for entry in self.bank.entries if entry["kind"] == self.image_kind] if self.bank else []
        coverage = len({entry["tier"] for entry in entries})
        summary = f"Эталонов: {len(entries)} · категорий: {coverage} из {len(faces.TIERS)}"
        if self.bank is None:
            summary = "Не удалось открыть локальную базу эталонов."
        self.reference_status.set(summary)
        if self.face_result is None:
            return
        image, report = self.face_result
        count = len(report["faces"])
        index = min(max(int(self.face_index.get()) - 1, 0), max(0, count - 1))
        self.face_selector.configure(values=tuple(str(i + 1) for i in range(count)))
        preview = faces.draw_preview(image, report, index, self.show_map.get(), (540, 300))
        photo = ImageTk.PhotoImage(preview, master=self.root)
        self.face_images.append(photo)
        self.preview.configure(image=photo, text="")
        if not count or self.bank is None:
            return
        try:
            category, nearest, reason = self.bank.compare(self.current_crop(), self.image_kind)
            if category:
                result = f"Категория · {category}"
            elif nearest:
                result = f"Ближайшая категория · {nearest[0][0]['tier']}"
            else:
                result = ""
            self.reference_status.set("\n".join(text for text in (summary, result, reason) if text))
            for entry, delta in nearest:
                self.thumbnail(self.neighbors, entry, f"{entry['tier']} · {delta:.3f}")
        except (ValueError, OSError, KeyError) as error:
            self.reference_status.set(f"{summary}\n{error}")

    def thumbnail(self, parent, entry, caption):
        tile = tk.Frame(parent, bg=PANEL)
        tile.pack(side="left", padx=(0, 12), pady=2)
        with Image.open(io.BytesIO(base64.b64decode(entry["thumbnail"], validate=True))) as image:
            image.thumbnail((78, 78))
            photo = ImageTk.PhotoImage(image, master=self.root)
        picture = label(tile, "")
        picture.configure(image=photo)
        picture.image = photo
        picture.pack()
        label(tile, caption, size=9, color=MUTED).pack()

    def add_reference(self):
        if self.bank is None:
            return
        if not self.face_result or not self.face_result[1]["faces"]:
            self.reference_status.set("Дождись кадра с лицом или открой фото.")
            return
        try:
            crop = self.current_crop()
            tier = self.face_tier.get()
            self.bank.add(crop, tier, self.image_kind)
            self.update_preview()
            self.reference_status.set(f"{self.reference_status.get()}\nЭталон {tier} добавлен")
        except (OSError, ValueError) as error:
            self.reference_status.set(str(error))

    def manage_references(self):
        if self.bank is None:
            return
        dialog = tk.Toplevel(self.root)
        dialog.title("Мои эталоны")
        dialog.configure(bg=PANEL, padx=14, pady=14)
        dialog.transient(self.root)
        entries = [entry for entry in self.bank.entries if entry["kind"] == self.image_kind]
        rows = tk.Listbox(dialog, bg=BACKGROUND, fg=INK, width=36, height=12, exportselection=False)
        rows.pack(side="left", fill="both", expand=True, padx=(0, 12))
        controls = tk.Frame(dialog, bg=PANEL)
        controls.pack(side="left", fill="y")
        photo_label = label(controls, "Выбери эталон")
        photo_label.pack(pady=(0, 8))
        for i, entry in enumerate(entries):
            rows.insert("end", f"{i + 1}. {entry['tier']}")

        def show(_):
            if rows.curselection():
                entry = entries[rows.curselection()[0]]
                try:
                    with Image.open(io.BytesIO(base64.b64decode(entry["thumbnail"], validate=True))) as image:
                        photo_label.image = ImageTk.PhotoImage(image, master=dialog)
                    photo_label.configure(image=photo_label.image, text="")
                except (ValueError, OSError):
                    photo_label.configure(image="", text="Миниатюра недоступна")

        def delete():
            if not rows.curselection():
                return
            index = rows.curselection()[0]
            if messagebox.askyesno("Удалить эталон?", "Удалить выбранный эталон из локальной базы?", parent=dialog):
                try:
                    self.bank.remove(entries[index]["id"])
                    del entries[index]
                    rows.delete(index)
                    photo_label.configure(image="", text="Выбери эталон")
                    self.update_preview()
                except OSError as error:
                    messagebox.showerror("VoicePick", str(error), parent=dialog)

        rows.bind("<<ListboxSelect>>", show)
        button(controls, "Удалить", delete).pack(anchor="w")

    def save_report(self):
        if not self.face_result:
            self.status.set("Сначала открой фото или выбери область экрана")
            return
        path = filedialog.asksaveasfilename(parent=self.root, defaultextension=".json",
                                            initialfile="voicepick-face.json", filetypes=[("JSON", "*.json")])
        if not path:
            return
        try:
            report = dict(self.face_result[1])
            if report["faces"] and self.bank is not None:
                category, nearest, explanation = self.bank.compare(self.current_crop(), self.image_kind)
                report["match"] = {"method": faces.METHOD, "category": category,
                                   "nearest": [{"tier": item["tier"], "distance": value} for item, value in nearest],
                                   "explanation": explanation}
            Path(path).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            self.status.set("Разбор сохранён")
        except (OSError, ValueError) as error:
            self.status.set(str(error))

    def close(self):
        self.stop(quiet=True)
        try:
            self.save_settings()
        except (OSError, tk.TclError):
            pass
        self.listener.stop()
        self.executor.shutdown(wait=False, cancel_futures=True)
        self.root.destroy()


def main():
    desktop.enable_dpi_awareness()
    root = tk.Tk()
    VoicePick(root)
    root.mainloop()


if __name__ == "__main__":
    main()
