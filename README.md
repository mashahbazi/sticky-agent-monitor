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
- **Readable titles** — if a session hasn't been given a friendly name yet, the
  monitor recovers its original task description from the session transcript
  instead of showing a bare hash like `125f85a7`.
- **`claude agents` control view flagged separately** — launching `claude
  agents` leaves an idle standby worker registered in
  `~/.claude/sessions/*.json`, indistinguishable at a glance from a real
  working agent. The monitor detects it and tags it with a distinct purple
  **CONTROL** badge instead of counting it as an active agent.
- **Smart sorting** — sessions needing your attention float to the top;
  control-view entries sink near the bottom.
- **Click to attach** (macOS) — click any session row to open a new Terminal.app
  window pre-filtered to that session's background agent (`claude agents --cwd
  <dir>`); press Enter once to attach.
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

By default this starts the overlay **detached from the terminal** — it forks
a background process (new session, no inherited stdin/stdout) and immediately
returns control of your shell. The overlay keeps running even after you close
the terminal window; closing it again just closes that terminal, not the app.

The window appears in the top-right corner and stays on top of other windows.
It resizes automatically to fit the number of active sessions (up to 10 visible,
with a `+N more…` overflow indicator).

### Managing the background process

```bash
python sticky-agent-monitor.py --status   # is it running?
python sticky-agent-monitor.py --stop     # stop it
```

To run it attached to the current terminal instead (e.g. for debugging, so
`print`/errors show up directly and Ctrl-C stops it):

```bash
python sticky-agent-monitor.py --foreground
```

A pidfile is kept at `~/.sticky-agent-monitor/monitor.pid` and logs at
`~/.sticky-agent-monitor/monitor.log`.

With `mise`:

```bash
mise run start       # start in background
mise run status      # check status
mise run stop        # stop it
mise run foreground  # run attached, for debugging
```

To actually quit the app, use `--stop` (or click the window's close button /
Cmd-Q it, same as any Mac app).

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
`cwd`, `sessionId`, and `updatedAt`. The monitor maps each `status` to a
colored badge and sort priority, then updates the existing row widgets in
place on every poll to avoid flicker. State transitions (e.g.
`busy → waiting`) trigger native OS notifications.

**Title recovery.** Claude only auto-renames a session away from its
generated id once it's made enough progress to summarize the task; until
then (or if it never does), `name` just equals the id. When that happens,
the monitor reads `~/.claude/projects/<cwd-with-slashes-as-dashes>/<sessionId
>.jsonl` and pulls the first genuine user message as the title, skipping
synthetic wrapper content (local-command caveats, bare slash-command
invocations with no arguments) and unwrapping `<command-args>` when the task
was given via a slash command. Results are cached per session for the life
of the process, since a session's original task never changes.

**Control-view detection.** `claude agents` keeps an idle spare worker on
standby in whichever directory it's launched from, ready to dispatch a new
task the instant you type one — and that standby worker gets its own entry
in `~/.claude/sessions/*.json`, styled identically to a real agent. The
monitor tells the two apart with a heuristic: a session is treated as a
control-view standby only while it has an `agent` field set, is still
`idle`, and was never renamed away from its id. The moment you actually
dispatch a task from within `claude agents`, that session picks up real
work and naturally falls out of this bucket on the next poll.

Clicking a row runs an AppleScript that opens Terminal.app and runs
`claude agents --cwd <cwd>`, which lists only the background agent(s) running
under that directory (usually just the one you clicked). Press Enter (or →)
on the highlighted session to attach to its live conversation. `claude
--resume` isn't used here because it refuses to attach to a session that's
still running as a background agent. This is macOS-only (uses `osascript` /
Terminal.app).
