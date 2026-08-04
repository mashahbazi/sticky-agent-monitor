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
//   ./sticky-agent-monitor --list        print each session's classified state
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

// How long a finished agent's row lingers in the speech bubble / pop-out. It
// reports an event you cannot act on any faster, so it behaves like a
// notification and retires itself. Blocked agents ignore this and hold their
// row until they are actually unblocked.
let transientRowTTL: TimeInterval = 5.0

// Rows the speech bubble can show before it outgrows the pet's window and gets
// clipped. The overflow row replaces the last one, and since busy agents sort
// last, they are what gets folded away first.
let maxBubbleRows = 7

// Global hotkey that pops the menubar menu open. Overridable at runtime via
// config.json ("hotkey" key) or `sticky-agent-monitor --hotkey <spec>`;
// the running app picks changes up on its next poll, no restart needed.
let configFile = runDir.appendingPathComponent("config.json")
let defaultHotKeySpec = "ctrl+alt+a"

// MARK: - Status model
//
// Two very different situations both look like "the agent stopped", and
// treating them the same is what makes a monitor cry wolf:
//
//   BLOCKED  the agent is parked at a gate right now — a permission prompt,
//            an AskUserQuestion dialog, a sandbox/worker request. It cannot
//            take one more step until you act. The session file says
//            status "waiting" and names the gate in `waitingFor`.
//   ASKED    the agent finished its turn and its closing message asked you
//            something ("which approach?", "shall I continue?"). Nothing is
//            parked: it is idle, exactly like a plain completion, and just
//            wants your next prompt whenever you get to it.
//
// `claude agents --json` reports state "blocked" for BOTH — for the second
// case it infers that from the agent's closing prose, not from an actual
// gate — so `state` alone cannot separate them. `waitingFor` can.
//
// Only BLOCKED is urgent. ASKED is a completion with a follow-up question.

enum Category { case blocked, error, asked, busy, done, stopped, other }

struct StatusMeta {
    let glyph: String
    let label: String
    let priority: Int
    let cat: Category
}

func statusMeta(_ status: String) -> StatusMeta {
    switch status {
    case "waiting", "needs_input", "blocked":
                        return StatusMeta(glyph: "🔔", label: "BLOCKED", priority: 0, cat: .blocked)
    case "error", "failed":
                        return StatusMeta(glyph: "⛔", label: "ERROR", priority: 1, cat: .error)
    case "asked":       return StatusMeta(glyph: "💬", label: "ASKED", priority: 2, cat: .asked)
    case "busy", "running", "working":
                        return StatusMeta(glyph: "▶", label: "BUSY", priority: 3, cat: .busy)
    case "idle", "completed", "done":
                        return StatusMeta(glyph: "✓", label: "DONE", priority: 5, cat: .done)
    case "stopped":     return StatusMeta(glyph: "◼", label: "STOPPED", priority: 6, cat: .stopped)
    default:            return StatusMeta(glyph: "·", label: status.uppercased(), priority: 99, cat: .other)
    }
}

// Whether a category's row in the speech bubble / pop-out behaves like a
// notification (appears on the transition into it, then retires itself) rather
// than like a standing entry that holds until the agent moves on. A finished
// agent is an event; a blocked or still-running one is a state.
func isTransientRow(_ cat: Category) -> Bool { cat == .asked || cat == .done }

// What the gate named in `waitingFor` means in plain words. The CLI writes
// the dialog's own name there; anything unrecognized passes through as-is.
func blockerReason(_ waitingFor: String?) -> String {
    switch waitingFor {
    case "permission prompt": return "needs permission"
    case "input needed":      return "needs an answer"
    case "dialog open":       return "dialog open"
    case "worker request":    return "worker request"
    case "sandbox request":   return "sandbox request"
    case let other?:          return other
    case nil:                 return "needs you"
    }
}

// When to raise a system notification, independent of which visual surfaces are
// on. "auto" is the default and the only one that reasons about them: it fills
// the gap rather than duplicating what you can already see. "always" suits
// anyone who treats Notification Centre as the real inbox and wants the log
// regardless; "never" silences them outright.
let notifyModes = ["auto", "always", "never"]
// The "auto" title names the two surfaces it defers to, matching the wording of
// their own checkboxes, so the rule needs no explanatory label beside it.
let notifyModeLabels = [
    "auto": "Only if panel and bubble are hidden",
    "always": "Always",
    "never": "Never",
]

// Statuses that trigger notifications when transitioned INTO. The buckets are
// disjoint: every status belongs to exactly one.
let notifyBlocked: Set<String> = ["waiting", "needs_input", "blocked"]
let notifyAsked: Set<String> = ["asked"]
let notifyDone: Set<String> = ["completed", "done", "idle"]
let notifyError: Set<String> = ["error", "failed"]

// MARK: - Session model

struct Session {
    let raw: [String: Any]
    let fileID: String
    let mtime: TimeInterval

    // Richer state from `claude agents --json`, overlaid after reading the
    // session file: "working" / "done" / "blocked" / "failed". Useful for
    // telling a finished turn that ended in a question ("blocked") from one
    // that didn't ("done") — but see `status`: it says nothing about whether
    // the agent is actually stuck.
    var state: String?
    // The CLI's own `waitingFor`, overlaid alongside `state`. Only a fallback:
    // see `waitingFor`.
    var cliWaitingFor: String?

    var pid: Int32 { (raw["pid"] as? NSNumber)?.int32Value ?? 0 }
    var fileStatus: String { ((raw["status"] as? String) ?? "unknown").lowercased() }

    // Present only while the session sits at a gate it cannot pass on its
    // own: "permission prompt", "input needed", "dialog open", "worker
    // request", "sandbox request". This is the real "stuck" signal.
    //
    // The session file is preferred because it is first-hand and updated by the
    // session itself, but both it and the CLI report the gate only while one is
    // actually open, so a missing value in either is silence rather than a "no".
    // Taking the first that speaks means a gate has to be missing from both to
    // be missed here.
    var waitingFor: String? { (raw["waitingFor"] as? String) ?? cliWaitingFor }

    var status: String {
        // A live gate is the one unambiguous "needs you NOW", and the session
        // file reports it first-hand — so it outranks the CLI's `state`,
        // which for a parked session also just says "blocked".
        if fileStatus == "waiting" || waitingFor != nil { return "waiting" }
        guard let st = state else { return fileStatus }
        switch st {
        case "working":
            // After a session is closed and reopened, the CLI resets its
            // state to "working" even when nothing runs; the file's
            // busy/idle is the reliable "is it actually computing" signal.
            return fileStatus == "busy" ? "busy" : fileStatus
        case "done": return "done"
        case "blocked":
            // Inferred from the closing message, not from a gate (we already
            // ruled one out above): the turn is over and the agent asked for
            // something. "Reply when you can", not "come here now".
            return "asked"
        case "failed": return "error"
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

// sessionId -> (state, waitingFor) from the claude CLI. state is "working" /
// "done" / "blocked" / "failed". Note the CLI derives "blocked" from the agent's
// closing prose, so it covers both a real gate and a mere trailing question;
// `waitingFor` is what separates the two.
//
// Both the session file and this CLI row can carry `waitingFor`, and neither
// reports it reliably on its own: the field is only present while a session
// actually sits at a gate, so an empty result never distinguishes "no gate"
// from "this source didn't say". Collecting it here as well lets `Session`
// prefer the file and fall back to the CLI, which is strictly better than
// trusting either alone.
func fetchAgentStates() -> [String: (state: String, waitingFor: String?)] {
    guard let claude = claudePath else { return [:] }
    let out = runCapture([claude, "agents", "--json"])
    guard let data = out.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [:] }
    var map: [String: (state: String, waitingFor: String?)] = [:]
    for row in rows {
        if let sid = row["sessionId"] as? String, let state = row["state"] as? String {
            map[sid] = (state, row["waitingFor"] as? String)
        }
    }
    return map
}

var seenWaitingFor: Set<String> = []

// Compress the session file's `waitingFor` gate name to a one-word tag, for UI
// too tight for `blockerReason`'s prose (the pet's bubble rows, which turn the
// tag into an icon). Matching is on substrings so the known gate names
// ("permission prompt", "input needed", "dialog open", "worker request",
// "sandbox request") and any future rewording both land on the right tag.
func shortWaitingFor(_ raw: String?) -> String? {
    guard let lower = raw?.lowercased(), !lower.isEmpty else { return nil }
    if lower.contains("permission") { return "permission" }
    if lower.contains("sandbox") { return "sandbox" }
    if lower.contains("worker") { return "worker" }
    if lower.contains("input") || lower.contains("question") { return "question" }
    if lower.contains("dialog") { return "dialog" }
    return lower.split(separator: " ").first.map(String.init)
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
            if let sid = sessions[i].sessionId, let info = states[sid] {
                sessions[i].state = info.state
                sessions[i].cliWaitingFor = info.waitingFor
            }
            // Surface gate names we haven't mapped yet, so gaps in
            // shortWaitingFor show up in the log instead of as a bare bell.
            if let wf = sessions[i].waitingFor, !seenWaitingFor.contains(wf) {
                seenWaitingFor.insert(wf)
                NSLog("waitingFor observed: '%@' -> tag '%@'", wf, shortWaitingFor(wf) ?? "-")
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
// an agent is blocked, errored, or finished by asking you something — grouped
// under separate headings, because the first two want you now and the third
// only wants a reply. Unlike a notification it cannot be reflex-dismissed: it
// stays until the agent is handled (or snoozed with its dismiss button), and it
// never steals keyboard focus from what you're typing. Clicking a row attaches
// to that agent.

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

        // Three groups, in the order they deserve your attention: what is stuck,
        // what just landed, what is still going. The dismiss button rides on
        // whichever heading comes first.
        let cat: (Session) -> Category = { statusMeta($0.status).cat }
        let stuck = sessions.filter { cat($0) == .blocked || cat($0) == .error }
        let finished = sessions.filter { isTransientRow(cat($0)) }
        let running = sessions.filter { cat($0) == .busy }

        var first = true
        for (title, group) in [("Blocked — needs you now", stuck),
                               ("Just finished", finished),
                               ("Still running", running)] where !group.isEmpty {
            addHeader(title, withDismiss: first)
            first = false
            for s in group { addRow(s) }
        }
    }

    private func addHeader(_ text: String, withDismiss: Bool) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        let title = NSTextField(labelWithString: text)
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())  // spacer
        if withDismiss {
            let dismiss = NSButton(title: "✕", target: self, action: #selector(dismissClicked(_:)))
            dismiss.isBordered = false
            dismiss.font = NSFont.systemFont(ofSize: 11)
            header.addArrangedSubview(dismiss)
        }
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }

    private func addRow(_ s: Session) {
        guard let i = sessions.firstIndex(where: { $0.fileID == s.fileID }) else { return }
        let meta = statusMeta(s.status)
        var name = displayName(s)
        if name.count > 40 { name = String(name.prefix(38)) + "…" }
        let leaf = (s.cwd as NSString).lastPathComponent
        // Spelling out the gate is the whole point for a blocked agent: it
        // tells you whether to approve something or to answer something.
        let why = meta.cat == .blocked ? " — \(blockerReason(s.waitingFor))" : ""
        // How long it has been stuck (or running) is worth knowing. How long a
        // self-retiring row has left on screen is not, so those show no age —
        // a number ticking toward its own disappearance says nothing.
        let where_ = isTransientRow(meta.cat) ? leaf : "\(leaf), \(formatAgo(s))"
        let row = NSButton(
            title: "\(meta.glyph)  \(name)   (\(where_))\(why)",
            target: self, action: #selector(rowClicked(_:)))
        row.isBordered = false
        row.alignment = .left
        row.font = NSFont.systemFont(ofSize: 13)
        row.tag = i
        stack.addArrangedSubview(row)
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
    if let n = counts[.blocked], n > 0 { parts.append("🔔\(n)") }
    if let n = counts[.error], n > 0 { parts.append("⛔\(n)") }
    if let n = counts[.asked], n > 0 { parts.append("💬\(n)") }
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
    var bubbleEnabled = true
    // Whether a still-running agent earns a row on the attention surfaces. It
    // is the one category that wants nothing from you, so listing it is a
    // progress readout rather than a call to act, and the icon strip beside the
    // pet already carries that count. Off leaves the surfaces to the agents
    // that are actually waiting on you.
    var busyRowsEnabled = true
    // "auto" (only what no visible surface is already showing), "always", or
    // "never". Independent of the two surfaces on purpose: whether you want a
    // system notification is a question about how you want to be interrupted,
    // not a consequence of which panel happens to be switched on.
    var notifyMode = "auto"
    var snoozed: Set<String> = []
    // fileID -> when its self-retiring row expires. See needySessions.
    var transientRows: [String: TimeInterval] = [:]
    var transientTimer: Timer?
    let attentionPanel = AttentionPanel()
    var settingsWindow: NSWindow?
    var recorderButton: HotKeyRecorderButton?
    var popoutCheckbox: NSButton?
    var petCheckbox: NSButton?
    var bubbleCheckbox: NSButton?
    var busyCheckbox: NSButton?
    var notifyPopup: NSPopUpButton?
    var loginCheckbox: NSButton?
    var petSizeSlider: NSSlider?
    var pet: PetController?
    var petEnabled = true
    var petSpeciesID = "octopus"
    var petPopup: NSPopUpButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        menu.delegate = self
        statusItem.menu = menu
        installHotKeyHandler()
        attentionPanel.onAttach = { attachSession($0) }
        attentionPanel.onDismiss = { [weak self] in self?.snoozeCurrent() }

        let startupConfig = readConfig()
        petSpeciesID = (startupConfig["petSpecies"] as? String) ?? "octopus"
        var savedOrigin: NSPoint?
        if let x = startupConfig["petX"] as? Double, let y = startupConfig["petY"] as? Double {
            savedOrigin = NSPoint(x: x, y: y)
        }
        let petCtl = PetController(initialXP: (startupConfig["petXP"] as? Int) ?? 0,
                                   initialSpecies: petSpeciesID,
                                   savedOrigin: savedOrigin)
        petCtl.onAttach = { [weak self] fileID in
            guard let self = self,
                  let s = self.lastSessions.first(where: { $0.fileID == fileID }) else { return }
            attachSession(s)
        }
        petCtl.onXPChanged = { xp in
            writeConfig(["petXP": xp])
        }
        petCtl.onMoved = { [weak self] origin in
            writeConfig(["petX": Double(origin.x), "petY": Double(origin.y)])
            self?.lastConfigMtime = configModTime()  // our own write, already applied
        }
        pet = petCtl
        // The pet lands somewhere other than the saved spot when that spot was
        // off screen (or when there was nothing saved). Record where it
        // actually went so the file never keeps a position you can't see.
        if petCtl.origin != savedOrigin {
            writeConfig(["petX": Double(petCtl.origin.x), "petY": Double(petCtl.origin.y)])
        }
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
        bubbleEnabled = (config["bubble"] as? Bool) ?? true
        busyRowsEnabled = (config["busyRows"] as? Bool) ?? true
        let mode = (config["notifications"] as? String) ?? "auto"
        notifyMode = notifyModes.contains(mode) ? mode : "auto"
        petEnabled = (config["pet"] as? Bool) ?? true
        pet?.setEnabled(petEnabled)
        pet?.setScale((config["petScale"] as? Double) ?? 1.0)
        petSpeciesID = (config["petSpecies"] as? String) ?? "octopus"
        pet?.setSpecies(petSpeciesID)
        // Position follows the file too, so editing petX/petY is a way back
        // when the pet is parked somewhere unreachable. Our own drag writes
        // land here as a no-op: they already match the window.
        if let x = config["petX"] as? Double, let y = config["petY"] as? Double {
            pet?.setOrigin(NSPoint(x: x, y: y))
        }
        applyHotKey((config["hotkey"] as? String) ?? defaultHotKeySpec)
    }

    // Which sessions the speech bubble / pop-out shows, and for how long. Two
    // different lifetimes, matching the two different kinds of attention:
    //
    //   blocked, errored  a standing alarm. The row holds until the agent is
    //                     actually unblocked (or snoozed with the dismiss
    //                     button), because it will not move without you.
    //   busy              a standing entry too — it holds while the agent runs
    //                     — but sorted to the very end, under everything that
    //                     wants something from you. Nothing to do about it yet;
    //                     it is there so you can see the fleet is alive.
    //   asked, done       an event. The row appears the moment the agent
    //                     finishes and retires itself after transientRowTTL,
    //                     exactly like a notification — there is nothing to
    //                     hold open, and a growing list of finished agents is
    //                     the noise this whole distinction exists to remove.
    //
    // The icon strip beside the pet is deliberately unaffected: it counts every
    // session in every state, standing tally rather than attention queue.
    // A snooze is keyed on session+status, so it clears itself as soon as the
    // status changes.
    func needySessions(_ sessions: [Session]) -> [Session] {
        pruneTransientRows()
        let needy = sessions.filter { s in
            let cat = statusMeta(s.status).cat
            if isTransientRow(cat) { return transientRows[s.fileID] != nil }
            if cat == .busy { return busyRowsEnabled }
            return cat == .blocked || cat == .error
        }
        let live = needy.filter { !snoozed.contains("\($0.fileID):\($0.status)") }
        snoozed.formIntersection(Set(needy.map { "\($0.fileID):\($0.status)" }))
        // `sessions` is already sorted attention-first; lifting the busy ones
        // out and re-appending them keeps that order within each group while
        // pinning "still running" to the bottom of the list.
        return live.filter { statusMeta($0.status).cat != .busy }
            + live.filter { statusMeta($0.status).cat == .busy }
    }

    // Give a session a row that expires on its own, and make sure something
    // wakes up to retire it. Called on the same transitions that notify.
    func showTransientRow(for fileID: String) {
        transientRows[fileID] = Date().timeIntervalSince1970 + transientRowTTL
        scheduleTransientSweep()
    }

    func pruneTransientRows() {
        let now = Date().timeIntervalSince1970
        transientRows = transientRows.filter { $0.value > now }
    }

    // The 3s poll is too coarse to retire a 5s row on time, so a one-shot
    // timer fires the moment the earliest row expires and redraws from the last
    // poll's sessions.
    func scheduleTransientSweep() {
        transientTimer?.invalidate()
        transientTimer = nil
        guard let earliest = transientRows.values.min() else { return }
        let delay = max(0.1, earliest - Date().timeIntervalSince1970)
        transientTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
            [weak self] _ in
            guard let self = self else { return }
            self.transientTimer = nil
            self.pruneTransientRows()
            self.updateAttentionPanel(self.lastSessions)
            self.updatePet(self.lastSessions)
            self.scheduleTransientSweep()
        }
    }

    // The panel and the pet's speech bubble are two independent surfaces for
    // the same queue, each with its own switch. They used to be mutually
    // exclusive (the panel hid itself whenever the pet was enabled), which
    // meant turning the pet on silently took the panel away with no setting
    // that would bring it back. They are orthogonal now: the panel is a
    // precise list under the menubar, the bubble is an ambient glance next to
    // the pet, and wanting one is not a statement about wanting the other.
    func updateAttentionPanel(_ sessions: [Session]) {
        attentionPanel.update(popoutEnabled ? needySessions(sessions) : [])
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
            case .blocked: counts.blocked += 1
            case .error: counts.error += 1
            case .asked: counts.asked += 1
            case .busy: counts.busy += 1
            case .done: counts.done += 1
            default: break
            }
        }
        var rows: [PetBubbleRow] = bubbleEnabled ? needySessions(sessions).map { s in
            let cat = statusMeta(s.status).cat
            let kind: PetAgentKind
            switch cat {
            case .error: kind = .error
            case .asked: kind = .asked
            case .done: kind = .done
            case .busy: kind = .busy
            default: kind = .blocked
            }
            // A self-retiring row shows no age: a number counting up to the
            // moment the row vanishes tells you nothing. The age has its own
            // right-aligned column here, so leaving it out just blanks that
            // column and the name keeps its full width either way.
            return PetBubbleRow(id: s.fileID, kind: kind,
                                text: String(displayName(s).prefix(26)),
                                ago: isTransientRow(cat) ? "" : formatAgo(s),
                                why: shortWaitingFor(s.waitingFor))
        } : []
        if rows.count > maxBubbleRows {
            let folded = rows.count - (maxBubbleRows - 1)
            rows = Array(rows.prefix(maxBubbleRows - 1))
            rows.append(PetBubbleRow(id: "", kind: .more, text: "+\(folded) more",
                                     ago: "", why: nil))
        }
        pet?.update(counts: counts, rows: rows)
    }

    // Whether a state change should also raise a system notification. Only
    // "auto" cares whether a surface is already showing it; note the bubble
    // counts only when the pet itself is enabled, since a disabled pet draws
    // no bubble however the bubble switch is set.
    func shouldNotify() -> Bool {
        switch notifyMode {
        case "always": return true
        case "never":  return false
        default:       return !(popoutEnabled || (petEnabled && bubbleEnabled))
        }
    }

    func checkNotifications(_ sessions: [Session]) {
        var current: [String: String] = [:]
        for s in sessions {
            let status = s.status
            current[s.fileID] = status
            guard let prev = prevStates[s.fileID] else { continue }
            let name = displayName(s)
            // Under "auto", notifications are the fallback for what you cannot
            // already see, nothing more. Every category now gets a row on some
            // surface (blocked and errored hold one, asked and done get a
            // self-retiring one), so whenever a surface is up, notifying as well
            // is the same event told twice and the second telling is the
            // intrusive one. With both surfaces off nothing else would mark the
            // transition, so notifications carry the whole load. "always" and
            // "never" opt out of that reasoning in either direction.
            let wantNotify = shouldNotify()
            if notifyBlocked.contains(status) && !notifyBlocked.contains(prev) {
                if wantNotify {
                    notify(title: "Blocked",
                           message: "\(name) \(blockerReason(s.waitingFor))",
                           attachJobId: s.shortJobId)
                }
            } else if notifyAsked.contains(status) && !notifyAsked.contains(prev) {
                if wantNotify {
                    notify(title: "Waiting for your reply",
                           message: "\(name) finished and asked you something",
                           attachJobId: s.shortJobId)
                }
                showTransientRow(for: s.fileID)
                pet?.gainXP()  // the turn still completed
            } else if notifyDone.contains(status) && !notifyDone.contains(prev) {
                if wantNotify {
                    notify(title: "Completed", message: "\(name) finished",
                           attachJobId: s.shortJobId)
                }
                showTransientRow(for: s.fileID)
                pet?.gainXP()  // the pet feeds on completed tasks
            } else if notifyError.contains(status) && !notifyError.contains(prev) {
                if wantNotify {
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
            let why = meta.cat == .blocked ? " — \(blockerReason(s.waitingFor))" : ""
            let item = NSMenuItem(
                title: "\(meta.glyph)  \(name)   (\(leaf), \(ago))\(why)",
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
        let petMenuItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        let petSubmenu = NSMenu()
        refreshPetSpecies()  // pick up pets installed via `npx petdex install`
        let petLabels = petPickerLabels(allPetSpecies)
        for (i, s) in allPetSpecies.enumerated() {
            let it = NSMenuItem(title: petLabels[i],
                                action: #selector(petSpeciesMenuAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.id
            it.state = (s.id == petSpeciesID) ? .on : .off
            petSubmenu.addItem(it)
        }
        petMenuItem.submenu = petSubmenu
        menu.addItem(petMenuItem)

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
        bubbleCheckbox?.state = bubbleEnabled ? .on : .off
        busyCheckbox?.state = busyRowsEnabled ? .on : .off
        if let idx = notifyModes.firstIndex(of: notifyMode) {
            notifyPopup?.selectItem(at: idx)
        }
        refreshPetSpecies()  // pick up pets installed via `npx petdex install`
        if let popup = petPopup {
            popup.removeAllItems()
            fillPetPopup(popup)
        }
        if let idx = allPetSpecies.firstIndex(where: { $0.id == petSpeciesID }) {
            petPopup?.selectItem(at: idx)
        }
        loginCheckbox?.state = loginItemEnabled() ? .on : .off
        petSizeSlider?.doubleValue = (readConfig()["petScale"] as? Double) ?? 1.0
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

        let checkbox = NSButton(checkboxWithTitle: "Show attention pop-out panel under the menubar",
                                target: self, action: #selector(popoutToggled(_:)))
        let petBox = NSButton(checkboxWithTitle: "Show desktop pet",
                              target: self, action: #selector(petToggled(_:)))
        let bubbleBox = NSButton(checkboxWithTitle: "Show the pet's speech bubble",
                                 target: self, action: #selector(bubbleToggled(_:)))
        let busyBox = NSButton(checkboxWithTitle: "Also list busy agents",
                               target: self, action: #selector(busyRowsToggled(_:)))
        let loginBox = NSButton(checkboxWithTitle: "Start at login",
                                target: self, action: #selector(loginToggled(_:)))

        let petLabel = NSTextField(labelWithString: "Pet:")
        let petPop = NSPopUpButton(frame: .zero, pullsDown: false)
        petPop.target = self
        petPop.action = #selector(petSpeciesChanged(_:))
        fillPetPopup(petPop)
        let petRow = NSStackView(views: [petLabel, petPop])
        petRow.orientation = .horizontal
        petRow.spacing = 8

        let sizeLabel = NSTextField(labelWithString: "Pet size:")
        let sizeSlider = NSSlider(value: 1.0, minValue: 0.5, maxValue: 2.0,
                                  target: self, action: #selector(petSizeChanged(_:)))
        sizeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let sizeRow = NSStackView(views: [sizeLabel, sizeSlider])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8

        let notifyLabel = NSTextField(labelWithString: "Notifications:")
        let notifyPop = NSPopUpButton(frame: .zero, pullsDown: false)
        notifyPop.target = self
        notifyPop.action = #selector(notifyModeChanged(_:))
        for (i, m) in notifyModes.enumerated() {
            notifyPop.addItem(withTitle: notifyModeLabels[m] ?? m)
            notifyPop.item(at: i)?.representedObject = m
        }
        let notifyRow = NSStackView(views: [notifyLabel, notifyPop])
        notifyRow.orientation = .horizontal
        notifyRow.spacing = 8

        let hotkeyLabel = NSTextField(labelWithString: "Global hotkey:")
        let hotkeyRow = NSStackView(views: [hotkeyLabel, recorder])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8

        let hint = NSTextField(
            labelWithString: "Click the hotkey, then press a new combination. Esc cancels.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        // `hint` explains the recorder, so it is grouped tight under it rather
        // than orphaned at the bottom of the window.
        let hotkeyBox = NSStackView(views: [hotkeyRow, hint])
        hotkeyBox.orientation = .vertical
        hotkeyBox.alignment = .leading
        hotkeyBox.spacing = 4

        // The four surface toggles are one decision ("what shows up, where"), so
        // they sit tighter together than the unrelated rows around them.
        let surfacesBox = NSStackView(views: [checkbox, petBox, bubbleBox, busyBox])
        surfacesBox.orientation = .vertical
        surfacesBox.alignment = .leading
        surfacesBox.spacing = 8

        let stack = NSStackView(views: [hotkeyBox, surfacesBox, petRow, sizeRow, notifyRow, loginBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Sized by hand, not from `stack.fittingSize`: the stack reports a width
        // narrower than its own widest child plus the insets, so fitting it
        // squeezes the notification popup and runs the longest checkbox label
        // into the right edge. Keep 430 wide for a real right margin, and tall
        // enough for the surface toggles, the pet picker and size slider, the
        // notification popup and the login row all at their natural heights.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 325),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "sticky-agent-monitor"
        win.isReleasedWhenClosed = false
        win.contentView = stack
        win.center()

        settingsWindow = win
        recorderButton = recorder
        popoutCheckbox = checkbox
        petCheckbox = petBox
        bubbleCheckbox = bubbleBox
        busyCheckbox = busyBox
        petPopup = petPop
        notifyPopup = notifyPop
        loginCheckbox = loginBox
        petSizeSlider = sizeSlider
    }

    @objc func petSizeChanged(_ sender: NSSlider) {
        let scale = sender.doubleValue
        pet?.setScale(scale)
        writeConfig(["petScale": scale])
        lastConfigMtime = configModTime()  // our own write, already applied
    }

    @objc func notifyModeChanged(_ sender: NSPopUpButton) {
        guard let mode = sender.selectedItem?.representedObject as? String else { return }
        notifyMode = mode
        writeConfig(["notifications": mode])
        lastConfigMtime = configModTime()  // our own write, already applied
    }

    @objc func loginToggled(_ sender: NSButton) {
        setLoginItem(sender.state == .on)
    }

    @objc func bubbleToggled(_ sender: NSButton) {
        bubbleEnabled = sender.state == .on
        writeConfig(["bubble": bubbleEnabled])
        lastConfigMtime = configModTime()  // our own write, already applied
        updatePet(lastSessions)
    }

    // Busy rows appear on both surfaces, so redraw both rather than just the pet.
    @objc func busyRowsToggled(_ sender: NSButton) {
        busyRowsEnabled = sender.state == .on
        writeConfig(["busyRows": busyRowsEnabled])
        lastConfigMtime = configModTime()  // our own write, already applied
        updatePet(lastSessions)
        updateAttentionPanel(lastSessions)
    }

    @objc func petToggled(_ sender: NSButton) {
        petEnabled = sender.state == .on
        writeConfig(["pet": petEnabled])
        lastConfigMtime = configModTime()  // our own write, already applied
        pet?.setEnabled(petEnabled)
        if petEnabled { updatePet(lastSessions) }
    }

    @objc func petSpeciesChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        selectPetSpecies(id)
    }

    // One item per species, in `allPetSpecies` order so `selectItem(at:)` still
    // lines up. Items go through the menu rather than `addItem(withTitle:)`,
    // which removes any existing item with the same title and would drop a pet.
    private func fillPetPopup(_ popup: NSPopUpButton) {
        let labels = petPickerLabels(allPetSpecies)
        for (i, s) in allPetSpecies.enumerated() {
            let it = NSMenuItem(title: labels[i], action: nil, keyEquivalent: "")
            it.representedObject = s.id
            popup.menu?.addItem(it)
        }
    }

    // Switch the pet species from any entry point (settings popup or menu),
    // persist it, and keep the pet visible so the change is immediately seen.
    func selectPetSpecies(_ id: String) {
        petSpeciesID = id
        writeConfig(["petSpecies": id])
        lastConfigMtime = configModTime()  // our own write, already applied
        pet?.setSpecies(id)
        if !petEnabled {
            petEnabled = true
            writeConfig(["pet": true])
            lastConfigMtime = configModTime()
            petCheckbox?.state = .on
            pet?.setEnabled(true)
        }
        updatePet(lastSessions)
    }

    @objc func petSpeciesMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectPetSpecies(id)
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

// Print what the monitor currently thinks of every session, one line each.
// Mainly here to check the blocked-vs-asked call without squinting at the
// menubar: it shows the raw inputs next to the verdict.
func cmdList() {
    let sessions = loadSessions()
    if sessions.isEmpty { print("no active sessions"); return }
    for s in sessions {
        let meta = statusMeta(s.status)
        var line = "\(meta.glyph) \(meta.label.padding(toLength: 8, withPad: " ", startingAt: 0))"
        line += "  \(displayName(s))"
        line += "  [file=\(s.fileStatus) state=\(s.state ?? "-")"
        if let w = s.waitingFor { line += " waitingFor=\(w)" }
        line += "]"
        print(line)
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

// MARK: - Login item

let launchAgentFile = home.appendingPathComponent(
    "Library/LaunchAgents/com.sticky-agent-monitor.plist")

func loginItemEnabled() -> Bool {
    FileManager.default.fileExists(atPath: launchAgentFile.path)
}

// A LaunchAgent starts the monitor at login. It runs the binary directly
// (launchd is the supervisor, so no self-daemonizing detour) and reuses the
// normal log file. Removing the plist disables it again.
func setLoginItem(_ on: Bool) {
    if on {
        let plist: [String: Any] = [
            "Label": "com.sticky-agent-monitor",
            "ProgramArguments": [executablePath, "--foreground"],
            "RunAtLoad": true,
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
        ]
        try? FileManager.default.createDirectory(
            at: launchAgentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: launchAgentFile)
        }
    } else {
        try? FileManager.default.removeItem(at: launchAgentFile)
    }
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
if args.contains("--list") { cmdList(); exit(0) }
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
}

// Single-instance guard: a login-item copy and a manually started copy must
// not run side by side (duplicate menubar items, pets, notifications).
if let existing = readPidFile(), existing != getpid(), procAlive(existing) {
    print("already running (pid \(existing)); exiting")
    exit(0)
}
try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
try? String(getpid()).write(to: pidFile, atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
