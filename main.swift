// sticky-agent-monitor: a native macOS menubar app that shows all active
// Claude Code sessions, notifies on state changes, and attaches to any agent
// with one keypress.
//
// Build:  swiftc -O -swift-version 5 -o sticky-agent-monitor main.swift
// Usage:
//   ./sticky-agent-monitor               start detached in the background
//   ./sticky-agent-monitor --foreground  run attached to this terminal
//   ./sticky-agent-monitor --stop        stop the running background instance
//   ./sticky-agent-monitor --status      check whether it's running
//   ./sticky-agent-monitor --attach <id> attach to a session by job id (used
//                                        by notification clicks / launchers)

import AppKit
import Carbon.HIToolbox

// MARK: - Config

let home = FileManager.default.homeDirectoryForCurrentUser
let sessionsDir = home.appendingPathComponent(".claude/sessions")
let runDir = home.appendingPathComponent(".sticky-agent-monitor")
let pidFile = runDir.appendingPathComponent("monitor.pid")
let logFile = runDir.appendingPathComponent("monitor.log")
let daemonEnvFlag = "_STICKY_AGENT_MONITOR_DAEMONIZED"

let pollInterval: TimeInterval = 3.0
let maxNumbered = 9   // sessions that get a 1-9 key equivalent in the menu
let maxMenuRows = 20  // sessions listed before the "+N more" indicator

// Global hotkey that pops the menubar menu open. Overridable at runtime via
// config.json ("hotkey" key) or `sticky-agent-monitor --hotkey <spec>`;
// the running app picks changes up on its next poll, no restart needed.
let configFile = runDir.appendingPathComponent("config.json")
let defaultHotKeySpec = "ctrl+alt+a"

// MARK: - Status model
//
// In practice a background agent only ever reports "busy" or "idle": there is
// no distinct "completed" status to tell "finished this task" apart from
// "finished and just sitting there". So "idle" is treated as done, full stop.

enum Category { case waiting, error, busy, done, stopped, other }

struct StatusMeta {
    let glyph: String
    let label: String
    let priority: Int
    let cat: Category
}

func statusMeta(_ status: String) -> StatusMeta {
    switch status {
    case "waiting":     return StatusMeta(glyph: "🔔", label: "WAITING", priority: 0, cat: .waiting)
    case "needs_input": return StatusMeta(glyph: "🔔", label: "NEEDS INPUT", priority: 0, cat: .waiting)
    case "blocked":     return StatusMeta(glyph: "⛔", label: "BLOCKED", priority: 1, cat: .error)
    case "error":       return StatusMeta(glyph: "⛔", label: "ERROR", priority: 2, cat: .error)
    case "busy", "running", "working":
                        return StatusMeta(glyph: "▶", label: "BUSY", priority: 3, cat: .busy)
    case "idle", "completed", "done":
                        return StatusMeta(glyph: "✓", label: "DONE", priority: 5, cat: .done)
    case "stopped":     return StatusMeta(glyph: "◼", label: "STOPPED", priority: 6, cat: .stopped)
    default:            return StatusMeta(glyph: "·", label: status.uppercased(), priority: 99, cat: .other)
    }
}

// Statuses that trigger notifications when transitioned INTO.
let notifyWaiting: Set<String> = ["waiting", "needs_input"]
let notifyDone: Set<String> = ["completed", "done", "idle"]
let notifyError: Set<String> = ["error", "blocked"]

// MARK: - Session model

struct Session {
    let raw: [String: Any]
    let fileID: String
    let mtime: TimeInterval

    // Richer state from `claude agents --json`, overlaid after reading the
    // session file. The file's own `status` only ever reports busy/idle: it
    // cannot distinguish "done" from "asked the user a question and is
    // waiting". The CLI's `state` can ("working" / "done" / "blocked").
    var state: String?

    var pid: Int32 { (raw["pid"] as? NSNumber)?.int32Value ?? 0 }
    var fileStatus: String { ((raw["status"] as? String) ?? "unknown").lowercased() }
    var status: String {
        guard let st = state else { return fileStatus }
        switch st {
        case "working":
            // After a session is closed and reopened, the CLI resets its
            // state to "working" even when nothing runs; the file's
            // busy/idle is the reliable "is it actually computing" signal.
            return fileStatus == "busy" ? "busy" : fileStatus
        case "done": return "done"
        case "blocked": return "needs_input"  // agent is waiting on the user
        default: return st.lowercased()
        }
    }
    var rawName: String { ((raw["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces) }
    var jobId: String? { raw["jobId"] as? String }
    var sessionId: String? { raw["sessionId"] as? String }
    var cwd: String { (raw["cwd"] as? String) ?? "" }
    var agent: String { (raw["agent"] as? String) ?? "" }
    var updatedAt: Double { (raw["updatedAt"] as? NSNumber)?.doubleValue ?? 0 }
    var sortTime: TimeInterval { updatedAt > 0 ? updatedAt / 1000 : mtime }

    // `claude attach` matches on the short job id (e.g. "88eee316"), not the
    // full session UUID. The jobId is the first UUID segment in practice.
    var shortJobId: String? {
        if let j = jobId, !j.isEmpty { return j }
        if let sid = sessionId, let first = sid.split(separator: "-").first { return String(first) }
        return nil
    }
}

func procAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM  // exists but owned by someone else: treat as alive
}

// `claude agents` (the background-agent control TUI) keeps an idle spare
// worker on standby, registered in ~/.claude/sessions/*.json like any real
// session. It has an `agent` field set, is still idle, and was never renamed
// away from its own auto-generated id. Hide those.
func isControlSession(_ s: Session) -> Bool {
    guard let jobId = s.jobId else { return false }
    return !s.agent.isEmpty && s.status == "idle" && s.rawName == jobId
}

func readSessionFiles() -> [Session] {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return [] }

    var sessions: [Session] = []
    for f in files where f.pathExtension == "json" {
        guard let data = try? Data(contentsOf: f),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let s = Session(raw: raw, fileID: f.deletingPathExtension().lastPathComponent, mtime: mtime)
        guard procAlive(s.pid) else { continue }  // stale file from a dead session
        if isControlSession(s) { continue }
        // Interactive terminal sessions register files too, but this monitor
        // is for background agents (and `claude attach` can't target them).
        if (raw["kind"] as? String) == "interactive" { continue }
        sessions.append(s)
    }
    return sessions
}

let claudePath: String? = {
    let candidates = [
        home.appendingPathComponent(".local/bin/claude").path,
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    let found = runCapture(["/usr/bin/which", "claude"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return found.isEmpty ? nil : found
}()

// sessionId -> state ("working" / "done" / "blocked") from the claude CLI.
func fetchAgentStates() -> [String: String] {
    guard let claude = claudePath else { return [:] }
    let out = runCapture([claude, "agents", "--json"])
    guard let data = out.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [:] }
    var map: [String: String] = [:]
    for row in rows {
        if let sid = row["sessionId"] as? String, let state = row["state"] as? String {
            map[sid] = state
        }
    }
    return map
}

// Session files merged with CLI states, sorted attention-first. Spawns the
// claude CLI, so call it off the main thread in UI contexts.
func loadSessions() -> [Session] {
    var sessions = readSessionFiles()
    let states = fetchAgentStates()
    if !states.isEmpty {
        // The CLI's list is authoritative: a finished session's worker
        // process can linger (for reattach) long after `claude agents` has
        // dropped it, so a session file with a live pid is not proof the
        // session is still real. Only trust the files alone when the CLI
        // gave us nothing (missing binary, error).
        sessions = sessions.filter { s in
            guard let sid = s.sessionId else { return false }
            return states[sid] != nil
        }
        for i in sessions.indices {
            if let sid = sessions[i].sessionId {
                sessions[i].state = states[sid]
            }
        }
    }
    sessions.sort { a, b in
        let pa = statusMeta(a.status).priority
        let pb = statusMeta(b.status).priority
        if pa != pb { return pa < pb }
        return a.sortTime > b.sortTime
    }
    return sessions
}

// MARK: - Title recovery
//
// Claude only auto-renames a session away from its generated id once it has
// made enough progress to summarize the task. Until then, recover the
// session's original task from the first genuine user message in its
// transcript. Cached per session: the original task never changes.

var firstMessageCache: [String: String] = [:]

func extractText(_ content: Any?) -> String? {
    if let s = content as? String { return s }
    if let blocks = content as? [[String: Any]] {
        for b in blocks where (b["type"] as? String) == "text" {
            return b["text"] as? String
        }
    }
    return nil
}

let commandArgsRegex = try! NSRegularExpression(
    pattern: "<command-args>(.*?)</command-args>", options: [.dotMatchesLineSeparators])

// Pull a usable one-line title out of a raw transcript message, or nil if the
// message is just wrapper/caveat noise rather than real content.
func candidateTitle(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    let ns = t as NSString
    // Slash-command invocations wrap the real task in <command-args>.
    if let m = commandArgsRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
        let args = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return args.isEmpty ? nil : args  // empty args (bare "/clear") isn't a title
    }
    // Other synthetic wrapper content (caveats, tool/system tags) starts with "<".
    if t.hasPrefix("<") { return nil }
    return t
}

func firstUserMessage(cwd: String, sessionId: String) -> String? {
    if let cached = firstMessageCache[sessionId] { return cached.isEmpty ? nil : cached }

    let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
    let path = home.appendingPathComponent(".claude/projects/\(projectDir)/\(sessionId).jsonl")
    var result = ""
    if let fh = try? FileHandle(forReadingFrom: path) {
        let data = fh.readData(ofLength: 512 * 1024)  // transcripts can be huge
        try? fh.close()
        if let text = String(data: data, encoding: .utf8) {
            for (i, line) in text.split(separator: "\n").enumerated() {
                if i > 200 { break }
                guard let d = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      (entry["type"] as? String) == "user",
                      let msg = entry["message"] as? [String: Any],
                      let found = extractText(msg["content"]),
                      let title = candidateTitle(found)
                else { continue }
                result = title.split(separator: "\n").first
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                if !result.isEmpty { break }
            }
        }
    }
    firstMessageCache[sessionId] = result
    return result.isEmpty ? nil : result
}

func displayName(_ s: Session) -> String {
    var name = s.rawName
    let isPlaceholder = name.isEmpty || (s.jobId != nil && name == s.jobId)
    if isPlaceholder, !s.cwd.isEmpty, let sid = s.sessionId,
       let first = firstUserMessage(cwd: s.cwd, sessionId: sid) {
        name = first
    }
    return name.isEmpty ? String(s.fileID.prefix(10)) : name
}

func formatAgo(_ s: Session) -> String {
    let t = s.sortTime
    guard t > 0 else { return "" }
    let delta = Date().timeIntervalSince1970 - t
    if delta < 60 { return "\(Int(delta))s" }
    if delta < 3600 { return "\(Int(delta / 60))m" }
    return "\(Int(delta / 3600))h"
}

// MARK: - Shell helpers

func runCapture(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func runOsascript(_ script: String, wait: Bool = false) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    p.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    p.standardError = errPipe
    p.terminationHandler = { _ in
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !data.isEmpty, let msg = String(data: data, encoding: .utf8),
           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("osascript error: %@", msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    guard (try? p.run()) != nil else { return }
    if wait { p.waitUntilExit() }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func applescriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// MARK: - Attach

// Return the tty (e.g. "/dev/ttys009") of an already-running
// `claude attach <jobId>` process, or nil if there isn't one.
func findAttachTTY(_ jobId: String) -> String? {
    let out = runCapture(["/bin/ps", "-eo", "tty=,command="])
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { continue }
        let tty = String(parts[0])
        if tty != "??", parts[1].contains("claude attach \(jobId)") {
            return "/dev/\(tty)"
        }
    }
    return nil
}

// Open a new tab in the frontmost iTerm2 window running `shellCmd`, or focus
// the iTerm tab whose session sits on `focusTTY` if given (dedup: don't open
// a second tab for a session that's already attached somewhere). Falls back
// to a new Terminal.app window when iTerm2 isn't running.
func openInTerminal(_ shellCmd: String, focusTTY: String? = nil, wait: Bool = false) {
    let escaped = applescriptEscape(shellCmd)

    let focusAndFallback: String
    if let tty = focusTTY {
        focusAndFallback = """
                set found to false
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(applescriptEscape(tty))" then
                                select w
                                tell w to select t
                                tell t to select s
                                set found to true
                                exit repeat
                            end if
                        end repeat
                        if found then exit repeat
                    end repeat
                    if found then exit repeat
                end repeat
                if not found then
        """
    } else {
        focusAndFallback = "        if true then"
    }

    // Targeting iTerm by bundle id launches it when it isn't running (the
    // display name "iTerm2" only resolves while the app is already open,
    // since the app file is iTerm.app). On a cold launch, wait for iTerm's
    // own startup window and write into its fresh shell instead of racing
    // it with a second window. The try block falls back to Terminal.app
    // only when iTerm isn't installed.
    let script = """
    try
        set wasRunning to running of application id "com.googlecode.iterm2"
        tell application id "com.googlecode.iterm2"
            activate
            if wasRunning then
    \(focusAndFallback)
                    if (count of windows) is 0 then
                        create window with default profile
                    else
                        tell current window to create tab with default profile
                    end if
                    tell current session of current window to write text "\(escaped)"
                end if
            else
                set tries to 0
                repeat while (count of windows) is 0 and tries < 30
                    delay 0.1
                    set tries to tries + 1
                end repeat
                if (count of windows) is 0 then
                    create window with default profile
                end if
                tell current session of current window to write text "\(escaped)"
            end if
        end tell
    on error
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
    end try
    """
    runOsascript(script, wait: wait)
}

// Attach directly to a background session via `claude attach <jobId>`. If a
// tab is already running that attach, focus it instead of opening another.
// From the attached view, left arrow returns to the agent list and Ctrl+Z
// drops to the shell; the session keeps running either way.
func attachSession(_ s: Session, wait: Bool = false) {
    guard let jobId = s.shortJobId else { return }
    let cwd = s.cwd.isEmpty ? NSHomeDirectory() : s.cwd
    let cmd = "cd \(shellQuote(cwd)) && claude attach \(shellQuote(jobId))"
    openInTerminal(cmd, focusTTY: findAttachTTY(jobId), wait: wait)
}

func openAgentsTUI(wait: Bool = false) {
    openInTerminal("claude agents", wait: wait)
}

// MARK: - Notifications

let executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]

// terminal-notifier (brew install terminal-notifier) makes notifications
// clickable: clicking one attaches straight to the agent that needs you.
// Without it, fall back to plain osascript notifications.
let terminalNotifierPath: String? = {
    for p in ["/opt/homebrew/bin/terminal-notifier", "/usr/local/bin/terminal-notifier"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    let found = runCapture(["/usr/bin/which", "terminal-notifier"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return found.isEmpty ? nil : found
}()

func notify(title: String, message: String, attachJobId: String? = nil) {
    if let tn = terminalNotifierPath {
        var args = [tn, "-title", title, "-message", message, "-sound", "Glass"]
        if let job = attachJobId {
            args += ["-execute", "\(shellQuote(executablePath)) --attach \(shellQuote(job))"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    } else {
        runOsascript("display notification \"\(applescriptEscape(message))\" "
            + "with title \"\(applescriptEscape(title))\" sound name \"Glass\"")
    }
}

// MARK: - Hotkey config

struct HotKeySpec: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String
}

let keyCodeMap: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
    "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
    "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
    "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
    "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
    "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
    "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
    "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    "space": kVK_Space, "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave,
    "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
    "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
    ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
    "\\": kVK_ANSI_Backslash, "backslash": kVK_ANSI_Backslash,
    "tab": kVK_Tab, "return": kVK_Return, "enter": kVK_Return,
]

// Parse a spec like "ctrl+alt+a", "cmd+shift+k", or "f6" (f-keys may omit
// modifiers; everything else requires at least one so plain typing can't
// trigger it). Returns nil on anything unrecognized.
func parseHotKey(_ spec: String) -> HotKeySpec? {
    var mods: UInt32 = 0
    var key: String?
    for tokenRaw in spec.lowercased().split(separator: "+") {
        let token = tokenRaw.trimmingCharacters(in: .whitespaces)
        switch token {
        case "ctrl", "control":        mods |= UInt32(controlKey)
        case "alt", "opt", "option":   mods |= UInt32(optionKey)
        case "cmd", "command":         mods |= UInt32(cmdKey)
        case "shift":                  mods |= UInt32(shiftKey)
        case "": continue
        default:
            if key != nil { return nil }
            key = token
        }
    }
    guard let k = key, let code = keyCodeMap[k] else { return nil }
    let isFKey = k.hasPrefix("f") && k.count > 1
    if mods == 0 && !isFKey { return nil }

    var display = ""
    if mods & UInt32(controlKey) != 0 { display += "⌃" }
    if mods & UInt32(optionKey) != 0 { display += "⌥" }
    if mods & UInt32(shiftKey) != 0 { display += "⇧" }
    if mods & UInt32(cmdKey) != 0 { display += "⌘" }
    display += k.uppercased()
    return HotKeySpec(keyCode: UInt32(code), modifiers: mods, display: display)
}

func readConfig() -> [String: Any] {
    guard let data = try? Data(contentsOf: configFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

func configuredHotKeySpec() -> String {
    (readConfig()["hotkey"] as? String) ?? defaultHotKeySpec
}

func writeConfig(_ updates: [String: Any]) {
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    var config = readConfig()
    for (k, v) in updates { config[k] = v }
    if let data = try? JSONSerialization.data(
        withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: configFile)
    }
}

// keyCode -> canonical spec token (aliases resolve to the shortest name).
let reverseKeyCodeMap: [Int: String] = Dictionary(
    keyCodeMap.map { ($1, $0) }, uniquingKeysWith: { min($0, $1) })

// A button that turns into a shortcut recorder when clicked: the next
// keypress (with its modifiers) becomes the new hotkey. Esc cancels.
final class HotKeyRecorderButton: NSButton {
    var displaySpec: String = "" {
        didSet { if !recording { title = displaySpec } }
    }
    var onRecordStart: (() -> Void)?
    var onRecorded: ((String) -> Void)?  // spec string, e.g. "ctrl+alt+a"
    var onCancel: (() -> Void)?
    private var monitor: Any?
    private var recording = false

    convenience init() {
        self.init(title: "", target: nil, action: nil)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
    }

    @objc private func toggleRecording() {
        recording ? cancelRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        title = "Press shortcut…"
        onRecordStart?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleKey(ev)
            return nil  // swallow the event
        }
    }

    private func stopMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        recording = false
    }

    private func cancelRecording() {
        stopMonitor()
        title = displaySpec
        onCancel?()
    }

    private func handleKey(_ ev: NSEvent) {
        if Int(ev.keyCode) == kVK_Escape {
            cancelRecording()
            return
        }
        guard let keyName = reverseKeyCodeMap[Int(ev.keyCode)] else {
            NSSound.beep()
            return
        }
        var parts: [String] = []
        if ev.modifierFlags.contains(.control) { parts.append("ctrl") }
        if ev.modifierFlags.contains(.option) { parts.append("alt") }
        if ev.modifierFlags.contains(.shift) { parts.append("shift") }
        if ev.modifierFlags.contains(.command) { parts.append("cmd") }
        let isFKey = keyName.hasPrefix("f") && keyName.count > 1
        if parts.isEmpty && !isFKey {
            NSSound.beep()  // unmodified plain keys would fire while typing
            return
        }
        parts.append(keyName)
        stopMonitor()
        onRecorded?(parts.joined(separator: "+"))
    }
}

func configModTime() -> TimeInterval {
    let attrs = try? FileManager.default.attributesOfItem(atPath: configFile.path)
    return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
}

// MARK: - Attention panel
//
// A floating, non-activating panel that slides in under the menubar whenever
// an agent is waiting for input or errored. Unlike a notification it cannot
// be reflex-dismissed: it stays until the agent is handled (or snoozed with
// its dismiss button), and it never steals keyboard focus from what you're
// typing. Clicking a row attaches to that agent.

final class AttentionPanel: NSObject {
    private let panel: NSPanel
    private let stack = NSStackView()
    private let container = NSVisualEffectView()
    private var sessions: [Session] = []
    var onAttach: ((Session) -> Void)?
    var onDismiss: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
        super.init()
    }

    func update(_ needy: [Session]) {
        sessions = needy
        if needy.isEmpty {
            hide()
            return
        }
        rebuildRows()
        show()
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        let title = NSTextField(labelWithString: "Agents need you")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        let dismiss = NSButton(title: "✕", target: self, action: #selector(dismissClicked(_:)))
        dismiss.isBordered = false
        dismiss.font = NSFont.systemFont(ofSize: 11)
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())  // spacer
        header.addArrangedSubview(dismiss)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        for (i, s) in sessions.enumerated() {
            let meta = statusMeta(s.status)
            var name = displayName(s)
            if name.count > 40 { name = String(name.prefix(38)) + "…" }
            let leaf = (s.cwd as NSString).lastPathComponent
            let row = NSButton(
                title: "\(meta.glyph)  \(name)   (\(leaf), \(formatAgo(s)))",
                target: self, action: #selector(rowClicked(_:)))
            row.isBordered = false
            row.alignment = .left
            row.font = NSFont.systemFont(ofSize: 13)
            row.tag = i
            stack.addArrangedSubview(row)
        }
    }

    private func show() {
        container.layoutSubtreeIfNeeded()
        var size = container.fittingSize
        size.width = max(size.width, 280)
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12,
                                         y: vf.maxY - size.height - 8))
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }

    @objc private func rowClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < sessions.count else { return }
        onAttach?(sessions[sender.tag])
    }

    @objc private func dismissClicked(_ sender: NSButton) {
        onDismiss?()
        hide()
    }
}

// MARK: - Menubar app

func menubarTitle(_ sessions: [Session]) -> String {
    var counts: [Category: Int] = [:]
    for s in sessions { counts[statusMeta(s.status).cat, default: 0] += 1 }
    var parts: [String] = []
    if let n = counts[.waiting], n > 0 { parts.append("🔔\(n)") }
    if let n = counts[.error], n > 0 { parts.append("⛔\(n)") }
    if let n = counts[.busy], n > 0 { parts.append("▶\(n)") }
    if let n = counts[.done], n > 0 { parts.append("✓\(n)") }
    return parts.isEmpty ? "–" : parts.joined(separator: " ")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?
    var prevStates: [String: String] = [:]
    var menuSessions: [Session] = []
    var lastSessions: [Session] = []
    var polling = false
    var hotKeyRef: EventHotKeyRef?
    var currentHotKey: HotKeySpec?
    var lastConfigMtime: TimeInterval = -1
    var popoutEnabled = true
    var snoozed: Set<String> = []
    let attentionPanel = AttentionPanel()
    var settingsWindow: NSWindow?
    var recorderButton: HotKeyRecorderButton?
    var popoutCheckbox: NSButton?
    var petCheckbox: NSButton?
    var pet: PetController?
    var petEnabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        menu.delegate = self
        statusItem.menu = menu
        installHotKeyHandler()
        attentionPanel.onAttach = { attachSession($0) }
        attentionPanel.onDismiss = { [weak self] in self?.snoozeCurrent() }

        let petCtl = PetController(initialXP: (readConfig()["petXP"] as? Int) ?? 0)
        petCtl.onAttach = { [weak self] fileID in
            guard let self = self,
                  let s = self.lastSessions.first(where: { $0.fileID == fileID }) else { return }
            attachSession(s)
        }
        petCtl.onOpenMenu = { [weak self] in self?.openMenu() }
        petCtl.onDismissBubble = { [weak self] in self?.snoozeCurrent() }
        petCtl.onXPChanged = { xp in
            writeConfig(["petXP": xp])
        }
        pet = petCtl
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let s = try? String(contentsOf: pidFile, encoding: .utf8),
           Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid() {
            try? FileManager.default.removeItem(at: pidFile)
        }
    }

    // Session loading spawns the claude CLI (up to ~1s), so it runs off the
    // main thread; all state mutation and UI updates hop back to main.
    func poll() {
        applyConfigIfChanged()
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = loadSessions()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                self.lastSessions = sessions
                self.statusItem.button?.title = menubarTitle(sessions)
                self.checkNotifications(sessions)
                self.updateAttentionPanel(sessions)
                self.updatePet(sessions)
            }
        }
    }

    func applyConfigIfChanged() {
        let mtime = configModTime()
        guard mtime != lastConfigMtime else { return }
        lastConfigMtime = mtime
        let config = readConfig()
        popoutEnabled = (config["popout"] as? Bool) ?? true
        petEnabled = (config["pet"] as? Bool) ?? true
        pet?.setEnabled(petEnabled)
        applyHotKey((config["hotkey"] as? String) ?? defaultHotKeySpec)
    }

    // Which sessions the pop-out panel shows: waiting or errored, minus ones
    // snoozed via the panel's dismiss button. A snooze is keyed on
    // session+status, so it clears itself as soon as the status changes.
    func needySessions(_ sessions: [Session]) -> [Session] {
        let needy = sessions.filter {
            let cat = statusMeta($0.status).cat
            return cat == .waiting || cat == .error
        }
        snoozed.formIntersection(Set(needy.map { "\($0.fileID):\($0.status)" }))
        return needy.filter { !snoozed.contains("\($0.fileID):\($0.status)") }
    }

    // The pet's speech bubble takes over the attention role when it's
    // enabled; the floating panel remains as the pet-less fallback.
    func updateAttentionPanel(_ sessions: [Session]) {
        let usePanel = popoutEnabled && !petEnabled
        attentionPanel.update(usePanel ? needySessions(sessions) : [])
    }

    func snoozeCurrent() {
        for s in needySessions(lastSessions) {
            snoozed.insert("\(s.fileID):\(s.status)")
        }
    }

    func updatePet(_ sessions: [Session]) {
        guard petEnabled else { return }
        var counts = PetStatusCounts()
        for s in sessions {
            switch statusMeta(s.status).cat {
            case .waiting: counts.waiting += 1
            case .error: counts.error += 1
            case .busy: counts.busy += 1
            case .done: counts.done += 1
            default: break
            }
        }
        let rows: [PetBubbleRow] = popoutEnabled ? needySessions(sessions).map { s in
            let kind: PetAgentKind = statusMeta(s.status).cat == .error ? .error : .waiting
            var name = displayName(s)
            if name.count > 20 { name = String(name.prefix(20)) }
            return PetBubbleRow(id: s.fileID, kind: kind,
                                text: "\(name) \(formatAgo(s))")
        } : []
        pet?.update(counts: counts, rows: rows)
    }

    func checkNotifications(_ sessions: [Session]) {
        var current: [String: String] = [:]
        for s in sessions {
            let status = s.status
            current[s.fileID] = status
            guard let prev = prevStates[s.fileID] else { continue }
            let name = displayName(s)
            // Waiting/error are the attention panel's job; notifying too
            // would just double up. Only fall back to notifications for them
            // when the pop-out is disabled. "Completed" has no panel row, so
            // it always notifies.
            if notifyWaiting.contains(status) && !notifyWaiting.contains(prev) {
                if !popoutEnabled {
                    notify(title: "Needs Input", message: "\(name) is waiting for you", attachJobId: s.shortJobId)
                }
            } else if notifyDone.contains(status) && !notifyDone.contains(prev) {
                notify(title: "Completed", message: "\(name) finished", attachJobId: s.shortJobId)
                pet?.gainXP()  // the pet feeds on completed tasks
            } else if notifyError.contains(status) && !notifyError.contains(prev) {
                if !popoutEnabled {
                    notify(title: "Attention", message: "\(name) hit an error", attachJobId: s.shortJobId)
                }
            }
        }
        prevStates = current
    }

    // Rebuild lazily right before the menu opens, from the last poll's data
    // (at most 3s stale; loading fresh here would block menu open on the
    // claude CLI).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = lastSessions
        menuSessions = sessions

        if sessions.isEmpty {
            menu.addItem(withTitle: "No active sessions", action: nil, keyEquivalent: "")
        }

        for (i, s) in sessions.prefix(maxMenuRows).enumerated() {
            let meta = statusMeta(s.status)
            var name = displayName(s)
            if name.count > 44 { name = String(name.prefix(42)) + "…" }
            let leaf = (s.cwd as NSString).lastPathComponent
            let ago = formatAgo(s)
            let item = NSMenuItem(
                title: "\(meta.glyph)  \(name)   (\(leaf), \(ago))",
                action: #selector(attachAction(_:)),
                keyEquivalent: i < maxNumbered ? "\(i + 1)" : ""
            )
            item.keyEquivalentModifierMask = []  // plain 1-9, no modifier
            item.target = self
            item.tag = i
            menu.addItem(item)
        }

        if sessions.count > maxMenuRows {
            menu.addItem(withTitle: "+\(sessions.count - maxMenuRows) more…",
                         action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        if let hk = currentHotKey {
            menu.addItem(withTitle: "Hotkey: \(hk.display)", action: nil, keyEquivalent: "")
        }
        let tui = NSMenuItem(title: "Open claude agents TUI",
                             action: #selector(openTUIAction(_:)), keyEquivalent: "a")
        tui.keyEquivalentModifierMask = []
        tui.target = self
        menu.addItem(tui)
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettingsAction(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = []
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func attachAction(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < menuSessions.count else { return }
        attachSession(menuSessions[sender.tag])
    }

    @objc func openTUIAction(_ sender: NSMenuItem) {
        openAgentsTUI()
    }

    // MARK: Settings window

    @objc func openSettingsAction(_ sender: Any?) {
        if settingsWindow == nil { buildSettingsWindow() }
        recorderButton?.displaySpec = currentHotKey?.display ?? configuredHotKeySpec()
        popoutCheckbox?.state = popoutEnabled ? .on : .off
        petCheckbox?.state = petEnabled ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildSettingsWindow() {
        let recorder = HotKeyRecorderButton()
        // While recording, release the current registration so the old combo
        // reaches the recorder instead of being swallowed system-wide.
        recorder.onRecordStart = { [weak self] in
            guard let self = self else { return }
            if let ref = self.hotKeyRef {
                UnregisterEventHotKey(ref)
                self.hotKeyRef = nil
            }
            self.currentHotKey = nil
        }
        recorder.onRecorded = { [weak self] spec in
            guard let self = self else { return }
            self.applyHotKey(spec)
            writeConfig(["hotkey": spec])
            self.lastConfigMtime = configModTime()  // our own write, already applied
            recorder.displaySpec = self.currentHotKey?.display ?? spec
        }
        recorder.onCancel = { [weak self] in
            self?.applyHotKey(configuredHotKeySpec())
        }

        let checkbox = NSButton(checkboxWithTitle: "Show pop-out panel when agents need input",
                                target: self, action: #selector(popoutToggled(_:)))
        let petBox = NSButton(checkboxWithTitle: "Show desktop pet",
                              target: self, action: #selector(petToggled(_:)))

        let hotkeyLabel = NSTextField(labelWithString: "Global hotkey:")
        let hotkeyRow = NSStackView(views: [hotkeyLabel, recorder])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8

        let hint = NSTextField(
            labelWithString: "Click the hotkey, then press a new combination. Esc cancels.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [hotkeyRow, checkbox, petBox, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "sticky-agent-monitor"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.center()

        settingsWindow = win
        recorderButton = recorder
        popoutCheckbox = checkbox
        petCheckbox = petBox
    }

    @objc func petToggled(_ sender: NSButton) {
        petEnabled = sender.state == .on
        writeConfig(["pet": petEnabled])
        lastConfigMtime = configModTime()  // our own write, already applied
        pet?.setEnabled(petEnabled)
        if petEnabled { updatePet(lastSessions) }
    }

    @objc func popoutToggled(_ sender: NSButton) {
        popoutEnabled = sender.state == .on
        writeConfig(["popout": popoutEnabled])
        lastConfigMtime = configModTime()  // our own write, already applied
        updateAttentionPanel(lastSessions)
    }

    // The global hotkey pops the menu open from anywhere. Carbon's
    // RegisterEventHotKey needs no Accessibility permission and consumes the
    // keypress, unlike NSEvent global monitors. The handler is installed
    // once; the actual key registration can be swapped at runtime whenever
    // config.json changes.
    func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            NSLog("hotkey pressed, opening menu")
            DispatchQueue.main.async { delegate.openMenu() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func applyHotKey(_ specString: String) {
        guard let spec = parseHotKey(specString) else {
            NSLog("invalid hotkey spec '\(specString)'; keeping \(currentHotKey?.display ?? "none")")
            return
        }
        if spec == currentHotKey { return }
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: 0x53414D4E, id: 1)  // "SAMN"
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // -9878 (hotKeyExistsErr) means another app owns this combo.
            NSLog("hotkey registration FAILED for \(spec.display) (OSStatus \(status))")
            currentHotKey = nil
        } else {
            NSLog("hotkey registered: \(spec.display) ('\(specString)')")
            currentHotKey = spec
        }
    }

    func openMenu() {
        statusItem.button?.performClick(nil)
    }
}

// MARK: - CLI plumbing

func readPidFile() -> Int32? {
    guard let s = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
    return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func cmdStatus() {
    if let pid = readPidFile(), procAlive(pid) {
        print("running (pid \(pid))")
    } else {
        print("not running")
    }
}

func cmdStop() {
    guard let pid = readPidFile(), procAlive(pid) else {
        print("not running")
        try? FileManager.default.removeItem(at: pidFile)
        return
    }
    kill(pid, SIGTERM)
    print("stopped (pid \(pid))")
    try? FileManager.default.removeItem(at: pidFile)
}

func cmdAttach(_ idArg: String) {
    let target = loadSessions().first { s in
        s.shortJobId == idArg || s.jobId == idArg || (s.sessionId?.hasPrefix(idArg) ?? false)
    }
    guard let s = target else {
        FileHandle.standardError.write(Data("no running session matching '\(idArg)'\n".utf8))
        exit(1)
    }
    attachSession(s, wait: true)
}

// Validate a hotkey spec, persist it to config.json. The running instance
// notices the config change on its next poll and re-registers, no restart.
func cmdHotkey(_ spec: String) {
    guard let parsed = parseHotKey(spec) else {
        FileHandle.standardError.write(Data(
            "invalid hotkey '\(spec)'. Format: modifiers+key, e.g. ctrl+alt+a, cmd+shift+k, f6\n".utf8))
        exit(1)
    }
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    var config = readConfig()
    config["hotkey"] = spec
    guard let data = try? JSONSerialization.data(
        withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
        (try? data.write(to: configFile)) != nil
    else {
        FileHandle.standardError.write(Data("failed to write \(configFile.path)\n".utf8))
        exit(1)
    }
    print("hotkey set to \(parsed.display) (\(spec))")
    if let pid = readPidFile(), procAlive(pid) {
        print("running instance (pid \(pid)) picks it up within \(Int(pollInterval))s")
    } else {
        print("takes effect on next start")
    }
}

// Relaunch as a background process detached from the controlling terminal so
// it keeps running after the terminal window is closed, then exit.
func launchDetached() -> Never {
    if let pid = readPidFile(), procAlive(pid) {
        print("already running (pid \(pid))")
        exit(0)
    }
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logFile.path) {
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
    }
    let log = try? FileHandle(forWritingTo: logFile)
    log?.seekToEndOfFile()

    let p = Process()
    p.executableURL = URL(fileURLWithPath: executablePath)
    var env = ProcessInfo.processInfo.environment
    env[daemonEnvFlag] = "1"
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = log ?? FileHandle.nullDevice
    p.standardError = log ?? FileHandle.nullDevice
    do { try p.run() } catch {
        print("failed to launch background process: \(error)")
        exit(1)
    }
    try? String(p.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    print("sticky-agent-monitor started in background (pid \(p.processIdentifier))")
    print("logs: \(logFile.path)")
    print("stop with: sticky-agent-monitor --stop")
    exit(0)
}

// MARK: - Main

let args = CommandLine.arguments

if args.contains("--stop") { cmdStop(); exit(0) }
if args.contains("--status") { cmdStatus(); exit(0) }
if let i = args.firstIndex(of: "--attach"), i + 1 < args.count {
    cmdAttach(args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--hotkey"), i + 1 < args.count {
    cmdHotkey(args[i + 1])
    exit(0)
}

let isDaemonChild = ProcessInfo.processInfo.environment[daemonEnvFlag] == "1"
if !args.contains("--foreground") && !isDaemonChild {
    launchDetached()
}

signal(SIGHUP, SIG_IGN)
if isDaemonChild {
    setsid()  // detach from the parent terminal's session
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    try? String(getpid()).write(to: pidFile, atomically: true, encoding: .utf8)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
