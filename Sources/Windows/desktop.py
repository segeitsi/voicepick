"""Windows capture and input restricted to the selected window and text field."""
import ctypes
from ctypes import wintypes
from dataclasses import dataclass
import os
import time

import win32api
import win32con
import win32gui
import win32process
from PIL import ImageGrab
from pywinauto import Desktop
from pywinauto.keyboard import send_keys

user32 = ctypes.WinDLL("user32", use_last_error=True)


def enable_dpi_awareness():
    user32.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))


def foreground():
    return win32gui.GetForegroundWindow()


def bounds(hwnd):
    return win32gui.GetWindowRect(hwnd)


def contains(rect, point):
    x, y = point
    return rect[0] <= x < rect[2] and rect[1] <= y < rect[3]


def capture(rect):
    return ImageGrab.grab(bbox=tuple(rect), all_screens=True).convert("RGB")


def size(rect):
    return rect[2] - rect[0], rect[3] - rect[1]


def window_identity(hwnd):
    if not hwnd or not win32gui.IsWindow(hwnd):
        raise ValueError("Открой нужное окно на переднем плане.")
    _, pid = win32process.GetWindowThreadProcessId(hwnd)
    if pid == os.getpid():
        raise ValueError("Выбери окно, в которое нужно вводить ответ.")
    return pid, win32gui.GetClassName(hwnd)


@dataclass
class Target:
    hwnd: int
    identity: tuple
    rect: tuple
    point: tuple | None = None
    region: tuple | None = None
    element_id: tuple | None = None

    @classmethod
    def current(cls):
        hwnd = foreground()
        return cls(hwnd, window_identity(hwnd), bounds(hwnd))

    @property
    def name(self):
        return win32gui.GetWindowText(self.hwnd) or "Выбранное окно"

    def position(self):
        if foreground() != self.hwnd:
            return None
        if window_identity(self.hwnd) != self.identity:
            return None
        current = bounds(self.hwnd)
        if size(current) != size(self.rect):
            raise ValueError("Размер окна изменился. Укажи поле и область заново.")
        return current

    def offset(self, coordinates):
        current = self.position()
        if current is None:
            raise ValueError("Вернись в выбранное окно.")
        dx, dy = current[0] - self.rect[0], current[1] - self.rect[1]
        return tuple(value + (dx if index % 2 == 0 else dy)
                     for index, value in enumerate(coordinates))


def text_field(point, pid):
    hwnd = win32gui.WindowFromPoint(point)
    if not hwnd or win32process.GetWindowThreadProcessId(hwnd)[1] != pid:
        raise ValueError("Поле перекрыто другим окном.")
    wrapper = Desktop(backend="uia").from_point(*point)
    while wrapper is not None:
        element = wrapper.element_info.element
        if element.CurrentIsPassword or element.CurrentProcessId != pid:
            break
        if wrapper.element_info.control_type in ("Edit", "Document"):
            if element.CurrentIsEnabled and element.CurrentIsKeyboardFocusable:
                field_value(wrapper)
                return wrapper
            break
        wrapper = wrapper.parent()
    raise ValueError("Windows не видит обычное поле ввода в этой точке.")


def field_value(field):
    from pywinauto.uia_defines import NoPatternInterface

    try:
        value = field.iface_value
    except NoPatternInterface:
        if field.element_info.control_type != "Edit":
            raise ValueError("Это поле не поддерживает проверку ввода.")
        try:
            return field.iface_text.DocumentRange.GetText(-1).rstrip("\r\n")
        except NoPatternInterface as error:
            raise ValueError("Windows не даёт прочитать это поле.") from error
    if value.CurrentIsReadOnly:
        raise ValueError("Поле доступно только для чтения.")
    return value.CurrentValue


class KeyboardInput(ctypes.Structure):
    _fields_ = [("vk", wintypes.WORD), ("scan", wintypes.WORD),
                ("flags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("extra", ctypes.c_size_t)]


class MouseInput(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG),
                ("data", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("extra", ctypes.c_size_t)]


class InputData(ctypes.Union):
    _fields_ = [("keyboard", KeyboardInput), ("mouse", MouseInput)]


class Input(ctypes.Structure):
    _fields_ = [("kind", wintypes.DWORD), ("data", InputData)]


def type_unicode(text):
    encoded = text.encode("utf-16-le")
    units = [int.from_bytes(encoded[i:i+2], "little") for i in range(0, len(encoded), 2)]
    events = [Input(1, InputData(keyboard=KeyboardInput(0, unit, flag, 0, 0)))
              for unit in units for flag in (4, 6)]
    array = (Input * len(events))(*events)
    user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(Input), ctypes.c_int]
    user32.SendInput.restype = wintypes.UINT
    if user32.SendInput(len(events), array, ctypes.sizeof(Input)) != len(events):
        raise ValueError("Windows заблокировала ввод. Запускай оба приложения без повышения прав.")


def modifiers_down():
    return any(win32api.GetAsyncKeyState(key) & 0x8000
               for key in (win32con.VK_CONTROL, win32con.VK_MENU, win32con.VK_SHIFT, 0x5B, 0x5C))


def normalized(text):
    return text.strip().replace("\ufe0e", "").replace("\ufe0f", "")


def matches(actual, expected):
    if expected.endswith(" ") and not actual.endswith(" "):
        return False
    if normalized(actual) == normalized(expected):
        return True
    return normalized(actual) == "\ufffc" and any(ord(c) > 0x2000 for c in expected)


class Writer:
    def __init__(self):
        self.draft = None

    def write(self, target, answer, enter, cancelled):
        if cancelled.is_set():
            return
        if modifiers_down():
            raise ValueError("Отпусти Ctrl, Alt и Shift перед вводом.")
        point = target.offset(target.point)
        field = text_field(point, target.identity[0])
        identity = tuple(field.element_info.element.GetRuntimeId())
        if identity != target.element_id:
            raise ValueError("Поле изменилось. Выбери его заново.")
        field.set_focus()

        def read():
            if cancelled.is_set() or target.position() is None:
                raise ValueError("Ввод остановлен: окно сменилось.")
            active = Desktop(backend="uia").get_active()
            if active.element_info != field.element_info:
                raise ValueError("Ввод остановлен: фокус ушёл из поля.")
            return field_value(active)

        original = read()
        if original.strip():
            if self.draft != (target.hwnd, identity, original):
                raise ValueError("Поле уже содержит текст. Очисти его перед вводом.")
            send_keys("^a{BACKSPACE}", pause=0)
            if read().strip():
                raise ValueError("Поле не очистилось. Проверь его вручную.")
        if read().strip():
            raise ValueError("Поле уже содержит текст.")
        payload = answer + (" " if any(ord(c) > 0x2000 for c in answer) else "")
        type_unicode(payload)
        for _ in range(12):
            current = read()
            if matches(current, payload):
                self.draft = (target.hwnd, identity, current)
                break
            time.sleep(0.04)
        else:
            raise ValueError("Не удалось проверить вставку. Проверь поле вручную.")
        if enter:
            if read() != current or modifiers_down():
                raise ValueError("Содержимое поля изменилось. Проверь ответ вручную.")
            send_keys("{ENTER}", pause=0)
            self.draft = None
