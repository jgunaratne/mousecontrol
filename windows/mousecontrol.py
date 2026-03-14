#!/usr/bin/env python3
"""
MouseControl — Windows Companion Client

Connects to the macOS MouseControl app over a USB-C TCP connection.
Captures screenshots on demand and injects mouse/keyboard actions
as directed by the AI agent running on the Mac.

Runs in the Windows system tray with status icon and right-click menu.

Dependencies:
    pip install -r requirements.txt

Usage:
    pythonw mousecontrol.py      # No console window (recommended)
    python  mousecontrol.py      # With console for debugging
"""

import asyncio
import base64
import ctypes
import ctypes.wintypes
import io
import json
import logging
import struct
import sys
import threading

# ── Configuration ──────────────────────────────────────────────────────

MAC_IP = "192.168.100.1"
PORT = 9877

# Seconds to wait before retrying after a dropped connection.
RECONNECT_DELAY = 2.0

# ── Logging ────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("mousecontrol")

# ── Win32 API Constants ────────────────────────────────────────────────

INPUT_MOUSE = 0
INPUT_KEYBOARD = 1

MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_ABSOLUTE = 0x8000
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_HWHEEL = 0x1000

KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_EXTENDEDKEY = 0x0001

SM_CXSCREEN = 0
SM_CYSCREEN = 1

WHEEL_DELTA = 120

# ── Win32 API Structures ──────────────────────────────────────────────

class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.wintypes.LONG),
        ("dy", ctypes.wintypes.LONG),
        ("mouseData", ctypes.wintypes.DWORD),
        ("dwFlags", ctypes.wintypes.DWORD),
        ("time", ctypes.wintypes.DWORD),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]

class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", ctypes.wintypes.WORD),
        ("wScan", ctypes.wintypes.WORD),
        ("dwFlags", ctypes.wintypes.DWORD),
        ("time", ctypes.wintypes.DWORD),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]

class _INPUTunion(ctypes.Union):
    _fields_ = [
        ("mi", MOUSEINPUT),
        ("ki", KEYBDINPUT),
    ]

class INPUT(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.wintypes.DWORD),
        ("union", _INPUTunion),
    ]

# ── Win32 API Functions ───────────────────────────────────────────────

user32 = ctypes.windll.user32
SendInput = user32.SendInput
SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]
SendInput.restype = ctypes.c_uint
SetCursorPos = user32.SetCursorPos
GetSystemMetrics = user32.GetSystemMetrics

SCREEN_WIDTH = GetSystemMetrics(SM_CXSCREEN)
SCREEN_HEIGHT = GetSystemMetrics(SM_CYSCREEN)

# ── Key Name to VK Code Mapping ───────────────────────────────────────

VK_MAP = {
    "ctrl": 0xA2, "lctrl": 0xA2, "rctrl": 0xA3,
    "alt": 0xA4, "lalt": 0xA4, "ralt": 0xA5,
    "shift": 0xA0, "lshift": 0xA0, "rshift": 0xA1,
    "super": 0x5B, "win": 0x5B, "lwin": 0x5B, "rwin": 0x5C,
    "enter": 0x0D, "return": 0x0D,
    "tab": 0x09, "escape": 0x1B, "esc": 0x1B,
    "backspace": 0x08, "delete": 0x2E,
    "space": 0x20,
    "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27,
    "home": 0x24, "end": 0x23,
    "pageup": 0x21, "pagedown": 0x22,
    "insert": 0x2D,
    "f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73,
    "f5": 0x74, "f6": 0x75, "f7": 0x76, "f8": 0x77,
    "f9": 0x78, "f10": 0x79, "f11": 0x7A, "f12": 0x7B,
    "capslock": 0x14, "numlock": 0x90,
}

EXTENDED_VK = {
    0x2D, 0x2E, 0x24, 0x23, 0x21, 0x22,  # insert, delete, home, end, pageup, pagedown
    0x25, 0x26, 0x27, 0x28,  # arrow keys
    0x5B, 0x5C,  # win keys
    0xA3, 0xA5,  # right ctrl, right alt
    0x6F,  # numpad divide
}

# ── Input Helpers ─────────────────────────────────────────────────────

_connection_status = "Disconnected"


def _send_mouse_input(flags: int, dx: int = 0, dy: int = 0, data: int = 0):
    mi = MOUSEINPUT(
        dx=dx, dy=dy,
        mouseData=ctypes.wintypes.DWORD(data & 0xFFFFFFFF),
        dwFlags=ctypes.wintypes.DWORD(flags),
        time=0, dwExtraInfo=None,
    )
    inp = INPUT(type=INPUT_MOUSE)
    inp.union.mi = mi
    SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def _send_key_input(vk: int, down: bool):
    flags = 0
    if not down:
        flags |= KEYEVENTF_KEYUP
    if vk in EXTENDED_VK:
        flags |= KEYEVENTF_EXTENDEDKEY
    ki = KEYBDINPUT(
        wVk=ctypes.wintypes.WORD(vk), wScan=0,
        dwFlags=ctypes.wintypes.DWORD(flags),
        time=0, dwExtraInfo=None,
    )
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.union.ki = ki
    SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def _vk_for_key(name: str) -> int | None:
    """Get the VK code for a key name."""
    lower = name.lower()
    if lower in VK_MAP:
        return VK_MAP[lower]
    # Single character → use its VK code
    if len(name) == 1:
        vk = ctypes.windll.user32.VkKeyScanW(ord(name))
        if vk != -1:
            return vk & 0xFF
    return None


# ── Screenshot Capture ────────────────────────────────────────────────

def capture_screenshot() -> tuple[str, int, int]:
    """Capture the entire screen and return (base64_png, width, height)."""
    try:
        import mss
        from PIL import Image
        
        with mss.mss() as sct:
            monitor = sct.monitors[1]
            screenshot = sct.grab(monitor)
            
            img = Image.frombytes("RGB", screenshot.size, screenshot.bgra, "raw", "BGRX")
            buf = io.BytesIO()
            img.save(buf, format="PNG", optimize=True)
            png_bytes = buf.getvalue()
            
            b64 = base64.b64encode(png_bytes).decode("ascii")
            log.info(
                "Screenshot captured: %dx%d (%d KB)",
                screenshot.width, screenshot.height,
                len(png_bytes) // 1024,
            )
            return (b64, screenshot.width, screenshot.height)
    except Exception as exc:
        log.error("Screenshot capture failed: %s", exc)
        raise


# ── Action Injection ──────────────────────────────────────────────────

def inject_action(event: dict) -> dict:
    """Execute an AI-directed action on this machine."""
    action = event.get("action")
    
    try:
        if action == "mouseMove":
            nx = event.get("normalizedX", 0.5)
            ny = event.get("normalizedY", 0.5)
            x = int(nx * SCREEN_WIDTH)
            y = int(ny * SCREEN_HEIGHT)
            x = max(0, min(x, SCREEN_WIDTH - 1))
            y = max(0, min(y, SCREEN_HEIGHT - 1))
            abs_x = int(x * 65535 / (SCREEN_WIDTH - 1)) if SCREEN_WIDTH > 1 else 0
            abs_y = int(y * 65535 / (SCREEN_HEIGHT - 1)) if SCREEN_HEIGHT > 1 else 0
            _send_mouse_input(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, dx=abs_x, dy=abs_y)
            log.info("mouseMove → (%d, %d)", x, y)
            return {"success": True}
            
        elif action == "click":
            nx = event.get("normalizedX", 0.5)
            ny = event.get("normalizedY", 0.5)
            x = int(nx * SCREEN_WIDTH)
            y = int(ny * SCREEN_HEIGHT)
            x = max(0, min(x, SCREEN_WIDTH - 1))
            y = max(0, min(y, SCREEN_HEIGHT - 1))
            
            # Move to position first
            abs_x = int(x * 65535 / (SCREEN_WIDTH - 1)) if SCREEN_WIDTH > 1 else 0
            abs_y = int(y * 65535 / (SCREEN_HEIGHT - 1)) if SCREEN_HEIGHT > 1 else 0
            _send_mouse_input(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, dx=abs_x, dy=abs_y)
            
            button = event.get("button", "left")
            count = event.get("clickCount", 1)
            
            for _ in range(count):
                if button == "left":
                    _send_mouse_input(MOUSEEVENTF_LEFTDOWN)
                    _send_mouse_input(MOUSEEVENTF_LEFTUP)
                elif button == "right":
                    _send_mouse_input(MOUSEEVENTF_RIGHTDOWN)
                    _send_mouse_input(MOUSEEVENTF_RIGHTUP)
                elif button == "middle":
                    _send_mouse_input(MOUSEEVENTF_MIDDLEDOWN)
                    _send_mouse_input(MOUSEEVENTF_MIDDLEUP)
            
            log.info("click (%s, ×%d) → (%d, %d)", button, count, x, y)
            return {"success": True}
            
        elif action == "type":
            text = event.get("text", "")
            if not text:
                return {"success": True}
            
            # Use SendInput with Unicode characters
            for char in text:
                # KEYEVENTF_UNICODE = 0x0004
                ki_down = KEYBDINPUT(
                    wVk=0, wScan=ctypes.wintypes.WORD(ord(char)),
                    dwFlags=ctypes.wintypes.DWORD(0x0004),  # KEYEVENTF_UNICODE
                    time=0, dwExtraInfo=None,
                )
                inp_down = INPUT(type=INPUT_KEYBOARD)
                inp_down.union.ki = ki_down
                
                ki_up = KEYBDINPUT(
                    wVk=0, wScan=ctypes.wintypes.WORD(ord(char)),
                    dwFlags=ctypes.wintypes.DWORD(0x0004 | KEYEVENTF_KEYUP),
                    time=0, dwExtraInfo=None,
                )
                inp_up = INPUT(type=INPUT_KEYBOARD)
                inp_up.union.ki = ki_up
                
                inputs = (INPUT * 2)(inp_down, inp_up)
                SendInput(2, inputs, ctypes.sizeof(INPUT))
            
            log.info("type → '%s'", text[:50] + ("…" if len(text) > 50 else ""))
            return {"success": True}
            
        elif action == "keyCombo":
            keys = event.get("keys", [])
            if not keys:
                return {"success": True}
            
            vk_codes = []
            for key in keys:
                vk = _vk_for_key(key)
                if vk is not None:
                    vk_codes.append(vk)
                else:
                    log.warning("Unknown key: %s", key)
            
            # Press all keys down
            for vk in vk_codes:
                _send_key_input(vk, down=True)
            # Release in reverse order
            for vk in reversed(vk_codes):
                _send_key_input(vk, down=False)
            
            log.info("keyCombo → %s", "+".join(keys))
            return {"success": True}
            
        elif action == "scroll":
            dx = event.get("scrollDeltaX", 0)
            dy = event.get("scrollDeltaY", 0)
            if dy:
                _send_mouse_input(MOUSEEVENTF_WHEEL, data=int(dy * WHEEL_DELTA))
            if dx:
                _send_mouse_input(MOUSEEVENTF_HWHEEL, data=int(dx * WHEEL_DELTA))
            log.info("scroll → (dx=%s, dy=%s)", dx, dy)
            return {"success": True}
            
        elif action in ("wait", "done", None):
            return {"success": True}
            
        else:
            log.warning("Unknown action: %s", action)
            return {"success": False, "error": f"Unknown action: {action}"}
            
    except Exception as exc:
        log.error("Action failed: %s — %s", action, exc)
        return {"success": False, "error": str(exc)}


# ── TCP Client ────────────────────────────────────────────────────────

async def _read_exact(reader: asyncio.StreamReader, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = await reader.read(n - len(data))
        if not chunk:
            raise ConnectionError("Connection closed by remote")
        data += chunk
    return data


async def tcp_client(tray_update=None):
    """Connect to the Mac and process commands. Reconnects on failure."""
    global _connection_status

    while True:
        writer = None
        try:
            _connection_status = "Connecting…"
            if tray_update:
                tray_update()

            log.info("Connecting to Mac at %s:%d …", MAC_IP, PORT)
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(MAC_IP, PORT),
                timeout=5.0,
            )
            log.info("Connected to Mac")
            _connection_status = "Connected"
            if tray_update:
                tray_update()

            while True:
                header = await asyncio.wait_for(
                    _read_exact(reader, 4), timeout=120.0,
                )
                length = struct.unpack("!I", header)[0]
                if length == 0 or length > 10_000_000:
                    log.warning("Invalid message length: %d", length)
                    break

                payload = await asyncio.wait_for(
                    _read_exact(reader, length), timeout=10.0,
                )
                message = json.loads(payload.decode("utf-8"))

                # Process the message
                response = handle_message(message)
                
                if response:
                    ret_payload = json.dumps(response).encode("utf-8")
                    ret_header = struct.pack("!I", len(ret_payload))
                    writer.write(ret_header + ret_payload)
                    await writer.drain()

        except asyncio.TimeoutError:
            log.warning("Connection timed out")
        except (ConnectionError, OSError, asyncio.IncompleteReadError) as exc:
            log.warning("Connection lost: %s", exc)
        except Exception as exc:
            log.error("Unexpected error: %s", exc, exc_info=True)
        finally:
            _connection_status = "Disconnected"
            if tray_update:
                tray_update()
            if writer is not None:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass

        log.info("Reconnecting in %.0f seconds …", RECONNECT_DELAY)
        await asyncio.sleep(RECONNECT_DELAY)


def handle_message(message: dict) -> dict | None:
    """Process a message from the Mac and return a response."""
    msg_type = message.get("type")
    
    if msg_type == "requestScreenshot":
        log.info("Screenshot requested by Mac")
        try:
            b64, w, h = capture_screenshot()
            return {
                "type": "screenshotData",
                "imageBase64": b64,
                "width": w,
                "height": h,
            }
        except Exception as exc:
            return {
                "type": "actionResult",
                "success": False,
                "error": f"Screenshot failed: {exc}",
            }
    
    elif msg_type == "executeAction":
        result = inject_action(message)
        return {"type": "actionResult", **result}
    
    elif msg_type == "heartbeat":
        log.debug("Heartbeat received")
        return None
    
    else:
        log.warning("Unknown message type: %s", msg_type)
        return None


# ── System Tray ───────────────────────────────────────────────────────

def _create_tray_icon():
    """Create and return a pystray Icon for the system tray."""
    try:
        import pystray
        from PIL import Image, ImageDraw
    except ImportError:
        log.warning("pystray/Pillow not installed — running without tray icon.")
        return None

    def _make_icon(color="green"):
        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        colors = {
            "green": (76, 175, 80),
            "yellow": (255, 193, 7),
            "red": (158, 158, 158),
        }
        fill = colors.get(color, colors["red"])
        draw.ellipse([8, 8, 56, 56], fill=(*fill, 255))
        return img

    def on_quit(icon, item):
        icon.stop()
        sys.exit(0)

    def _update_icon(icon):
        if _connection_status == "Connected":
            icon.icon = _make_icon("green")
        elif _connection_status == "Connecting…":
            icon.icon = _make_icon("yellow")
        else:
            icon.icon = _make_icon("red")
        icon.title = f"MouseControl — {_connection_status}"

    menu = pystray.Menu(
        pystray.MenuItem(
            lambda _: f"Status: {_connection_status}",
            action=None, enabled=False,
        ),
        pystray.MenuItem(
            lambda _: f"Mac: {MAC_IP}:{PORT}",
            action=None, enabled=False,
        ),
        pystray.MenuItem(
            lambda _: f"Screen: {SCREEN_WIDTH}×{SCREEN_HEIGHT}",
            action=None, enabled=False,
        ),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit MouseControl", on_quit),
    )

    icon = pystray.Icon(
        "MouseControl",
        _make_icon("red"),
        "MouseControl — Disconnected",
        menu,
    )
    return icon, _update_icon


# ── Main ──────────────────────────────────────────────────────────────

def main():
    log.info("MouseControl Windows Companion starting …")
    log.info("Screen resolution: %dx%d", SCREEN_WIDTH, SCREEN_HEIGHT)
    log.info("Will connect to Mac at %s:%d", MAC_IP, PORT)

    tray_result = _create_tray_icon()

    if tray_result:
        icon, update_fn = tray_result

        def run_async_client():
            def tray_update():
                try:
                    update_fn(icon)
                except Exception:
                    pass
            try:
                asyncio.run(tcp_client(tray_update=tray_update))
            except Exception as exc:
                log.error("Client thread error: %s", exc)

        client_thread = threading.Thread(target=run_async_client, daemon=True)
        client_thread.start()
        icon.run()
    else:
        try:
            asyncio.run(tcp_client())
        except KeyboardInterrupt:
            log.info("Shutting down …")
        log.info("Goodbye.")


if __name__ == "__main__":
    main()
