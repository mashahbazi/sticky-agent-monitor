# sticky-agent-monitor

A tiny, always-on-top desktop overlay that shows all of your active
[Claude Code](https://claude.com/claude-code) sessions and their live state.

It polls `~/.claude/sessions/*.json` every few seconds and renders a compact,
flicker-free list in the top-right corner of your screen — so you can see at a
glance which sessions are **busy**, **waiting for input**, **done**, or in an
**error** state, and get a native OS notification when a session changes state.

## Features

- **Live session list** — reads `~/.claude/sessions/*.json` and updates in place.
- **Color-coded status badges** — waiting, blocked, error, busy, idle, done, stopped.
- **Smart sorting** — sessions needing your attention float to the top.
- **Native notifications** — alerts when a session starts waiting, finishes, or errors
  (macOS via `osascript`, Linux via `notify-send`).
- **Zero dependencies** — pure Python standard library (uses `tkinter`).
- **Lightweight** — pre-allocated row widgets, in-place updates, no flicker.

## Requirements

- **Python 3.10+**
- **tkinter** — bundled with the official python.org / mise Python builds on
  macOS and Windows. On some Linux distributions install it separately:
  - Debian/Ubuntu: `sudo apt install python3-tk`
  - Fedora: `sudo dnf install python3-tkinter`

There are no third-party packages to install — see `requirements.txt`.

## Setup with mise

This repo ships a [`mise`](https://mise.jdx.dev/) config that pins Python and
manages a project-local virtualenv.

```bash
# Install the pinned Python and create the .venv
mise install

# (optional) install dependencies — currently none
mise run install

# Run the overlay
mise run start
```

## Setup with plain pip

```bash
# Create and activate a virtualenv
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate

# Install dependencies (currently none)
pip install -r requirements.txt

# Run the overlay
python sticky-agent-monitor.py
```

## Usage

```bash
python sticky-agent-monitor.py
```

The window appears in the top-right corner and stays on top of other windows.
It resizes automatically to fit the number of active sessions (up to 10 visible,
with a `+N more…` overflow indicator).

## Configuration

Tweak the constants near the top of `sticky-agent-monitor.py`:

| Constant           | Default | Description                                  |
| ------------------ | ------- | -------------------------------------------- |
| `SESSIONS_DIR`     | `~/.claude/sessions` | Where session JSON files are read from |
| `POLL_INTERVAL_MS` | `3000`  | How often to poll for changes (milliseconds) |
| `WINDOW_WIDTH`     | `360`   | Overlay width in pixels                      |
| `MAX_VISIBLE`      | `10`    | Max session rows shown before overflow       |

## How it works

Each session JSON file is expected to contain fields such as `status`, `name`,
`cwd`, and `updatedAt`. The monitor maps each `status` to a colored badge and
sort priority, then updates the existing row widgets in place on every poll to
avoid flicker. State transitions (e.g. `busy → waiting`) trigger native OS
notifications.
