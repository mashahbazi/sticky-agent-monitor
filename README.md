# sticky-agent-monitor

A tiny native macOS menubar app that shows all of your active
[Claude Code](https://claude.com/claude-code) sessions, notifies you when one
needs attention, and attaches to any agent with a single keypress.

It polls `~/.claude/sessions/*.json` every few seconds and condenses the state
of every session into a compact menubar glyph, e.g. `🔔1 ▶3 ✓2`: one agent
waiting for input, three busy, two done. Press **Ctrl+Alt+A** anywhere (or
click the menubar item) to open the session list, then press **1**-**9** to
attach to a session, in a new iTerm tab, without touching the mouse.

## Features

- **Menubar glyph summary**: `🔔` waiting for input, `⛔` blocked/error,
  `▶` busy, `✓` done, each with a count. The bell only appears when an agent
  actually needs you, so a glance tells you whether to switch contexts.
- **Global hotkey (Ctrl+Alt+A, configurable)**: pops the menu open from any
  app. Uses Carbon's `RegisterEventHotKey`, so it needs no Accessibility
  permission and the keypress never leaks into the focused app. Change it in
  the Settings window (menu > Settings…, click the hotkey, press a new
  combination) or with `sticky-agent-monitor --hotkey "cmd+shift+k"`: the
  running instance re-registers immediately, no restart.
- **Real "needs input" detection**: session files only ever report
  busy/idle, so they can't distinguish "done" from "asked you a question".
  The monitor overlays the `state` field from `claude agents --json`
  ("working" / "done" / "blocked"), where `blocked` means the agent is
  waiting on you. That's what triggers the bell and the pop-out.
- **Octoclaude, the desktop pet**: a pixel-art octopus (SpriteKit, all art
  composed in code, no assets) that embodies the fleet. A pixel icon strip
  beside it mirrors the menubar counts; when an agent needs you it waves and
  shows a cartoony speech bubble listing the waiting sessions (pixel frame,
  monospaced text), including what each one is blocked on (permission,
  question, sandbox, ...). Click a bubble line to attach, right-click the
  bubble to snooze, click the octopus for the session menu, drag to move it;
  its position survives restarts. It sleeps
  when all is quiet, panics on errors, feeds on completed tasks (XP persisted
  in config) and earns a bandana at 25 completions and a top hat at 100.
  Disable via Settings ("Show desktop pet") or `"pet": false` in the config.
- **Attention pop-out**: with the pet disabled, a floating panel takes over
  the speech bubble's job: it slides in under the menubar when an agent
  starts waiting (or errors) and stays until the agent is handled, unlike a
  notification your brain learns to dismiss. It never steals keyboard focus;
  clicking a row attaches, `✕` snoozes until the agent's status next
  changes. Disable with `"popout": false` in the config file.
- **Keyboard-first attach**: menu items are numbered; plain `1`-`9` attaches
  instantly. Arrow keys + Enter work too. `a` opens the full `claude agents`
  TUI, `q` quits.
- **Direct attach, deduplicated**: attaching runs `claude attach <id>` in a
  new tab of your frontmost iTerm window (falls back to Terminal.app). If a
  tab is already attached to that session, it focuses that tab instead of
  opening another. From the attached view, left arrow returns to the agent
  list and Ctrl+Z drops to the shell; the session keeps running either way.
- **Clickable notifications**: when a session finishes you get a native
  notification. With
  [`terminal-notifier`](https://github.com/julienXX/terminal-notifier)
  installed (`brew install terminal-notifier`), clicking the notification
  attaches straight to that agent. Without it, plain notifications still
  work. Waiting/error states notify only when the pop-out panel is disabled;
  otherwise the panel handles them and notifying too would double up.
- **Readable titles**: if a session hasn't been given a friendly name yet, the
  monitor recovers its original task description from the session transcript
  instead of showing a bare hash like `125f85a7`.
- **Control-view standby hidden**: `claude agents` keeps an idle spare worker
  registered in `~/.claude/sessions/*.json` that looks like a real agent. The
  monitor detects and hides it.
- **Smart sorting**: sessions needing your attention sort to the top and get
  the low number keys.
- **No separate "idle" state**: a background agent only ever reports "busy" or
  "idle"; there's no distinct "just finished" signal. So "idle" is treated as
  **done** instead of a confusing third state.
- **Start at login**: a Settings checkbox installs/removes a LaunchAgent. A
  single-instance guard keeps a login-started and a manually started copy
  from running side by side.
- **Zero dependencies**: two Swift files, compiled with the system
  toolchain. No Electron, no Python, no packages.

## Requirements

- macOS with the Xcode Command Line Tools (`xcode-select --install`) for
  `swiftc`.
- Optional: `brew install terminal-notifier` for click-to-attach
  notifications.

## Usage

With [`mise`](https://mise.jdx.dev/):

```bash
mise run start       # build + start in background (menubar item appears)
mise run status      # check status
mise run stop        # stop it
mise run foreground  # run attached to the terminal, for debugging
```

Or by hand:

```bash
swiftc -O -swift-version 5 -o sticky-agent-monitor main.swift
./sticky-agent-monitor
```

By default the app starts **detached from the terminal**: it relaunches
itself as a background process and immediately returns your shell. Closing
the terminal doesn't kill it. A pidfile is kept at
`~/.sticky-agent-monitor/monitor.pid` and logs at
`~/.sticky-agent-monitor/monitor.log`.

### CLI

```bash
./sticky-agent-monitor --status        # is it running?
./sticky-agent-monitor --stop          # stop it
./sticky-agent-monitor --foreground    # run attached (debugging)
./sticky-agent-monitor --attach <id>   # attach to a session by short job id
```

`--attach` is what notification clicks invoke, and it also makes the monitor
scriptable from launchers like Raycast or skhd.

## Configuration

Tweak the constants near the top of `main.swift`:

| Constant         | Default              | Description                          |
| ---------------- | -------------------- | ------------------------------------ |
| `sessionsDir`    | `~/.claude/sessions` | Where session JSON files are read    |
| `pollInterval`   | `3.0`                | Poll interval in seconds             |
| `maxNumbered`    | `9`                  | Sessions that get a 1-9 shortcut     |
| `maxMenuRows`    | `20`                 | Sessions listed before "+N more"     |
| `hotKeyCode`     | `kVK_ANSI_A`         | Global hotkey key (with Ctrl+Alt)    |

## How it works

Each session JSON file contains fields such as `status`, `name`, `cwd`,
`sessionId`, `jobId`, and `updatedAt`. Files whose `pid` is no longer running
are ignored as stale. Each `status` maps to a glyph and sort priority; the
menu is rebuilt lazily each time it opens (`menuNeedsUpdate`), so it is
always fresh and there is no poll-vs-open race. State transitions (e.g.
`busy → waiting`) trigger notifications.

**Attaching.** `claude --resume` refuses sessions that are still running as
background agents, but `claude attach <jobId>` opens one directly in the
current terminal. The monitor scans `ps` for an existing
`claude attach <jobId>` process first; if one exists, an AppleScript walks
iTerm's windows/tabs, matches the process tty, and focuses that tab instead
of opening a duplicate.

**Title recovery.** Claude only auto-renames a session away from its
generated id once it's made enough progress to summarize the task; until
then, `name` just equals the id. When that happens, the monitor reads
`~/.claude/projects/<cwd-with-slashes-as-dashes>/<sessionId>.jsonl` and pulls
the first genuine user message as the title, skipping synthetic wrapper
content and unwrapping `<command-args>` when the task was given via a slash
command. Results are cached per session for the life of the process.

**Control-view detection.** A session is treated as the `claude agents`
standby worker only while it has an `agent` field set, is still `idle`, and
was never renamed away from its id. The moment you dispatch a task from
within `claude agents`, that session picks up real work and reappears on the
next poll.
