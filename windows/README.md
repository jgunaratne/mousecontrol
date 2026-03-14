# MouseControl — Windows Companion

AI-powered remote PC control. The macOS MouseControl app sends prompts to Gemini 3.1 Pro, which analyzes your Windows screen and remotely operates your mouse and keyboard.

## Prerequisites

- **Python 3.10+** — [python.org/downloads](https://www.python.org/downloads/)
- **USB-C cable** connected to the Mac running MouseControl

## Installation

### 1. Clone or copy the `windows/` folder to your Windows PC

```powershell
# If you have the repo:
git clone <your-repo-url>
cd mousecontrol\windows
```

### 2. Install dependencies

```powershell
pip install -r requirements.txt
```

This installs:
- **mss** — fast screenshot capture
- **Pillow** — image processing
- **pystray** — system tray icon

### 3. Run

```powershell
# With console (for debugging):
python mousecontrol.py

# Without console (background, recommended):
pythonw mousecontrol.py
```

The app will:
1. Appear as a colored circle in your system tray
2. Automatically connect to the Mac at `192.168.100.1:9877`
3. Show **green** when connected, **red** when disconnected

### 4. (Optional) Auto-start on boot

Not yet built in — you can add a shortcut manually:

1. Press `Win+R`, type `shell:startup`, press Enter
2. Create a shortcut to `pythonw C:\path\to\mousecontrol.py`

## How It Works

Once connected, the Mac can:
1. **Request screenshots** — the companion captures and sends your screen
2. **Send AI actions** — mouse clicks, typing, key combos, scrolling

All actions are performed via the Win32 `SendInput` API, so they appear as real hardware input.

## Troubleshooting

| Issue | Fix |
|---|---|
| Tray icon not showing | Install pystray: `pip install pystray Pillow` |
| "Connection refused" | Ensure Mac's MouseControl is running and USB-C is connected |
| Screenshot fails | Ensure mss is installed: `pip install mss` |
| Actions not working | Run as Administrator (some apps require elevated input) |

## Network

- Mac IP: `192.168.100.1`
- Port: `9877`
- Protocol: TCP with 4-byte length-prefixed JSON messages
