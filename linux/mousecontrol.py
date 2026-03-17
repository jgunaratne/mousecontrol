#!/usr/bin/env python3
"""
MouseControl — Linux Companion Daemon

Connects to the macOS MouseControl app over a USB-C TCP connection.
Captures screenshots on demand and injects mouse/keyboard actions
as directed by the AI agent running on the Mac.

Dependencies:
    pip3 install mss Pillow
    sudo apt install xdotool        # X11
    sudo apt install xclip          # strongly recommended — used for reliable text typing
"""

import asyncio
import base64
import io
import json
import logging
import os
import re
import shutil
import struct
import subprocess
import sys

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

# ── Display Server Detection ──────────────────────────────────────────

USE_WAYLAND = bool(os.environ.get("WAYLAND_DISPLAY"))


def detect_display_server():
    """Log which display server is active."""
    if USE_WAYLAND:
        log.info("Display server: Wayland (will use ydotool)")
    else:
        log.info("Display server: X11 (will use xdotool)")


def detect_screen_resolution() -> tuple[int, int]:
    """Detect the primary screen resolution.
    Returns (width, height). Defaults to (1920, 1080).
    """
    # Try xrandr first
    if shutil.which("xrandr"):
        try:
            result = subprocess.run(
                ["xrandr"], capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.splitlines():
                m = re.search(r"(\d+)x(\d+)\+\d+\+\d+", line)
                if m:
                    w, h = int(m.group(1)), int(m.group(2))
                    log.info("Screen resolution (xrandr): %dx%d", w, h)
                    return (w, h)
        except Exception as exc:
            log.debug("xrandr failed: %s", exc)

    # Try xdpyinfo
    if shutil.which("xdpyinfo"):
        try:
            result = subprocess.run(
                ["xdpyinfo"], capture_output=True, text=True, timeout=5
            )
            m = re.search(r"dimensions:\s+(\d+)x(\d+)\s+pixels", result.stdout)
            if m:
                w, h = int(m.group(1)), int(m.group(2))
                log.info("Screen resolution (xdpyinfo): %dx%d", w, h)
                return (w, h)
        except Exception as exc:
            log.debug("xdpyinfo failed: %s", exc)

    log.warning("Could not detect screen resolution — using default 1920x1080")
    return (1920, 1080)


# ── Screenshot Capture ────────────────────────────────────────────────

def capture_screenshot() -> tuple[str, int, int]:
    """Capture the entire screen and return (base64_png, width, height).
    
    Uses mss for fast screen capture. Falls back to scrot if mss is unavailable.
    """
    try:
        import mss
        with mss.mss() as sct:
            # Capture the primary monitor
            monitor = sct.monitors[1]  # monitors[0] is all monitors combined
            screenshot = sct.grab(monitor)
            
            # Convert to PNG bytes
            from PIL import Image
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
            
    except ImportError:
        log.warning("mss not available, trying scrot fallback")
    
    # Fallback: use scrot
    try:
        result = subprocess.run(
            ["scrot", "-o", "/tmp/mousecontrol_screenshot.png"],
            capture_output=True, timeout=5,
        )
        with open("/tmp/mousecontrol_screenshot.png", "rb") as f:
            png_bytes = f.read()
        
        from PIL import Image
        img = Image.open(io.BytesIO(png_bytes))
        w, h = img.size
        
        b64 = base64.b64encode(png_bytes).decode("ascii")
        log.info("Screenshot captured (scrot): %dx%d (%d KB)", w, h, len(png_bytes) // 1024)
        return (b64, w, h)
        
    except Exception as exc:
        log.error("All screenshot methods failed: %s", exc)
        raise


# ── Modifier Key Safety ───────────────────────────────────────────────

def reset_modifier_keys():
    """Force-release all modifier keys to prevent stuck-modifier issues.

    xdotool's --clearmodifiers can leave modifiers stuck if the process is
    interrupted mid-operation or if two xdotool commands race.  This
    function explicitly releases every modifier, which is safe to call
    even if the keys aren't currently pressed.
    """
    if USE_WAYLAND:
        return  # ydotool handles modifiers differently
    for mod in (
        "Shift_L", "Shift_R",
        "Control_L", "Control_R",
        "Alt_L", "Alt_R",
        "Super_L", "Super_R",
        "Meta_L", "Meta_R",
        "Caps_Lock", "Num_Lock",
    ):
        subprocess.run(
            ["xdotool", "keyup", mod],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )


def _clipboard_type(text: str):
    """Type text by copying it to the clipboard and pasting with Ctrl+V.

    Much more reliable than `xdotool type` for anything longer than a
    few characters, and avoids the --clearmodifiers stuck-key problem.
    Falls back to xdotool type on failure.
    """
    if not shutil.which("xclip"):
        # Fallback: xdotool type (without --clearmodifiers)
        subprocess.run(
            ["xdotool", "type", "--delay", "12", "--", text],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30,
        )
        return

    try:
        # Save current clipboard so we can restore it afterward.
        old_clip = subprocess.run(
            ["xclip", "-selection", "clipboard", "-o"],
            capture_output=True, timeout=2,
        ).stdout
    except Exception:
        old_clip = None

    try:
        # Copy desired text to clipboard.
        proc = subprocess.Popen(
            ["xclip", "-selection", "clipboard"],
            stdin=subprocess.PIPE,
        )
        proc.communicate(input=text.encode("utf-8"), timeout=5)

        # Small delay so the clipboard is ready.
        import time
        time.sleep(0.05)

        # Paste with Ctrl+V.
        subprocess.run(
            ["xdotool", "key", "ctrl+v"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        )
    finally:
        # Restore previous clipboard content (best-effort).
        if old_clip is not None:
            try:
                proc = subprocess.Popen(
                    ["xclip", "-selection", "clipboard"],
                    stdin=subprocess.PIPE,
                )
                proc.communicate(input=old_clip, timeout=5)
            except Exception:
                pass


# ── Action Injection ──────────────────────────────────────────────────

def inject_action(event: dict, screen_w: int, screen_h: int) -> dict:
    """Execute an AI-directed action on this machine.
    
    Returns a result dict: {"success": True/False, "error": "..." if failed}
    """
    action = event.get("action")
    
    try:
        if action == "mouseMove":
            nx = event.get("normalizedX", 0.5)
            ny = event.get("normalizedY", 0.5)
            x = int(nx * screen_w)
            y = int(ny * screen_h)
            x = max(0, min(x, screen_w - 1))
            y = max(0, min(y, screen_h - 1))
            
            if USE_WAYLAND:
                subprocess.run(
                    ["ydotool", "mousemove", "--absolute", "-x", str(x), "-y", str(y)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                )
            else:
                subprocess.run(
                    ["xdotool", "mousemove", str(x), str(y)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                )
            log.info("mouseMove → (%d, %d)", x, y)
            return {"success": True}
            
        elif action == "click":
            nx = event.get("normalizedX", 0.5)
            ny = event.get("normalizedY", 0.5)
            x = int(nx * screen_w)
            y = int(ny * screen_h)
            x = max(0, min(x, screen_w - 1))
            y = max(0, min(y, screen_h - 1))
            
            button = event.get("button", "left")
            count = event.get("clickCount", 1)
            
            button_num = {"left": "1", "middle": "2", "right": "3"}.get(button, "1")
            
            if USE_WAYLAND:
                subprocess.run(
                    ["ydotool", "mousemove", "--absolute", "-x", str(x), "-y", str(y)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                )
                for _ in range(count):
                    subprocess.run(
                        ["ydotool", "click", button_num],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                    )
            else:
                repeat_flag = ["--repeat", str(count)] if count > 1 else []
                subprocess.run(
                    ["xdotool", "mousemove", str(x), str(y)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                )
                subprocess.run(
                    ["xdotool", "click"] + repeat_flag + [button_num],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                )
            log.info("click (%s, ×%d) → (%d, %d)", button, count, x, y)
            return {"success": True}
            
        elif action == "type":
            text = event.get("text", "")
            if not text:
                return {"success": True}
            
            if USE_WAYLAND:
                subprocess.run(
                    ["ydotool", "type", "--", text],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30,
                )
            else:
                # Use clipboard paste — much more reliable than xdotool type
                # and avoids the --clearmodifiers stuck-key problem entirely.
                _clipboard_type(text)
            log.info("type → '%s'", text[:50] + ("…" if len(text) > 50 else ""))
            return {"success": True}
            
        elif action == "keyCombo":
            keys = event.get("keys", [])
            if not keys:
                return {"success": True}
            
            # Map common key names to xdotool names
            key_map = {
                "ctrl": "ctrl",
                "alt": "alt",
                "shift": "shift",
                "super": "super",
                "enter": "Return",
                "return": "Return",
                "tab": "Tab",
                "escape": "Escape",
                "esc": "Escape",
                "backspace": "BackSpace",
                "delete": "Delete",
                "space": "space",
                "up": "Up",
                "down": "Down",
                "left": "Left",
                "right": "Right",
                "home": "Home",
                "end": "End",
                "pageup": "Prior",
                "pagedown": "Next",
                "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4",
                "f5": "F5", "f6": "F6", "f7": "F7", "f8": "F8",
                "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
            }
            
            mapped_keys = [key_map.get(k.lower(), k) for k in keys]
            combo = "+".join(mapped_keys)
            
            if USE_WAYLAND:
                subprocess.run(
                    ["ydotool", "key", combo],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                )
            else:
                subprocess.run(
                    ["xdotool", "key", combo],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                )
            log.info("keyCombo → %s", combo)
            return {"success": True}
            
        elif action == "scroll":
            dx = event.get("scrollDeltaX", 0)
            dy = event.get("scrollDeltaY", 0)
            
            # xdotool: button 4 = scroll up, button 5 = scroll down
            # button 6 = scroll left, button 7 = scroll right
            if dy:
                button = "4" if dy > 0 else "5"
                clicks = abs(int(dy))
                for _ in range(clicks):
                    if USE_WAYLAND:
                        subprocess.run(
                            ["ydotool", "click", button],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                        )
                    else:
                        subprocess.run(
                            ["xdotool", "click", button],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                        )
            if dx:
                button = "7" if dx > 0 else "6"
                clicks = abs(int(dx))
                for _ in range(clicks):
                    if USE_WAYLAND:
                        subprocess.run(
                            ["ydotool", "click", button],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                        )
                    else:
                        subprocess.run(
                            ["xdotool", "click", button],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                        )
            log.info("scroll → (dx=%s, dy=%s)", dx, dy)
            return {"success": True}
            
        elif action == "wait":
            # Wait is handled on the Mac side; companion just acks.
            return {"success": True}
            
        elif action == "done":
            log.info("Task complete: %s", event.get("summary", ""))
            return {"success": True}
            
        elif action is None:
            return {"success": True}
            
        else:
            log.warning("Unknown action: %s", action)
            return {"success": False, "error": f"Unknown action: {action}"}
            
    except subprocess.TimeoutExpired:
        log.error("Action timed out: %s", action)
        reset_modifier_keys()  # Clean up after timeout
        return {"success": False, "error": f"Action timed out: {action}"}
    except Exception as exc:
        log.error("Action failed: %s — %s", action, exc)
        reset_modifier_keys()  # Clean up after failure
        return {"success": False, "error": str(exc)}
    finally:
        # Defensive: always ensure no modifiers are stuck after any action.
        try:
            reset_modifier_keys()
        except Exception:
            pass


# ── TCP Client ────────────────────────────────────────────────────────

async def _read_exact(reader: asyncio.StreamReader, n: int) -> bytes:
    """Read exactly n bytes from the stream, raising on EOF."""
    data = b""
    while len(data) < n:
        chunk = await reader.read(n - len(data))
        if not chunk:
            raise ConnectionError("Connection closed by remote")
        data += chunk
    return data


async def tcp_client(screen_w: int, screen_h: int):
    """Connect to the Mac and process commands in a loop.
    Reconnects automatically on failure.
    """
    while True:
        writer = None
        try:
            log.info("Connecting to Mac at %s:%d …", MAC_IP, PORT)
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(MAC_IP, PORT),
                timeout=5.0,
            )
            log.info("Connected to Mac")

            while True:
                # Read 4-byte length header with timeout
                header = await asyncio.wait_for(
                    _read_exact(reader, 4),
                    timeout=120.0,
                )
                length = struct.unpack("!I", header)[0]

                if length == 0 or length > 10_000_000:
                    log.warning("Invalid message length: %d — dropping connection", length)
                    break

                # Read the JSON payload with timeout
                payload = await asyncio.wait_for(
                    _read_exact(reader, length),
                    timeout=10.0,
                )
                message = json.loads(payload.decode("utf-8"))

                # Process the message
                response = handle_message(message, screen_w, screen_h)
                
                # Send the response if there is one
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
            if writer is not None:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass

        log.info("Reconnecting in %.0f seconds …", RECONNECT_DELAY)
        await asyncio.sleep(RECONNECT_DELAY)


def handle_message(message: dict, screen_w: int, screen_h: int) -> dict | None:
    """Process a message from the Mac and return a response (or None)."""
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
            log.error("Failed to capture screenshot: %s", exc)
            return {
                "type": "actionResult",
                "success": False,
                "error": f"Screenshot capture failed: {exc}",
            }
    
    elif msg_type == "executeAction":
        result = inject_action(message, screen_w, screen_h)
        return {
            "type": "actionResult",
            **result,
        }
    
    elif msg_type == "heartbeat":
        log.debug("Heartbeat received from Mac")
        return None  # No response for heartbeats
    
    else:
        log.warning("Unknown message type: %s", msg_type)
        return None


# ── Startup Checks ────────────────────────────────────────────────────

def check_dependencies():
    """Check that required tools are installed."""
    missing = []
    
    # Check for xdotool or ydotool
    if USE_WAYLAND:
        if not shutil.which("ydotool"):
            missing.append("ydotool (sudo apt install ydotool)")
    else:
        if not shutil.which("xdotool"):
            missing.append("xdotool (sudo apt install xdotool)")
        if not shutil.which("xclip"):
            log.warning(
                "xclip not found — text typing will fall back to xdotool type "
                "which can cause stuck modifiers. Install with: sudo apt install xclip"
            )
    
    # Check for screenshot dependencies
    try:
        import mss
    except ImportError:
        try:
            import PIL
        except ImportError:
            missing.append("mss and Pillow (pip3 install mss Pillow)")
    
    if missing:
        print("❌ Missing dependencies:")
        for dep in missing:
            print(f"   • {dep}")
        sys.exit(1)


# ── Main ──────────────────────────────────────────────────────────────

def main():
    log.info("MouseControl Linux Companion starting …")

    # 1. Check dependencies
    check_dependencies()

    # 2. Detect display server
    detect_display_server()

    # 3. Detect screen resolution
    screen_w, screen_h = detect_screen_resolution()

    # 4. Log connection target
    log.info("Will connect to Mac at %s:%d", MAC_IP, PORT)

    # 5. Run the async event loop
    try:
        asyncio.run(tcp_client(screen_w, screen_h))
    except KeyboardInterrupt:
        log.info("Shutting down …")
    
    log.info("Goodbye.")


if __name__ == "__main__":
    main()
