
#!/usr/bin/env python3
"""
Claude Code Session Monitor
A tiny always-on-top overlay that shows all active Claude Code sessions and their state.
Polls ~/.claude/sessions/*.json every 3 seconds. Updates labels in-place (no flicker).

Usage:
    python3 sticky-agent-monitor.py            # start detached in the background
    python3 sticky-agent-monitor.py --foreground  # run attached to this terminal
    python3 sticky-agent-monitor.py --stop     # stop the running background instance
    python3 sticky-agent-monitor.py --status   # check whether it's running

Requires: Python 3.10+ (tkinter is included with Python on macOS/Windows)
"""

import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import tkinter as tk
from pathlib import Path

# ── Config ───────────────────────────────────────────────────────────────────
SESSIONS_DIR = Path.home() / ".claude" / "sessions"
POLL_INTERVAL_MS = 3000
WINDOW_WIDTH = 360
ROW_HEIGHT = 54
HEADER_HEIGHT = 32
MAX_VISIBLE = 10

RUN_DIR = Path.home() / ".sticky-agent-monitor"
PID_FILE = RUN_DIR / "monitor.pid"
LOG_FILE = RUN_DIR / "monitor.log"
_DAEMON_ENV_FLAG = "_STICKY_AGENT_MONITOR_DAEMONIZED"

# Status → (bg, fg, label, sort priority)
#
# In practice a background agent only ever reports "busy" or "idle" -- there's
# no distinct "completed"/"done" status to tell "finished this task" apart
# from "finished and just sitting there". So we treat "idle" as done: once a
# bg agent stops being busy/waiting/erroring, it's done, full stop. Every
# state below is also picked to have a clearly different hue from every other
# state (and from CONTROL_STYLE below) so you can tell them apart by color
# alone, not just by reading the label.
STATUS_STYLES = {
    "waiting":       ("#FEF3C7", "#92400E", "WAITING",     0),  # amber
    "needs_input":   ("#FEF3C7", "#92400E", "NEEDS INPUT", 0),  # amber
    "blocked":       ("#FECACA", "#7F1D1D", "BLOCKED",     1),  # red
    "error":         ("#FECACA", "#7F1D1D", "ERROR",       2),  # red
    "busy":          ("#BFDBFE", "#1E3A8A", "BUSY",        3),  # blue
    "running":       ("#BFDBFE", "#1E3A8A", "RUNNING",     3),  # blue
    "working":       ("#BFDBFE", "#1E3A8A", "WORKING",     3),  # blue
    "idle":          ("#A7F3D0", "#065F46", "DONE",        5),  # green
    "completed":     ("#A7F3D0", "#065F46", "DONE",        5),  # green
    "done":          ("#A7F3D0", "#065F46", "DONE",        5),  # green
    "stopped":       ("#E5E7EB", "#374151", "STOPPED",     6),  # gray
}
DEFAULT_STYLE = ("#F3F4F6", "#374151", "UNKNOWN", 99)

# `claude agents` (the background-agent control TUI) keeps an idle spare
# worker on standby in whichever directory it's launched from, ready to
# dispatch a new task the moment you type one. That standby worker shows up
# in ~/.claude/sessions/*.json exactly like any other session, but it never
# received a real task -- it's still idle and still named after its own
# auto-generated id. We tag those distinctly so they don't get confused with
# actual working agents. Pink is used deliberately: it's the one hue nothing
# else in STATUS_STYLES uses, so it can't be mistaken for busy/done/etc.
# (bg, fg, label, sort priority)
CONTROL_STYLE = ("#FBCFE8", "#9D174D", "CONTROL", 50)

# Statuses that trigger notifications when transitioned INTO. "idle" counts
# as done (see STATUS_STYLES above) -- that's the only completion signal most
# background agents ever actually report.
NOTIFY_WAITING = {"waiting", "needs_input"}
NOTIFY_DONE = {"completed", "done", "idle"}
NOTIFY_ERROR = {"error", "blocked"}


def notify(title: str, message: str):
    """Native OS notification."""
    try:
        if sys.platform == "darwin":
            subprocess.Popen([
                "osascript", "-e",
                f'display notification "{message}" with title "{title}" sound name "Glass"'
            ])
        elif sys.platform == "linux":
            subprocess.Popen(["notify-send", title, message])
    except Exception:
        pass


def _applescript_escape(s: str) -> str:
    """Escape a string for safe embedding inside an AppleScript "..." literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def attach_session(session: dict):
    """Open a new Terminal.app window/tab pre-filtered to this session's
    background agent view, ready to attach with a single Enter keypress.

    `claude --resume` refuses to attach to a session that's still running as
    a background agent (it says to use `claude agents` instead), so we open
    `claude agents --cwd <dir>` scoped to this session's directory. macOS only.
    """
    if sys.platform != "darwin":
        return

    cwd = session.get("cwd") or str(Path.home())
    shell_cmd = f"cd {shlex.quote(cwd)} && claude agents --cwd {shlex.quote(cwd)}"
    script = (
        'tell application "Terminal"\n'
        "activate\n"
        f'do script "{_applescript_escape(shell_cmd)}"\n'
        "end tell"
    )
    try:
        subprocess.Popen(["osascript", "-e", script])
    except Exception:
        pass


def is_control_session(session: dict) -> bool:
    """True if this is `claude agents`' own idle standby worker, not a real
    working agent. See the CONTROL_STYLE comment for why this check works."""
    job_id = session.get("jobId")
    return (
        bool(session.get("agent"))
        and session.get("status", "").lower() == "idle"
        and job_id is not None
        and session.get("name") == job_id
    )


def _extract_text(content) -> str | None:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                return block.get("text")
    return None


_COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)


def _candidate_title(text: str) -> str | None:
    """Pull a usable one-line title out of a raw transcript message, or None
    if this message is just wrapper/caveat noise rather than real content."""
    text = text.strip()
    if not text:
        return None

    # Slash-command invocations wrap the real task in <command-args>...</command-args>.
    args_match = _COMMAND_ARGS_RE.search(text)
    if args_match:
        args = args_match.group(1).strip()
        return args or None  # empty args (e.g. bare "/clear") isn't a useful title

    # Other synthetic wrapper content (caveats, tool/system tags) starts with "<".
    if text.startswith("<"):
        return None

    return text


_first_message_cache: dict[str, str] = {}


def _first_user_message(cwd: str, session_id: str) -> str | None:
    """Read the session's transcript to recover its original task, for
    sessions Claude hasn't gotten around to auto-naming yet."""
    if session_id in _first_message_cache:
        return _first_message_cache[session_id] or None

    project_dir = cwd.replace("/", "-")
    path = Path.home() / ".claude" / "projects" / project_dir / f"{session_id}.jsonl"
    text = ""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 200:
                    break
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("type") != "user":
                    continue
                found = _extract_text(entry.get("message", {}).get("content"))
                if not found:
                    continue
                title = _candidate_title(found)
                if title:
                    text = title.splitlines()[0].strip()
                    break
    except OSError:
        pass

    _first_message_cache[session_id] = text
    return text or None


def display_name(session: dict) -> str:
    """A human-friendly title for the row, falling back to the session's
    original task description when it's still just an auto-generated id."""
    name = (session.get("name") or "").strip()
    job_id = session.get("jobId") or ""
    is_placeholder = not name or (job_id and name == job_id)

    if is_placeholder:
        cwd = session.get("cwd")
        session_id = session.get("sessionId")
        if cwd and session_id:
            first_msg = _first_user_message(cwd, session_id)
            if first_msg:
                name = first_msg

    return name or session.get("_id", "")[:10]


def _proc_alive(pid: int) -> bool:
    """Check that `pid` is still a running process, not a dead PID left behind
    by a session that crashed or was killed without cleaning up its file."""
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        pass  # exists but we can't signal it (e.g. different user) -- assume alive
    return True


def read_sessions() -> list[dict]:
    """Read ~/.claude/sessions/*.json for still-running sessions and return sorted list."""
    sessions = []
    if not SESSIONS_DIR.exists():
        return sessions

    for f in SESSIONS_DIR.iterdir():
        if not f.is_file() or f.suffix != ".json":
            continue
        try:
            data = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        if not _proc_alive(data.get("pid")):
            continue  # stale file left behind by a session that's no longer running

        data["_id"] = f.stem
        data["_mtime"] = f.stat().st_mtime
        sessions.append(data)

    def sort_key(s):
        if is_control_session(s):
            priority = CONTROL_STYLE[3]
        else:
            status = s.get("status", "unknown").lower()
            priority = STATUS_STYLES.get(status, DEFAULT_STYLE)[3]
        return (priority, -s.get("_mtime", 0))

    sessions.sort(key=sort_key)
    return sessions


def format_ago(session: dict) -> str:
    updated_at = session.get("updatedAt", 0)
    mtime = updated_at / 1000 if updated_at else session.get("_mtime", 0)
    if not mtime:
        return ""
    delta = time.time() - mtime
    if delta < 60:
        return f"{int(delta)}s"
    elif delta < 3600:
        return f"{int(delta / 60)}m"
    else:
        return f"{int(delta / 3600)}h"


ROW_BG = "#1F2937"
ROW_BG_HOVER = "#2D3748"


class SessionRow:
    """A single session row that updates its labels in-place."""

    def __init__(self, parent: tk.Frame, on_click=None):
        self.on_click = on_click
        self.session: dict | None = None

        cursor = "pointinghand" if sys.platform == "darwin" else "hand2"

        self.frame = tk.Frame(parent, bg=ROW_BG, highlightthickness=0, cursor=cursor)

        self.badge = tk.Label(
            self.frame, text="", font=("SF Mono", 9, "bold"), padx=4, pady=1, cursor=cursor
        )
        self.badge.pack(side="left", padx=(6, 8), pady=8)
        self.badge.bind("<Button-1>", self._handle_click)

        self.info = tk.Frame(self.frame, bg=ROW_BG, cursor=cursor)
        self.info.pack(side="left", fill="x", expand=True, pady=4)

        self.name_label = tk.Label(
            self.info, text="", font=("SF Pro Text", 11, "bold"),
            fg="#E5E7EB", bg=ROW_BG, anchor="w", cursor=cursor
        )
        self.name_label.pack(anchor="w")

        self.cwd_label = tk.Label(
            self.info, text="", font=("SF Pro Text", 9),
            fg="#6B7280", bg=ROW_BG, anchor="w", cursor=cursor
        )
        self.cwd_label.pack(anchor="w")

        self.time_label = tk.Label(
            self.frame, text="", font=("SF Mono", 9),
            fg="#6B7280", bg=ROW_BG, padx=8, cursor=cursor
        )
        self.time_label.pack(side="right", pady=8)

        self._clickable_widgets = (
            self.frame, self.info, self.name_label, self.cwd_label, self.time_label
        )
        for widget in self._clickable_widgets:
            widget.bind("<Button-1>", self._handle_click)
            widget.bind("<Enter>", self._on_enter)
            widget.bind("<Leave>", self._on_leave)

        self._current_status = None

    def _handle_click(self, _event):
        if self.session and self.on_click:
            self.on_click(self.session)

    def _on_enter(self, _event):
        self._set_row_bg(ROW_BG_HOVER)

    def _on_leave(self, _event):
        self._set_row_bg(ROW_BG)

    def _set_row_bg(self, color: str):
        self.frame.config(bg=color)
        self.info.config(bg=color)
        self.name_label.config(bg=color)
        self.cwd_label.config(bg=color)
        self.time_label.config(bg=color)

    def update(self, session: dict):
        self.session = session
        control = is_control_session(session)

        if control:
            bg, fg, label = CONTROL_STYLE[0], CONTROL_STYLE[1], CONTROL_STYLE[2]
            status_key = "__control__"
        else:
            status_key = session.get("status", "unknown").lower()
            bg, fg, label, _ = STATUS_STYLES.get(status_key, DEFAULT_STYLE)

        # Only reconfigure badge colors if status changed
        if status_key != self._current_status:
            self.badge.config(text=f" {label} ", fg=fg, bg=bg)
            self._current_status = status_key

        name = "claude agents (idle)" if control else display_name(session)
        if len(name) > 28:
            name = name[:26] + "..."
        self.name_label.config(text=name)

        cwd = session.get("cwd", "")
        if cwd:
            cwd = Path(cwd).name
        self.cwd_label.config(text=cwd)

        self.time_label.config(text=format_ago(session))

    def show(self):
        self.frame.pack(fill="x", padx=4, pady=2)

    def hide(self):
        self.frame.pack_forget()

    def destroy(self):
        self.frame.destroy()


class SessionMonitor:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Claude Sessions")
        self.root.attributes("-topmost", True)
        self.root.resizable(False, True)
        self.root.configure(bg="#1F2937")

        self.prev_states: dict[str, str] = {}

        # Position top-right
        self.root.update_idletasks()
        screen_w = self.root.winfo_screenwidth()
        x = screen_w - WINDOW_WIDTH - 20
        self.root.geometry(f"{WINDOW_WIDTH}x{HEADER_HEIGHT + 60}+{x}+40")

        # Header
        header = tk.Frame(self.root, bg="#1F2937", height=HEADER_HEIGHT)
        header.pack(fill="x")
        header.pack_propagate(False)

        tk.Label(
            header, text=" Claude Sessions", font=("SF Pro Display", 13, "bold"),
            fg="#F9FAFB", bg="#1F2937", anchor="w", padx=10
        ).pack(side="left", fill="y")

        self.count_label = tk.Label(
            header, text="", font=("SF Mono", 11), fg="#9CA3AF", bg="#1F2937", padx=10
        )
        self.count_label.pack(side="right", fill="y")

        # Session list
        self.list_frame = tk.Frame(self.root, bg="#111827")
        self.list_frame.pack(fill="both", expand=True, padx=4, pady=(0, 4))

        self.empty_label = tk.Label(
            self.list_frame,
            text="No active sessions\n\nclaude --bg \"your task\"",
            font=("SF Pro Text", 11), fg="#6B7280", bg="#111827", justify="center"
        )

        # Pre-allocate row widgets (reuse them, never destroy/recreate)
        self.rows: list[SessionRow] = []
        for _ in range(MAX_VISIBLE):
            self.rows.append(SessionRow(self.list_frame, on_click=attach_session))

        self.overflow_label = tk.Label(
            self.list_frame, text="", font=("SF Pro Text", 10),
            fg="#6B7280", bg="#111827"
        )

        self._last_session_count = -1
        self.poll()

    def poll(self):
        sessions = read_sessions()
        self.update_ui(sessions)
        self.check_notifications(sessions)
        self.root.after(POLL_INTERVAL_MS, self.poll)

    def check_notifications(self, sessions: list[dict]):
        current: dict[str, str] = {}
        for s in sessions:
            sid = s["_id"]
            status = s.get("status", "unknown").lower()
            current[sid] = status

            prev = self.prev_states.get(sid)
            if prev is None or is_control_session(s):
                continue

            name = display_name(s)

            if status in NOTIFY_WAITING and prev not in NOTIFY_WAITING:
                notify("Needs Input", f"{name} is waiting for you")
            elif status in NOTIFY_DONE and prev not in NOTIFY_DONE:
                notify("Completed", f"{name} finished")
            elif status in NOTIFY_ERROR and prev not in NOTIFY_ERROR:
                notify("Attention", f"{name} hit an error")

        self.prev_states = current

    def update_ui(self, sessions: list[dict]):
        n = len(sessions)
        visible_count = min(n, MAX_VISIBLE)

        active = sum(
            1 for s in sessions
            if not is_control_session(s)
            and s.get("status", "").lower() not in ("stopped", "completed", "done")
        )
        self.count_label.config(text=f"{active} active / {n} total")

        if n == 0:
            for row in self.rows:
                row.hide()
            self.overflow_label.pack_forget()
            self.empty_label.pack(expand=True, fill="both", pady=20)
            self._resize(HEADER_HEIGHT + 80)
            return

        self.empty_label.pack_forget()

        # Update visible rows in-place
        for i in range(MAX_VISIBLE):
            if i < visible_count:
                self.rows[i].update(sessions[i])
                self.rows[i].show()
            else:
                self.rows[i].hide()

        # Overflow indicator
        if n > MAX_VISIBLE:
            self.overflow_label.config(text=f"+{n - MAX_VISIBLE} more...")
            self.overflow_label.pack(pady=(2, 4))
            self._resize(HEADER_HEIGHT + visible_count * ROW_HEIGHT + 32)
        else:
            self.overflow_label.pack_forget()
            self._resize(HEADER_HEIGHT + visible_count * ROW_HEIGHT + 8)

    def _resize(self, height: int):
        """Only call geometry if size actually changed."""
        if height != self._last_session_count:
            self.root.geometry(f"{WINDOW_WIDTH}x{height}")
            self._last_session_count = height

    def run(self):
        self.root.mainloop()


def _read_pid() -> int | None:
    try:
        return int(PID_FILE.read_text().strip())
    except (OSError, ValueError):
        return None


def _pid_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True  # exists but owned by someone else -- treat as alive
    return True


def cmd_status():
    pid = _read_pid()
    if pid and _pid_running(pid):
        print(f"running (pid {pid})")
    else:
        print("not running")


def cmd_stop():
    pid = _read_pid()
    if not pid or not _pid_running(pid):
        print("not running")
        PID_FILE.unlink(missing_ok=True)
        return
    os.kill(pid, signal.SIGTERM)
    print(f"stopped (pid {pid})")
    PID_FILE.unlink(missing_ok=True)


def launch_detached():
    """Relaunch this script as a background process detached from the
    controlling terminal (new session, no inherited stdio) so it keeps
    running after the terminal window is closed, then exit this process."""
    existing = _read_pid()
    if existing and _pid_running(existing):
        print(f"already running (pid {existing})")
        sys.exit(0)

    RUN_DIR.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env[_DAEMON_ENV_FLAG] = "1"

    with open(LOG_FILE, "ab") as log:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__)],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            env=env,
            start_new_session=True,  # setsid: detach from this terminal's session
        )

    PID_FILE.write_text(str(proc.pid))
    print(f"sticky-agent-monitor started in background (pid {proc.pid})")
    print(f"logs: {LOG_FILE}")
    print(f"stop with: python3 {os.path.basename(__file__)} --stop")
    sys.exit(0)


if __name__ == "__main__":
    if "--stop" in sys.argv:
        cmd_stop()
        sys.exit(0)
    if "--status" in sys.argv:
        cmd_status()
        sys.exit(0)

    foreground = "--foreground" in sys.argv or os.environ.get(_DAEMON_ENV_FLAG) == "1"
    if not foreground:
        launch_detached()

    # Detached child (or explicit --foreground run) continues here.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    if os.environ.get(_DAEMON_ENV_FLAG) == "1":
        RUN_DIR.mkdir(parents=True, exist_ok=True)
        PID_FILE.write_text(str(os.getpid()))

    app = SessionMonitor()
    try:
        app.run()
    finally:
        if _read_pid() == os.getpid():
            PID_FILE.unlink(missing_ok=True)
