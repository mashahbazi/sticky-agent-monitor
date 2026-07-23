// Octoclaude: a pixel-art octopus desktop pet that embodies the agent fleet.
// A pixel icon strip beside it mirrors the menubar overview (bell/play/
// check/cross with counts), and when an agent needs you it raises a tentacle
// and shows a cartoony speech bubble with the waiting sessions, rendered in
// a tiny hand-drawn pixel font. Feeds on completed tasks (XP persisted in
// config.json) and evolves accessories with age.
//
// All art is composed in code from character pixel grids and rendered to
// nearest-neighbor SKTextures: no binary assets, no bundled fonts.

import AppKit
import SpriteKit

// MARK: - Palette

private let pixelPalette: [Character: NSColor] = [
    "P": NSColor(red: 0.65, green: 0.45, blue: 0.85, alpha: 1),  // body
    "D": NSColor(red: 0.45, green: 0.28, blue: 0.62, alpha: 1),  // shade
    "W": .white,
    "B": .black,
    "K": NSColor(red: 0.95, green: 0.60, blue: 0.75, alpha: 1),  // cheek
    "R": NSColor(red: 0.85, green: 0.25, blue: 0.30, alpha: 1),  // red / bandana
    "H": NSColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1),  // hat
    "G": NSColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1),  // hat band
    "A": NSColor(red: 0.98, green: 0.72, blue: 0.18, alpha: 1),  // amber
    "L": NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1),  // blue
    "E": NSColor(red: 0.20, green: 0.75, blue: 0.40, alpha: 1),  // green
    "T": NSColor(white: 1.0, alpha: 1.0),                        // bubble fill
    "O": NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1),  // cat orange
    "F": NSColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1),  // cream (fur/belly)
    "N": NSColor(red: 0.35, green: 0.22, blue: 0.15, alpha: 1),  // dark brown (nose)
    "M": NSColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 1),  // robot metal
    "C": NSColor(red: 0.30, green: 0.85, blue: 0.92, alpha: 1),  // robot screen cyan
    "S": NSColor(red: 0.40, green: 0.82, blue: 0.50, alpha: 1),  // slime green
    "Q": NSColor(red: 0.24, green: 0.58, blue: 0.34, alpha: 1),  // slime shade
]

// MARK: - Pixel font (3x5, uppercase)

private let pixelFont: [Character: [String]] = [
    "A": ["XXX", "X.X", "XXX", "X.X", "X.X"],
    "B": ["XX.", "X.X", "XX.", "X.X", "XX."],
    "C": [".XX", "X..", "X..", "X..", ".XX"],
    "D": ["XX.", "X.X", "X.X", "X.X", "XX."],
    "E": ["XXX", "X..", "XX.", "X..", "XXX"],
    "F": ["XXX", "X..", "XX.", "X..", "X.."],
    "G": [".XX", "X..", "X.X", "X.X", ".XX"],
    "H": ["X.X", "X.X", "XXX", "X.X", "X.X"],
    "I": ["XXX", ".X.", ".X.", ".X.", "XXX"],
    "J": ["..X", "..X", "..X", "X.X", ".X."],
    "K": ["X.X", "X.X", "XX.", "X.X", "X.X"],
    "L": ["X..", "X..", "X..", "X..", "XXX"],
    "M": ["X.X", "XXX", "XXX", "X.X", "X.X"],
    "N": ["XX.", "X.X", "X.X", "X.X", "X.X"],
    "O": [".X.", "X.X", "X.X", "X.X", ".X."],
    "P": ["XX.", "X.X", "XX.", "X..", "X.."],
    "Q": [".X.", "X.X", "X.X", ".X.", "..X"],
    "R": ["XX.", "X.X", "XX.", "X.X", "X.X"],
    "S": [".XX", "X..", ".X.", "..X", "XX."],
    "T": ["XXX", ".X.", ".X.", ".X.", ".X."],
    "U": ["X.X", "X.X", "X.X", "X.X", "XXX"],
    "V": ["X.X", "X.X", "X.X", "X.X", ".X."],
    "W": ["X.X", "X.X", "X.X", "XXX", "X.X"],
    "X": ["X.X", "X.X", ".X.", "X.X", "X.X"],
    "Y": ["X.X", "X.X", ".X.", ".X.", ".X."],
    "Z": ["XXX", "..X", ".X.", "X..", "XXX"],
    "0": ["XXX", "X.X", "X.X", "X.X", "XXX"],
    "1": [".X.", "XX.", ".X.", ".X.", "XXX"],
    "2": ["XX.", "..X", ".X.", "X..", "XXX"],
    "3": ["XXX", "..X", ".XX", "..X", "XXX"],
    "4": ["X.X", "X.X", "XXX", "..X", "..X"],
    "5": ["XXX", "X..", "XX.", "..X", "XX."],
    "6": [".XX", "X..", "XXX", "X.X", "XXX"],
    "7": ["XXX", "..X", ".X.", ".X.", ".X."],
    "8": ["XXX", "X.X", "XXX", "X.X", "XXX"],
    "9": ["XXX", "X.X", "XXX", "..X", "XX."],
    " ": ["...", "...", "...", "...", "..."],
    "-": ["...", "...", "XXX", "...", "..."],
    ".": ["...", "...", "...", "...", ".X."],
    ",": ["...", "...", "...", ".X.", "X.."],
    "(": ["..X", ".X.", ".X.", ".X.", "..X"],
    ")": ["X..", ".X.", ".X.", ".X.", "X.."],
    ":": ["...", ".X.", "...", ".X.", "..."],
    "!": [".X.", ".X.", ".X.", "...", ".X."],
    "?": ["XX.", "..X", ".X.", "...", ".X."],
    "/": ["..X", "..X", ".X.", "X..", "X.."],
    "'": [".X.", ".X.", "...", "...", "..."],
]

// 5x5 status icons matching the menubar glyphs (used by the overview strip;
// the bubble rows use emoji for their "why blocked" icons instead).
private let pixelIcons: [Character: (rows: [String], color: Character)] = [
    "b": (["..X..", ".XXX.", ".XXX.", "XXXXX", "..X.."], "A"),  // bell, waiting
    "p": (["XXXXX", ".X.X.", "..X..", ".X.X.", "XXXXX"], "L"),  // hourglass, busy
    "c": (["....X", "...XX", "X.XX.", "XXX..", ".X..."], "E"),  // check, done
    "x": (["X...X", ".X.X.", "..X..", ".X.X.", "X...X"], "R"),  // cross, error
]

// Stamp pixel-font text into a grid. Unknown characters render as a dot.
private func stampText(_ text: String, into grid: inout [[Character]],
                       row: Int, col: Int, color: Character) {
    var c = col
    for ch in text.uppercased() {
        let glyph = pixelFont[ch] ?? ["XXX", "X.X", "X.X", "X.X", "XXX"]
        for (dy, glyphRow) in glyph.enumerated() {
            for (dx, px) in glyphRow.enumerated() where px == "X" {
                let r = row + dy
                let cc = c + dx
                if r >= 0, r < grid.count, cc >= 0, cc < grid[r].count {
                    grid[r][cc] = color
                }
            }
        }
        c += 4
    }
}

private func stampIcon(_ icon: Character, into grid: inout [[Character]],
                       row: Int, col: Int) {
    guard let (rows, color) = pixelIcons[icon] else { return }
    for (dy, r) in rows.enumerated() {
        for (dx, px) in r.enumerated() where px == "X" {
            let rr = row + dy
            let cc = col + dx
            if rr >= 0, rr < grid.count, cc >= 0, cc < grid[rr].count {
                grid[rr][cc] = color
            }
        }
    }
}

// MARK: - Octopus frames

private enum EyeStyle { case open, closed, wide }
private enum TentacleStyle { case a, b }
private enum PetStage: Int { case hatchling = 0, juggler = 1, ringmaster = 2 }

private func headRows(eyes: EyeStyle) -> [String] {
    let eyeRow: String
    switch eyes {
    case .open:   eyeRow = ".PPPWBWPPPPPPWBWPPP."
    case .closed: eyeRow = ".PPPDDDPPPPPPDDDPPP."
    case .wide:   eyeRow = ".PPWWBWPPPPPPWBWWPP."
    }
    return [
        "......PPPPPPPP......",
        "....PPPPPPPPPPPP....",
        "...PPPPPPPPPPPPPP...",
        "..PPPPPPPPPPPPPPPP..",
        "..PPPPPPPPPPPPPPPP..",
        eyeRow,
        eyeRow,
        ".PPKPPPPPPPPPPPPKPP.",
        ".PPPPPPPPPDDPPPPPPP.",
        "..PPPPPPPPPPPPPPPP..",
    ]
}

private func tentacleRows(_ style: TentacleStyle) -> [String] {
    switch style {
    case .a:
        return [
            "..PPP.PPP..PPP.PPP..",
            "..PP...PP..PP...PP..",
            ".PPP...PP..PP...PPP.",
            ".PP....PP..PP....PP.",
            ".PP...PPP..PPP...PP.",
            "..P...PP....PP...P..",
        ]
    case .b:
        return [
            "..PPP.PPP..PPP.PPP..",
            "...PP..PP..PP..PP...",
            "...PP..PP..PP..PP...",
            "..PP...PP..PP...PP..",
            "..PP..PPP..PPP..PP..",
            "...P..PP....PP..P...",
        ]
    }
}

// Overlay one raised tentacle along the right edge, for waving.
private func addWaveArm(_ grid: inout [[Character]], phase: Int) {
    let column = 18 + (phase % 2)
    for row in 2...8 {
        let c = row <= 4 ? column : 18
        if c < grid[row].count { grid[row][c] = "P" }
    }
}

// Stage accessories drawn straight into the grid. The ringmaster's top hat
// needs headroom, so every frame carries 4 spare transparent rows on top.
private func addAccessory(_ grid: inout [[Character]], stage: PetStage) {
    switch stage {
    case .hatchling:
        break
    case .juggler:  // red bandana across the forehead
        for col in 3...16 where grid[6][col] == "P" { grid[6][col] = "R" }
        for col in 2...5 where grid[7][col] == "P" { grid[7][col] = "R" }
    case .ringmaster:  // top hat
        for col in 6...13 { grid[0][col] = "H" }
        for col in 6...13 { grid[1][col] = "H" }
        for col in 6...13 { grid[2][col] = "G" }
        for col in 4...15 { grid[3][col] = "H" }
    }
}

private func composeFrame(eyes: EyeStyle, tentacles: TentacleStyle,
                          stage: PetStage, waveArm: Bool, wavePhase: Int = 0) -> [[Character]] {
    let spare = ["....................", "....................",
                 "....................", "...................."]
    let rows = spare + headRows(eyes: eyes) + tentacleRows(tentacles)
    var grid = rows.map { Array($0) }
    if waveArm {
        var body = Array(grid[4...])
        addWaveArm(&body, phase: wavePhase)
        grid.replaceSubrange(4..., with: body)
    }
    addAccessory(&grid, stage: stage)
    return grid
}

// MARK: - Additional species

// Every species is drawn on the same 20x20 canvas the octopus uses: 4 spare
// transparent rows on top (headroom for hats/crowns) plus 16 rows of body.
// `petBody` right-pads each authored row to 20 columns so only the leading
// art has to be counted exactly, and prepends the spare rows. Grid row N of
// the body therefore lands at final grid row N + 4.
private let petSpareRows = 4

private func petBody(_ rows: [String]) -> [[Character]] {
    let spare = Array(repeating: String(repeating: ".", count: 20), count: petSpareRows)
    return (spare + rows).map { line -> [Character] in
        var a = Array(line)
        if a.count < 20 { a += Array(repeating: Character("."), count: 20 - a.count) }
        else if a.count > 20 { a = Array(a.prefix(20)) }
        return a
    }
}

// --- Cat (orange tabby, sitting) ---

private func catRows(eyes: EyeStyle) -> [String] {
    let eyeRow: String
    switch eyes {
    case .open:   eyeRow = "..OOOWBOOOOOOWBOOO.."
    case .closed: eyeRow = "..OOONNOOOOOONNOOO.."
    case .wide:   eyeRow = "..OOWBBOOOOOWBBOOO.."
    }
    return [
        ".OO..............OO.",
        "OOOO............OOOO",
        "..OOOOOOOOOOOOOOOO..",
        "..OOOOOOOOOOOOOOOO..",
        eyeRow,
        "..OOOOOOOOOOOOOOOO..",
        "..OOOOFFFFFFOOOOOO..",
        "..OOOOFFNNFFOOOOOO..",
        "..OOOOFFFFFFOOOOOO..",
        "...OOOOOOOOOOOOOO...",
        "...OOOOOOOOOOOOOO...",
        "..OOOOFFFFFFFFOOOO..",
        "..OOOFFFFFFFFFFOOO..",
        "..OOOFFFFFFFFFFOOO..",
        "..OFFO......OFFO....",
        "..OOOO......OOOO....",
    ]
}

private func catTail(_ g: inout [[Character]], variant: Int) {
    // A curled tail on the right; its tip rises on the second frame so the
    // cat gently swishes while idle.
    let tipRow = variant == 0 ? 16 : 14
    for r in tipRow...18 where r < g.count { g[r][18] = "O" }
    g[18][17] = "O"
}

private func catWave(_ g: inout [[Character]], phase: Int) {
    // Raise a front paw up beside the head and wave the pad.
    for r in 9...13 { g[r][17] = "O"; g[r][18] = "O" }
    let padRow = 7 + (phase % 2)
    g[padRow][17] = "F"; g[padRow][18] = "F"
}

private func catAccessory(_ g: inout [[Character]], stage: PetStage) {
    switch stage {
    case .hatchling:
        break
    case .juggler:  // red collar with a gold tag
        for c in 5...14 where g[13][c] == "F" || g[13][c] == "O" { g[13][c] = "R" }
        g[13][9] = "G"; g[13][10] = "G"
    case .ringmaster:  // little gold crown
        for c in 6...13 { g[3][c] = "G" }
        for c in [6, 9, 10, 13] { g[2][c] = "G" }
    }
}

private func composeCat(eyes: EyeStyle, variant: Int, stage: PetStage,
                        wave: Bool, wavePhase: Int) -> [[Character]] {
    var g = petBody(catRows(eyes: eyes))
    catTail(&g, variant: variant)
    if wave { catWave(&g, phase: wavePhase) }
    catAccessory(&g, stage: stage)
    return g
}

// --- Robot ---

private func robotRows(eyes: EyeStyle, variant: Int) -> [String] {
    let e: Character
    switch eyes {
    case .open:   e = "B"
    case .closed: e = "C"   // eyes off: blank screen
    case .wide:   e = "R"   // red alert
    }
    let es = String(e)
    let light = variant == 0 ? "C" : "M"   // antenna light blinks while idle
    return [
        "........\(light)...........",
        "........M...........",
        "...MMMMMMMMMMMM.....",
        "..MMMMMMMMMMMMMM....",
        "..MCCCCCCCCCCCCM....",
        "..MCC\(es)\(es)CCCC\(es)\(es)CCM....",
        "..MCCCCMMMMCCCCM....",
        "..MMMMMMMMMMMMMM....",
        "...MMMMMMMMMMMM.....",
        ".M.MMMMMMMMMMMM.M...",
        ".M.MMMMMMMMMMMM.M...",
        ".M.MMMMMMMMMMMM.M...",
        "...MMMMMMMMMMMM.....",
        "...MMMM....MMMM.....",
        "...MMMM....MMMM.....",
        "..MMMMM....MMMMM....",
    ]
}

private func robotWave(_ g: inout [[Character]], phase: Int) {
    // Swing the right arm up beside the head.
    let col = 16 + (phase % 2)
    for r in 5...9 where col < 20 { g[r][col] = "M" }
}

private func robotAccessory(_ g: inout [[Character]], stage: PetStage) {
    switch stage {
    case .hatchling:
        break
    case .juggler:  // gold chest badge
        for c in 8...10 { g[14][c] = "G" }
        g[13][9] = "G"
    case .ringmaster:  // gold antenna crown
        g[4][8] = "G"
        for c in 6...11 { g[3][c] = "G" }
        for c in [6, 9, 11] { g[2][c] = "G" }
    }
}

private func composeRobot(eyes: EyeStyle, variant: Int, stage: PetStage,
                          wave: Bool, wavePhase: Int) -> [[Character]] {
    var g = petBody(robotRows(eyes: eyes, variant: variant))
    if wave { robotWave(&g, phase: wavePhase) }
    robotAccessory(&g, stage: stage)
    return g
}

// --- Slime ---

private func slimeRows(eyes: EyeStyle) -> [String] {
    let e: String
    switch eyes {
    case .open:   e = "BW"
    case .closed: e = "QQ"
    case .wide:   e = "WB"
    }
    return [
        "........SSSS........",
        "......SSSSSSSS......",
        ".....SSSSSSSSSS.....",
        "....SSSSSSSSSSSS....",
        "...SSS\(e)SSSS\(e)SSS...",
        "...SSSSSSSSSSSSSS...",
        "..SSSSSSSSSSSSSSSS..",
        "..SSSSSSSSSSSSSSSS..",
        ".SSSSSSSSSSSSSSSSSS.",
        ".SSSSSSSSSSSSSSSSSS.",
        "SSSSSSSSSSSSSSSSSSSS",
        "SSSSSSSSSSSSSSSSSSSS",
        "SSSSSSSSSSSSSSSSSSSS",
        "QQQQQQQQQQQQQQQQQQQQ",
        ".QQQQQQQQQQQQQQQQQQ.",
        "..QQQQQQQQQQQQQQQQ..",
    ]
}

private func slimeShine(_ g: inout [[Character]], variant: Int) {
    // A drifting highlight gives the blob a wet wobble between frames.
    let col = variant == 0 ? 6 : 8
    g[6][col] = "W"; g[7][col] = "W"
}

private func slimeWave(_ g: inout [[Character]], phase: Int) {
    // No arms: raise little side nubs as if reaching up for attention.
    let lift = phase % 2
    for r in (5 - lift)...7 where r >= 0 { g[r][2] = "S"; g[r][17] = "S" }
}

private func slimeAccessory(_ g: inout [[Character]], stage: PetStage) {
    switch stage {
    case .hatchling:
        break
    case .juggler:  // a leafy sprout
        g[3][10] = "E"; g[2][10] = "E"; g[3][11] = "E"
    case .ringmaster:  // gold crown
        for c in 6...13 { g[3][c] = "G" }
        for c in [7, 10, 13] { g[2][c] = "G" }
    }
}

private func composeSlime(eyes: EyeStyle, variant: Int, stage: PetStage,
                          wave: Bool, wavePhase: Int) -> [[Character]] {
    var g = petBody(slimeRows(eyes: eyes))
    slimeShine(&g, variant: variant)
    if wave { slimeWave(&g, phase: wavePhase) }
    slimeAccessory(&g, stage: stage)
    return g
}

// MARK: - Species registry

// A species supplies only its body art; the palette, pixel renderer, speech
// bubble, overview strip and animation timing are shared by all of them.
struct PetSpecies {
    let id: String
    let displayName: String
    fileprivate let compose: (_ eyes: EyeStyle, _ variant: Int, _ stage: PetStage,
                              _ wave: Bool, _ wavePhase: Int) -> [[Character]]
}

let allPetSpecies: [PetSpecies] = [
    PetSpecies(id: "octopus", displayName: "Octopus") { eyes, variant, stage, wave, phase in
        composeFrame(eyes: eyes, tentacles: variant == 0 ? .a : .b,
                     stage: stage, waveArm: wave, wavePhase: phase)
    },
    PetSpecies(id: "cat", displayName: "Cat", compose: composeCat),
    PetSpecies(id: "robot", displayName: "Robot", compose: composeRobot),
    PetSpecies(id: "slime", displayName: "Slime", compose: composeSlime),
]

func petSpecies(withID id: String) -> PetSpecies {
    allPetSpecies.first { $0.id == id } ?? allPetSpecies[0]
}

private func texture(from grid: [[Character]], scale: Int) -> SKTexture {
    let h = grid.count
    let w = grid.map { $0.count }.max() ?? 0
    guard w > 0, h > 0, let ctx = CGContext(
        data: nil, width: w * scale, height: h * scale,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return SKTexture() }

    for (rowIdx, row) in grid.enumerated() {
        for (colIdx, ch) in row.enumerated() {
            guard let color = pixelPalette[ch] else { continue }
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            ctx.setFillColor(red: rgb.redComponent, green: rgb.greenComponent,
                             blue: rgb.blueComponent, alpha: rgb.alphaComponent)
            // CGContext origin is bottom-left; grids are authored top-down.
            let y = (h - 1 - rowIdx) * scale
            ctx.fill(CGRect(x: colIdx * scale, y: y, width: scale, height: scale))
        }
    }
    guard let img = ctx.makeImage() else { return SKTexture() }
    let tex = SKTexture(cgImage: img)
    tex.filteringMode = .nearest
    return tex
}

// MARK: - Speech bubble

// White bubble, black 1px border, notched pixel corners, tail bottom-right
// pointing at the octopus. One line per waiting session; the content is
// drawn as real monospaced labels (emoji reason icon + name + age) over the
// sprite, so the grid only carries the frame.
private func bubbleGrid(rowCount: Int, textW: Int = 108) -> [[Character]] {
    let lineH = 8   // row height in grid px
    let padding = 4
    // Default textW fits emoji + ~28 chars of Menlo 12 at 2.5x display.
    let w = padding * 2 + textW
    // Equal padding above and below the rows keeps content centered.
    let h = padding * 2 + rowCount * lineH - 3
    var grid = Array(repeating: Array(repeating: Character("."), count: w), count: h)

    for r in 0..<h {
        for c in 0..<w {
            let corner = (r < 2 && c < 2) || (r < 2 && c >= w - 2)
                || (r >= h - 2 && c < 2) || (r >= h - 2 && c >= w - 2)
            if corner { continue }
            let border = r == 0 || r == h - 1 || c == 0 || c == w - 1
                || (r == 1 && (c == 1 || c == w - 2))
                || (r == h - 2 && (c == 1 || c == w - 2))
            grid[r][c] = border ? "B" : "T"
        }
    }

    // Tail, pointing down toward the octopus on the right side.
    let tailBase = w - 26
    grid.append(contentsOf: Array(repeating: Array(repeating: Character("."), count: w), count: 5))
    for i in 0..<5 {
        let r = h + i
        let left = tailBase + i
        let right = tailBase + 8 - i
        for c in left...right where c < w {
            grid[r][c] = (c == left || c == right || r == h + 4) ? "B" : "T"
        }
    }
    // Open the bubble border where the tail attaches.
    for c in (tailBase + 1)..<(tailBase + 8) { grid[h - 1][c] = "T" }
    return grid
}

// Icon strip mirroring the menubar overview, e.g. bell 1, play 3, check 2.
private func overviewGrid(counts: [(icon: Character, count: Int)]) -> [[Character]] {
    let visible = counts.filter { $0.count > 0 }
    guard !visible.isEmpty else { return [] }
    let itemW = 5 + 2 + 8  // icon + gap + up to 2 digits
    let w = visible.count * itemW
    var grid = Array(repeating: Array(repeating: Character("."), count: w), count: 5)
    for (i, item) in visible.enumerated() {
        let x = i * itemW
        stampIcon(item.icon, into: &grid, row: 0, col: x)
        let color = pixelIcons[item.icon]?.color ?? "B"
        stampText("\(min(item.count, 99))", into: &grid, row: 0, col: x + 7, color: color)
    }
    return grid
}

// MARK: - Model

enum PetAgentKind { case busy, waiting, error }

struct PetBubbleRow {
    let id: String       // session fileID, used for click-to-attach
    let kind: PetAgentKind
    let text: String     // session name
    let ago: String      // time in the blocked state, right-aligned
    let why: String?     // shortWaitingFor tag, picks the row icon
}

struct PetStatusCounts {
    var waiting = 0
    var error = 0
    var busy = 0
    var done = 0
}

// MARK: - Scene

private enum PetMode { case sleep, idle, busy, blocked, panic }

final class PetScene: SKScene {
    var onRowClick: ((String) -> Void)?

    private let octopus = SKSpriteNode()
    private let bubble = SKSpriteNode()
    private let overview = SKSpriteNode()
    private var bubbleRows: [PetBubbleRow] = []
    private var bubbleCollapsed = false
    private var collapsedIds: Set<String> = []
    private var mode: PetMode = .idle
    private var stage: PetStage = .hatchling
    private var species: PetSpecies = allPetSpecies[0]
    private var idleSince: TimeInterval = 0
    private var zzzEmitter: Timer?
    private var frameCache: [String: ([SKTexture], TimeInterval)] = [:]
    private var lastOverviewKey = ""

    private let bodyCenter: CGPoint
    // Render the bubble grid at 5x then display at half size: an effective
    // 2.5x that stays pixel-crisp on retina (5 device pixels per grid cell).
    private let bubbleRenderScale = 5
    private let bubbleDisplayFactor: CGFloat = 0.5
    private var bubbleScale: CGFloat { CGFloat(bubbleRenderScale) * bubbleDisplayFactor }

    override init(size: CGSize) {
        bodyCenter = CGPoint(x: size.width - 70, y: 64)
        super.init(size: size)
        backgroundColor = .clear
        octopus.size = CGSize(width: 80, height: 80)
        octopus.position = bodyCenter
        octopus.name = "petBody"
        addChild(octopus)

        bubble.name = "bubble"
        bubble.anchorPoint = CGPoint(x: 1, y: 0)  // bottom-right, above the head
        bubble.isHidden = true
        addChild(bubble)


        overview.name = "overview"
        overview.anchorPoint = CGPoint(x: 1, y: 0.5)
        addChild(overview)

        applyMode(.idle, force: true)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("not used") }

    func setStage(_ newStage: Int) {
        let s = PetStage(rawValue: min(newStage, 2)) ?? .hatchling
        guard s != stage else { return }
        stage = s
        frameCache.removeAll()
        applyMode(mode, force: true)
    }

    func setSpecies(_ id: String) {
        guard id != species.id else { return }
        species = petSpecies(withID: id)
        frameCache.removeAll()
        applyMode(mode, force: true)
    }

    // Stop timers and rendering while the pet is hidden; resume cleanly.
    func setActive(_ on: Bool) {
        isPaused = !on
        if on {
            applyMode(mode, force: true)
        } else {
            zzzEmitter?.invalidate()
            zzzEmitter = nil
        }
    }

    func apply(counts: PetStatusCounts, rows: [PetBubbleRow]) {
        updateOverview(counts)
        updateBubble(rows)

        let newMode: PetMode
        if counts.error > 0 {
            newMode = .panic
        } else if !rows.isEmpty {
            newMode = .blocked
        } else if counts.busy > 0 {
            newMode = .busy
        } else if CACurrentMediaTime() - idleSince > 90 {
            newMode = .sleep
        } else {
            newMode = .idle
        }
        if newMode != .sleep && newMode != .idle {
            idleSince = CACurrentMediaTime()
        }
        applyMode(newMode)
    }

    private func updateOverview(_ counts: PetStatusCounts) {
        let key = "\(counts.waiting)/\(counts.error)/\(counts.busy)/\(counts.done)"
        guard key != lastOverviewKey else { return }
        lastOverviewKey = key
        let grid = overviewGrid(counts: [
            ("b", counts.waiting), ("x", counts.error),
            ("p", counts.busy), ("c", counts.done),
        ])
        if grid.isEmpty {
            overview.isHidden = true
            return
        }
        overview.isHidden = false
        let tex = texture(from: grid, scale: 2)
        overview.texture = tex
        overview.size = tex.size()
        overview.position = CGPoint(x: bodyCenter.x - 52, y: bodyCenter.y - 20)
    }

    private func updateBubble(_ rows: [PetBubbleRow]) {
        let key: ([PetBubbleRow]) -> [String] = { list in
            list.map { "\($0.id)|\($0.text)|\($0.ago)|\($0.why ?? "")" }
        }
        let unchanged = key(rows) == key(bubbleRows)
        bubbleRows = rows
        if rows.isEmpty {
            bubble.isHidden = true
            bubbleCollapsed = false
            collapsedIds = []
            return
        }

        // A newly blocked session re-opens a closed bubble; the same set of
        // sessions stays closed.
        let ids = Set(rows.map { $0.id })
        if bubbleCollapsed && !ids.subtracting(collapsedIds).isEmpty {
            bubbleCollapsed = false
        }
        if bubbleCollapsed {
            bubble.isHidden = true
            return
        }

        if !bubble.isHidden && unchanged { return }
        // Emoji says WHY the agent is blocked. Blocked with no stated reason
        // means "waiting for your reply", hence the question mark; the bell
        // only remains for reason strings we don't recognize yet.
        let emojiFor: (PetBubbleRow) -> String = { row in
            if row.kind == .error { return "⛔" }
            switch row.why {
            case nil, "question": return "❓"
            case "permission": return "🔒"
            case "sandbox": return "📦"
            case "worker": return "⚙️"
            case "dialog": return "💬"
            default: return "🔔"
            }
        }
        let grid = bubbleGrid(rowCount: rows.count)
        let tex = texture(from: grid, scale: bubbleRenderScale)
        bubble.texture = tex
        bubble.size = CGSize(width: tex.size().width * bubbleDisplayFactor,
                             height: tex.size().height * bubbleDisplayFactor)

        // Real monospaced text over the pixel frame: name left, age right.
        bubble.removeAllChildren()
        let w = bubble.size.width
        let h = bubble.size.height

        for (i, row) in rows.enumerated() {
            let rowTop = (4 + CGFloat(i) * 8) * bubbleScale
            let y = h - rowTop - 2.5 * bubbleScale  // center of the 5px row

            let name = SKLabelNode(text: "\(emojiFor(row)) \(row.text.prefix(28))")
            name.fontName = "Menlo"
            name.fontSize = 12
            name.fontColor = .black
            name.horizontalAlignmentMode = .left
            name.verticalAlignmentMode = .center
            name.position = CGPoint(x: -w + 4 * bubbleScale + 4, y: y)
            bubble.addChild(name)

            let ago = SKLabelNode(text: row.ago)
            ago.fontName = "Menlo"
            ago.fontSize = 11
            ago.fontColor = NSColor.black.withAlphaComponent(0.55)
            ago.horizontalAlignmentMode = .right
            ago.verticalAlignmentMode = .center
            ago.position = CGPoint(x: -5 * bubbleScale, y: y)
            bubble.addChild(ago)
        }
        bubble.position = CGPoint(x: size.width - 6, y: bodyCenter.y + 48)
        if bubble.isHidden {
            bubble.isHidden = false
            bubble.alpha = 0
            bubble.run(.fadeIn(withDuration: 0.15))
        }
    }

    private func frames(for mode: PetMode) -> ([SKTexture], TimeInterval) {
        let cacheKey = "\(species.id)-\(mode)-\(stage)"
        if let cached = frameCache[cacheKey] { return cached }
        func f(_ eyes: EyeStyle, _ variant: Int, wave: Bool = false, phase: Int = 0) -> SKTexture {
            texture(from: species.compose(eyes, variant, stage, wave, phase), scale: 4)
        }
        let result: ([SKTexture], TimeInterval)
        switch mode {
        case .idle:    result = ([f(.open, 0), f(.open, 1)], 0.5)
        case .sleep:   result = ([f(.closed, 0), f(.closed, 1)], 0.9)
        case .busy:    result = ([f(.open, 0), f(.open, 1)], 0.25)
        case .blocked: result = ([f(.open, 0, wave: true, phase: 0),
                                  f(.open, 1, wave: true, phase: 1)], 0.35)
        case .panic:   result = ([f(.wide, 0), f(.wide, 1)], 0.12)
        }
        frameCache[cacheKey] = result
        return result
    }

    private func applyMode(_ newMode: PetMode, force: Bool = false) {
        guard force || newMode != mode else { return }
        mode = newMode
        let (texs, perFrame) = frames(for: newMode)
        octopus.removeAction(forKey: "anim")
        octopus.texture = texs[0]
        octopus.run(.repeatForever(.animate(with: texs, timePerFrame: perFrame)), withKey: "anim")

        zzzEmitter?.invalidate()
        zzzEmitter = nil
        if newMode == .sleep {
            zzzEmitter = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.spawnZzz()
            }
        }
    }

    private func spawnZzz() {
        let z = SKLabelNode(text: "z")
        z.fontName = "Menlo"
        z.fontSize = 13
        z.fontColor = NSColor.white.withAlphaComponent(0.8)
        z.position = CGPoint(x: bodyCenter.x + 34, y: bodyCenter.y + 34)
        addChild(z)
        z.run(.sequence([
            .group([.moveBy(x: 14, y: 30, duration: 1.6), .fadeOut(withDuration: 1.6)]),
            .removeFromParent(),
        ]))
    }

    // Tapping the octopus hides the bubble completely, or brings it back.
    // A newly blocked session still re-opens it on its own.
    private func toggleBubble() {
        guard !bubbleRows.isEmpty else { return }
        bubbleCollapsed.toggle()
        if bubbleCollapsed {
            collapsedIds = Set(bubbleRows.map { $0.id })
            bubble.isHidden = true
        } else {
            bubble.isHidden = true  // force a fresh render with current rows
            updateBubble(bubbleRows)
        }
    }

    private func bubbleRowIndex(at sceneLocation: CGPoint) -> Int? {
        guard !bubble.isHidden, bubble.contains(sceneLocation) else { return nil }
        let topY = bubble.position.y + bubble.size.height
        let padding = 4 * bubbleScale
        let lineH = 8 * bubbleScale
        let offset = topY - padding - sceneLocation.y
        let idx = Int(floor(offset / lineH))
        return (idx >= 0 && idx < bubbleRows.count) ? idx : nil
    }

    // The window regions that should catch the mouse: the octopus body and,
    // when visible, the speech bubble. Everything else clicks through to
    // whatever is behind the window.
    var interactiveRects: [CGRect] {
        var rects = [octopus.frame.insetBy(dx: -8, dy: -8)]
        if !bubble.isHidden { rects.append(bubble.frame.insetBy(dx: -6, dy: -6)) }
        return rects
    }

    override func mouseDown(with event: NSEvent) {
        let loc = event.location(in: self)
        if let idx = bubbleRowIndex(at: loc) {
            onRowClick?(bubbleRows[idx].id)
            return
        }
        if !bubble.isHidden, bubble.contains(loc) {
            onRowClick?(bubbleRows.first?.id ?? "")
            return
        }
        guard nodes(at: loc).contains(where: { $0.name == "petBody" }),
              let win = view?.window else { return }
        // Tap the body toggles the bubble; dragging the body moves the
        // window. The drag is applied via setFrameOrigin, which skips the
        // system's screen-edge clamping entirely.
        let startMouse = NSEvent.mouseLocation
        let startOrigin = win.frame.origin
        while true {
            guard let next = win.nextEvent(matching: [.leftMouseUp, .leftMouseDragged])
            else { return }
            if next.type == .leftMouseUp {
                let moved = hypot(NSEvent.mouseLocation.x - startMouse.x,
                                  NSEvent.mouseLocation.y - startMouse.y)
                if moved < 3 { toggleBubble() }  // tap the pet = show/hide bubble
                return
            }
            let now = NSEvent.mouseLocation
            win.setFrameOrigin(NSPoint(x: startOrigin.x + now.x - startMouse.x,
                                       y: startOrigin.y + now.y - startMouse.y))
        }
    }

}

// MARK: - Controller

// macOS normally refuses to place a window's top edge above the menubar,
// which makes the (mostly transparent) pet window snap down when dragged
// high. The pet should go wherever it's shoved, clipping included.
private final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class PetController {
    private let panel: NSPanel
    private let scene: PetScene
    private var enabled = true
    private(set) var xp: Int
    private(set) var speciesID: String

    var onAttach: ((String) -> Void)?
    var onXPChanged: ((Int) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    private var moveDebounce: Timer?
    private var hoverTimer: Timer?

    init(initialXP: Int, initialSpecies: String, savedOrigin: NSPoint?) {
        xp = initialXP
        speciesID = petSpecies(withID: initialSpecies).id

        let size = CGSize(width: 440, height: 290)
        panel = UnconstrainedPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false

        let skView = SKView(frame: NSRect(origin: .zero, size: size))
        skView.allowsTransparency = true
        scene = PetScene(size: size)
        scene.scaleMode = .resizeFill
        skView.presentScene(scene)
        panel.contentView = skView

        scene.setSpecies(speciesID)
        scene.setStage(PetController.stage(forXP: xp))
        scene.onRowClick = { [weak self] id in
            if !id.isEmpty { self?.onAttach?(id) }
        }

        // Restore the last dragged position if it's still on a screen;
        // fall back to bottom-right otherwise (e.g. monitor unplugged).
        let onSomeScreen = savedOrigin.map { origin in
            NSScreen.screens.contains { $0.frame.intersects(
                NSRect(origin: origin, size: size)) }
        } ?? false
        if let origin = savedOrigin, onSomeScreen {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 30, y: vf.minY + 10))
        }

        // Per-region click-through: the window only catches the mouse while
        // the pointer is over the octopus or the visible bubble; everything
        // else passes clicks to whatever is behind. Cheap 20Hz position
        // check; the timer pauses automatically during drags (event-tracking
        // runloop mode), so it can't fight the drag loop.
        panel.ignoresMouseEvents = true
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.enabled, self.panel.isVisible else { return }
            let mouse = NSEvent.mouseLocation
            let origin = self.panel.frame.origin
            let hit = self.scene.interactiveRects.contains { rect in
                rect.offsetBy(dx: origin.x, dy: origin.y).contains(mouse)
            }
            if self.panel.ignoresMouseEvents == hit {
                self.panel.ignoresMouseEvents = !hit
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.moveDebounce?.invalidate()
            self.moveDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                self.onMoved?(self.panel.frame.origin)
            }
        }
    }

    static func stage(forXP xp: Int) -> Int {
        if xp >= 100 { return 2 }
        if xp >= 25 { return 1 }
        return 0
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        scene.setActive(on)
        if on {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func gainXP() {
        xp += 1
        scene.setStage(PetController.stage(forXP: xp))
        onXPChanged?(xp)
    }

    func setSpecies(_ id: String) {
        let resolved = petSpecies(withID: id).id
        guard resolved != speciesID else { return }
        speciesID = resolved
        scene.setSpecies(resolved)
    }

    func update(counts: PetStatusCounts, rows: [PetBubbleRow]) {
        guard enabled else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
        scene.apply(counts: counts, rows: rows)
    }
}
