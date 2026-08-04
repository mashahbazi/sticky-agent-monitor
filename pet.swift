// Octoclaude: a pixel-art octopus desktop pet that embodies the agent fleet.
// A pixel icon strip beside it mirrors the menubar overview (bell/balloon/
// play/check/cross with counts), and when an agent is blocked it raises a
// tentacle and shows a cartoony speech bubble with the sessions that want
// you, rendered in a tiny hand-drawn pixel font. A blocked agent gets the
// bell; one that only asked a question gets the balloon and no waving.
// Feeds on completed tasks (XP persisted in
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
    "b": (["..X..", ".XXX.", ".XXX.", "XXXXX", "..X.."], "A"),  // bell, blocked
    "q": (["XXXXX", "X...X", "XXXXX", ".X...", "....."], "C"),  // balloon, asked
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
// Art comes either from a compose function (built-in pixel-grid pets) or
// from a petdex.dev sprite-sheet atlas on disk.
struct PetSpecies {
    let id: String
    let displayName: String
    fileprivate let compose: ((_ eyes: EyeStyle, _ variant: Int, _ stage: PetStage,
                               _ wave: Bool, _ wavePhase: Int) -> [[Character]])?
    fileprivate let atlasURL: URL?

    fileprivate init(id: String, displayName: String,
                     compose: @escaping (_ eyes: EyeStyle, _ variant: Int, _ stage: PetStage,
                                         _ wave: Bool, _ wavePhase: Int) -> [[Character]]) {
        self.id = id
        self.displayName = displayName
        self.compose = compose
        self.atlasURL = nil
    }

    init(id: String, displayName: String, atlasURL: URL) {
        self.id = id
        self.displayName = displayName
        self.compose = nil
        self.atlasURL = atlasURL
    }

    // What the Pet menu and the Settings popup both show. Installs are free to
    // ship the same displayName (both `mochi` and `mochi-10` call themselves
    // "Mochi"), so every petdex pet always spells out its install slug, even
    // when the name already implies it: the slug is the identity you picked and
    // the only thing that tells two same-named installs apart.
    var pickerLabel: String {
        guard id.hasPrefix("petdex:") else { return displayName }
        let slug = String(id.dropFirst("petdex:".count))
        return "\(displayName) (\(slug))"
    }
}

let builtinPetSpecies: [PetSpecies] = [
    PetSpecies(id: "octopus", displayName: "Octopus") { eyes, variant, stage, wave, phase in
        composeFrame(eyes: eyes, tentacles: variant == 0 ? .a : .b,
                     stage: stage, waveArm: wave, wavePhase: phase)
    },
    PetSpecies(id: "cat", displayName: "Cat", compose: composeCat),
    PetSpecies(id: "robot", displayName: "Robot", compose: composeRobot),
    PetSpecies(id: "slime", displayName: "Slime", compose: composeSlime),
]

// Pets installed from petdex.dev (`npx petdex install <slug>`) live in
// ~/.codex/pets/<slug>/ as pet.json + a spritesheet. Every installed pet
// becomes a selectable species alongside the built-in ones.
func discoverPetdexSpecies() -> [PetSpecies] {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/pets")
    guard let subdirs = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil) else { return [] }
    var found: [PetSpecies] = []
    for d in subdirs {
        guard let data = try? Data(contentsOf: d.appendingPathComponent("pet.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        let sheetName = (obj["spritesheetPath"] as? String) ?? "spritesheet.webp"
        let sheet = d.appendingPathComponent(sheetName)
        guard FileManager.default.fileExists(atPath: sheet.path) else { continue }
        // Keyed on the install slug, not pet.json's "id": the slug is the
        // directory name so it is unique by construction, while ids collide
        // (mochi-10 ships id "mochi"), which would make the saved species
        // ambiguous and drop one pet out of the picker.
        let slug = d.lastPathComponent
        found.append(PetSpecies(id: "petdex:\(slug)",
                                displayName: (obj["displayName"] as? String) ?? slug,
                                atlasURL: sheet))
    }
    return found.sorted { $0.displayName < $1.displayName }
}

var allPetSpecies: [PetSpecies] = builtinPetSpecies + discoverPetdexSpecies()

func refreshPetSpecies() {
    allPetSpecies = builtinPetSpecies + discoverPetdexSpecies()
}

func petSpecies(withID id: String) -> PetSpecies {
    allPetSpecies.first { $0.id == id } ?? allPetSpecies[0]
}

// Labels for a species list, guaranteed distinct. `pickerLabel` already spells
// out the slug where the display name is ambiguous, but nothing stops an
// install from naming itself after a built-in ("Cat"), and NSPopUpButton
// silently drops an item whose title already exists, which would desync the
// popup's indices from this list.
func petPickerLabels(_ species: [PetSpecies]) -> [String] {
    var used: Set<String> = []
    return species.map { s in
        var label = s.pickerLabel
        if used.contains(label) { label += " [\(s.id)]" }
        used.insert(label)
        return label
    }
}

// Canonical petdex atlas layout, ported from crafter-station/petdex's
// native renderer (main.zig): 8 columns, 9 rows (v2 sheets: 11, the extra
// "look" rows sit below the states), one animation per row with per-frame
// timings. waving / failed / jumping / review are transient by design:
// petdex plays them once and reverts to idle, so they must not loop.
private struct PetdexAnim {
    let row: Int
    let frameMs: [Int]
}

private let petdexAnims: [String: PetdexAnim] = [
    "idle":          PetdexAnim(row: 0, frameMs: [280, 110, 110, 140, 140, 320]),
    "running-right": PetdexAnim(row: 1, frameMs: [120, 120, 120, 120, 120, 120, 120, 220]),
    "running-left":  PetdexAnim(row: 2, frameMs: [120, 120, 120, 120, 120, 120, 120, 220]),
    "waving":        PetdexAnim(row: 3, frameMs: [140, 140, 140, 280]),
    "jumping":       PetdexAnim(row: 4, frameMs: [140, 140, 140, 140, 280]),
    "failed":        PetdexAnim(row: 5, frameMs: [140, 140, 140, 140, 140, 140, 140, 240]),
    "waiting":       PetdexAnim(row: 6, frameMs: [150, 150, 150, 150, 150, 260]),
    "running":       PetdexAnim(row: 7, frameMs: [120, 120, 120, 120, 120, 220]),
    "review":        PetdexAnim(row: 8, frameMs: [150, 150, 150, 150, 150, 280]),
]

private var atlasSheetCache: [String: SKTexture] = [:]

// petdex sheets store their pixel-styled art at 1:1, one art pixel per image
// pixel, and the pet is displayed at whatever fraction of 208pt the size
// slider asks for. Nearest-neighbour at a non-integer scale drops whole rows
// of pixels unevenly, which shimmers as the animation moves, so atlas textures
// sample linearly. The code-drawn grids in `texture(from:)` are rendered at
// an integer scale from a small grid and keep .nearest.
private func atlasSheet(_ url: URL) -> SKTexture? {
    if let cached = atlasSheetCache[url.path] { return cached }
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let t = SKTexture(cgImage: cg)
    t.filteringMode = .linear
    atlasSheetCache[url.path] = t
    return t
}

// v2 atlases (8x11) are taller: same 192x208 frame, more rows below the
// nine states.
private func atlasRowCount(width: Int, height: Int) -> Int {
    height * 1536 >= width * 2288 ? 11 : 9
}

// Where the drawn animal sits inside its cell, as fractions of that cell.
// Pets pad their sheets very differently (dalek's body fills 77% x 78% of
// its cell where buge's fills 85% x 95%), so sizing and hit-testing off the
// raw cell makes one slider value produce visibly different pets, and leaves
// a slab of empty window swallowing clicks above the shorter ones.
private struct AtlasBody {
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let bottomFraction: CGFloat   // opaque bottom, above the cell's bottom edge
    let centerXFraction: CGFloat  // opaque centre, from the cell's left edge
}

private let atlasBodyFallback = AtlasBody(widthFraction: 1, heightFraction: 1,
                                          bottomFraction: 0, centerXFraction: 0.5)
private var atlasBodyCache: [String: AtlasBody] = [:]

// Opaque bounding box of the first idle frame: the silhouette the pet shows
// while standing still, which is what "how big is this pet" should mean.
private func atlasBody(_ url: URL) -> AtlasBody {
    if let cached = atlasBodyCache[url.path] { return cached }
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return atlasBodyFallback }
    let cellW = cg.width / 8
    let cellH = cg.height / atlasRowCount(width: cg.width, height: cg.height)
    // cropping(to:) is top-left origin, so this is the idle row's first cell.
    guard cellW > 0, cellH > 0,
          let cell = cg.cropping(to: CGRect(x: 0, y: 0, width: cellW, height: cellH))
    else { return atlasBodyFallback }

    var pixels = [UInt8](repeating: 0, count: cellW * cellH * 4)
    var body = atlasBodyFallback
    pixels.withUnsafeMutableBytes { buf in
        guard let base = buf.baseAddress,
              let ctx = CGContext(data: base, width: cellW, height: cellH,
                                  bitsPerComponent: 8, bytesPerRow: cellW * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(cell, in: CGRect(x: 0, y: 0, width: cellW, height: cellH))
        let px = base.assumingMemoryBound(to: UInt8.self)
        var minX = cellW, maxX = -1, minY = cellH, maxY = -1
        for y in 0..<cellH {
            for x in 0..<cellW where px[(y * cellW + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return }
        let w = CGFloat(cellW), h = CGFloat(cellH)
        // A bitmap context draws bottom-up but stores its rows top-down, so
        // `maxY` is the LOWEST opaque scanline and the gap under the pet is
        // measured from it. Getting this backwards is invisible on a pet whose
        // padding happens to be symmetric and drops the others through the
        // floor.
        body = AtlasBody(
            widthFraction: CGFloat(maxX - minX + 1) / w,
            heightFraction: CGFloat(maxY - minY + 1) / h,
            bottomFraction: CGFloat(cellH - 1 - maxY) / h,
            centerXFraction: CGFloat(minX + maxX + 1) / 2 / w)
    }
    atlasBodyCache[url.path] = body
    return body
}

// One animation's frames with their durations, sliced out of the sheet.
private func atlasFrames(sheetURL: URL, anim name: String,
                         slowdown: Double = 1) -> [(tex: SKTexture, dur: TimeInterval)]? {
    guard let anim = petdexAnims[name], let sheet = atlasSheet(sheetURL) else { return nil }
    let size = sheet.size()
    guard size.width > 0, size.height > 0 else { return nil }
    let rows = CGFloat(atlasRowCount(width: Int(size.width), height: Int(size.height)))
    let cols: CGFloat = 8
    return anim.frameMs.enumerated().map { i, ms in
        // SKTexture sub-rects are normalized with a bottom-left origin;
        // atlas rows are counted from the top.
        let rect = CGRect(x: CGFloat(i) / cols,
                          y: 1 - CGFloat(anim.row + 1) / rows,
                          width: 1 / cols, height: 1 / rows)
        let frame = SKTexture(rect: rect, in: sheet)
        frame.filteringMode = .linear
        return (frame, TimeInterval(ms) / 1000 * slowdown)
    }
}

private func frameSequence(_ frames: [(tex: SKTexture, dur: TimeInterval)]) -> SKAction {
    .sequence(frames.map {
        .sequence([.setTexture($0.tex, resize: false), .wait(forDuration: $0.dur)])
    })
}

// Working states are bursts, not treadmills. Upstream drives `running` and
// `review` from per-tool-call hooks and drops straight back to idle on the
// tool's post hook, so a busy pet is a train of short bursts separated by
// idling. We only learn about work once per poll, so approximate that
// rhythm: one cycle of the working animation, one idle breath, then a
// randomized pause so consecutive bursts never land on a beat.
private func burstLoop(_ frames: [(tex: SKTexture, dur: TimeInterval)],
                       breather: [(tex: SKTexture, dur: TimeInterval)],
                       rest: TimeInterval, range: TimeInterval) -> SKAction {
    .repeatForever(.sequence([
        frameSequence(frames),
        frameSequence(breather),
        .setTexture(breather[0].tex, resize: false),
        .wait(forDuration: rest, withRange: range),
    ]))
}

// A resting pet is mostly still. The idle row is not a breath loop: mochi's
// six frames blink twice and glance both ways inside 1.1s, so looping it
// forever reads as a nervous cat rather than a chilling one. Play one pass,
// then hold its neutral first frame for a long randomized beat, which turns
// constant fidgeting into an occasional blink.
private func settleLoop(_ frames: [(tex: SKTexture, dur: TimeInterval)],
                        rest: TimeInterval, range: TimeInterval) -> SKAction {
    .repeatForever(.sequence([
        frameSequence(frames),
        .setTexture(frames[0].tex, resize: false),
        .wait(forDuration: rest, withRange: range),
    ]))
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
// pointing at the octopus. One line per session that wants you, drawn entirely
// as real monospaced labels over the sprite (icon + name + right-aligned age),
// so the grid only carries the frame. The icon says which of the two kinds of
// attention this is, and for a blocked agent it goes further and says which
// gate: lock = permission, box = sandbox, gear = worker, speech = dialog,
// question = needs an answer; balloon = merely asked, check = just finished,
// hourglass = still running, cross = errored.
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

// `blocked` = parked at a permission/input gate and cannot move; `asked` =
// finished its turn with a question for you; `done` = finished, nothing
// pending; `more` = the "+N more" overflow line, which draws no icon and is
// not clickable. Only `blocked` is an alarm.
enum PetAgentKind { case busy, blocked, asked, done, error, more }

struct PetBubbleRow {
    let id: String       // session fileID, used for click-to-attach
    let kind: PetAgentKind
    let text: String     // session name
    let ago: String      // time in the blocked state, right-aligned
    let why: String?     // shortWaitingFor tag, picks the row icon
}

struct PetStatusCounts {
    var blocked = 0
    var asked = 0
    var error = 0
    var busy = 0
    var done = 0
}

// MARK: - Scene

// `reviewing` is `busy` with one session in flight: petdex has a whole
// read-only "review" animation that would otherwise go unused, and a fleet
// with a single agent working deserves the calmer of the two.
private enum PetMode { case sleep, idle, reviewing, busy, blocked, panic }

// Reference height of the drawn ANIMAL at slider 1.0. Upstream petdex draws
// a 192x208 cell at scale 0.7 (~146pt) and a pet that fills its cell covers
// about 95% of that, so ~138pt is upstream's default pet measured on the
// animal rather than on however much padding its sheet happens to carry.
private let atlasBodyHeight: CGFloat = 138

// The floor the animal's feet stand on, in scene coordinates.
private let atlasFloorY: CGFloat = 18

// How long a resting pet holds still between passes of its idle row. SpriteKit
// spreads a wait over `duration +/- range/2`, so this is a 1.4s to 3.0s hold:
// a ~0.9s row plays roughly once every three seconds, which is a pet that
// blinks now and then rather than one that either fidgets or freezes.
private let idleRest: TimeInterval = 2.2
private let idleRestRange: TimeInterval = 1.6

final class PetScene: SKScene {
    var onRowClick: ((String) -> Void)?
    // True while the body drag loop owns the window origin, so an
    // externally-driven move can't yank the window out from under the mouse.
    private(set) var isDragging = false

    private let octopus = SKSpriteNode()
    private let bubble = SKSpriteNode()
    private let overview = SKSpriteNode()
    private var bubbleRows: [PetBubbleRow] = []
    private var bubbleCollapsed = false
    private var collapsedIds: Set<String> = []
    private var mode: PetMode = .idle
    private var stage: PetStage = .hatchling
    private var species: PetSpecies = allPetSpecies[0]
    private var sizeScale: CGFloat = 1
    // Seeded at launch, not left at zero: CACurrentMediaTime() is seconds since
    // boot, so a zero here reads as "idle since the machine booted" and the pet
    // starts up asleep on a quiet machine instead of idling first.
    private var idleSince = CACurrentMediaTime()
    private var zzzEmitter: Timer?
    private var frameCache: [String: ([SKTexture], TimeInterval)] = [:]
    private var lastOverviewKey = ""
    // Where the drawn animal sits in the scene. For a padded atlas cell this
    // is much smaller than `octopus.frame`, and clicks, the bubble tail and
    // the overview strip all have to line up with the animal, not the cell.
    private var animalRect: CGRect = .zero
    // Set while a drag is playing a directional run, so releasing knows to
    // hand the sprite back to its mode animation.
    private var dragAnim: String?
    private var patFlip = false

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

    func setSizeScale(_ scale: CGFloat) {
        let clamped = min(max(scale, 0.5), 2.0)
        guard clamped != sizeScale else { return }
        sizeScale = clamped
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
            isDragging = false
        }
    }

    func apply(counts: PetStatusCounts, rows: [PetBubbleRow]) {
        updateOverview(counts)
        updateBubble(rows)

        // The body only escalates for agents that are genuinely stuck. One
        // that merely ended its turn with a question leaves the pet calm —
        // its bubble row is enough.
        let newMode: PetMode
        if counts.error > 0 {
            newMode = .panic
        } else if counts.blocked > 0 {
            newMode = .blocked
        } else if counts.busy > 1 {
            newMode = .busy
        } else if counts.busy > 0 {
            newMode = .reviewing
        } else if rows.isEmpty && CACurrentMediaTime() - idleSince > 90 {
            newMode = .sleep  // stay awake while a bubble is still up
        } else {
            newMode = .idle
        }
        if newMode != .sleep && newMode != .idle {
            idleSince = CACurrentMediaTime()
        }
        applyMode(newMode)
    }

    private func updateOverview(_ counts: PetStatusCounts) {
        let key = "\(counts.blocked)/\(counts.error)/\(counts.asked)/\(counts.busy)/\(counts.done)"
        guard key != lastOverviewKey else { return }
        lastOverviewKey = key
        let grid = overviewGrid(counts: [
            ("b", counts.blocked), ("x", counts.error), ("q", counts.asked),
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
        layoutOverview()
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

        // A session that newly wants something re-opens a closed bubble; the
        // same set of sessions stays closed. Busy rows are excluded from that
        // test on purpose: they come and go constantly as agents start work,
        // and letting them re-open the bubble would defeat closing it at all.
        // Nothing about a busy agent is worth overriding the user for.
        let ids = Set(rows.filter { $0.kind != .busy && $0.kind != .more }.map { $0.id })
        if bubbleCollapsed && !ids.subtracting(collapsedIds).isEmpty {
            bubbleCollapsed = false
        }
        if bubbleCollapsed {
            bubble.isHidden = true
            return
        }

        if !bubble.isHidden && unchanged { return }
        // The kind decides the icon first, mirroring the menubar glyphs so the
        // two readings agree (💬 = asked, ✅ = done, ⏳ = busy, ❌ = error).
        // Only a genuinely blocked agent goes further and names its gate, which
        // is the difference between "go approve something" and "go answer
        // something", the whole reason a blocked row is worth interrupting for.
        // An unrecognized gate name falls back to the plain bell.
        let emojiFor: (PetBubbleRow) -> String = { row in
            switch row.kind {
            case .error: return "❌"
            case .more:  return " "   // the "+N more" line carries no icon
            case .done:  return "✅"
            case .busy:  return "⏳"
            case .asked: return "💬"
            case .blocked:
                switch row.why {
                case nil, "question": return "❓"
                case "permission":    return "🔒"
                case "sandbox":       return "📦"
                case "worker":        return "⚙️"
                case "dialog":        return "🗨️"
                default:              return "🔔"
                }
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
        bubble.position = CGPoint(x: size.width - 6, y: animalRect.maxY + 6)
        if bubble.isHidden {
            bubble.isHidden = false
            bubble.alpha = 0
            bubble.run(.fadeIn(withDuration: 0.15))
        }
    }

    // Mode -> petdex animation. Upstream splits its nine states into
    // transient ones (waving / jumping / failed / review, played for a dwell
    // and then reverted to idle) and steady ones, of which only `waiting`
    // is not idle. Every state change there is a discrete hook event, per
    // tool call, so the pet is idle-dominant: it flickers into work for the
    // length of a call and drops back. Our session poll gives moods instead
    // of events, so the rule here is that idle is the resting state, entering
    // a mode fires its reaction once, and what loops afterwards is either
    // idle, `waiting`, or short bursts with idle in between.
    private func atlasAction(for mode: PetMode, atlas: URL) -> (action: SKAction, first: SKTexture)? {
        switch mode {
        case .idle:
            // A blink or a glance every few seconds, not every second: the row
            // itself keeps the artist's timing, the stillness between passes is
            // what makes it read as resting. Randomized so it never ticks.
            guard let f = atlasFrames(sheetURL: atlas, anim: "idle") else { return nil }
            return (settleLoop(f, rest: idleRest, range: idleRestRange), f[0].tex)
        case .sleep:
            // petdex has no sleeping row, so sleep is idle at half speed and
            // the zzz overlay carries the meaning. It rests longer than idle
            // does, because a sleeping pet that stirs more than an awake one
            // looks wrong.
            guard let f = atlasFrames(sheetURL: atlas, anim: "idle", slowdown: 2.5) else { return nil }
            return (settleLoop(f, rest: idleRest * 1.6, range: idleRestRange), f[0].tex)
        case .reviewing:
            guard let review = atlasFrames(sheetURL: atlas, anim: "review"),
                  let breathe = atlasFrames(sheetURL: atlas, anim: "idle") else { return nil }
            return (burstLoop(review, breather: breathe, rest: 2.5, range: 2.0), breathe[0].tex)
        case .busy:
            guard let run = atlasFrames(sheetURL: atlas, anim: "running"),
                  let breathe = atlasFrames(sheetURL: atlas, anim: "idle") else { return nil }
            return (burstLoop(run, breather: breathe, rest: 1.2, range: 1.0), run[0].tex)
        case .blocked:
            // Wave once for attention, then sit in `waiting` until the user
            // answers. That is upstream exactly: waving is transient, and
            // `waiting` is the one steady state it loops indefinitely.
            guard let wave = atlasFrames(sheetURL: atlas, anim: "waving"),
                  let wait = atlasFrames(sheetURL: atlas, anim: "waiting") else { return nil }
            return (.sequence([frameSequence(wave),
                               .repeatForever(frameSequence(wait))]), wave[0].tex)
        case .panic:
            // `failed` is transient upstream too, so it plays once instead of
            // looping or freezing on its last frame. An errored agent is
            // still blocked on the user, so it settles into the same waiting
            // loop rather than idling as if nothing had happened.
            guard let fail = atlasFrames(sheetURL: atlas, anim: "failed"),
                  let wait = atlasFrames(sheetURL: atlas, anim: "waiting") else { return nil }
            return (.sequence([frameSequence(fail),
                               .repeatForever(frameSequence(wait))]), fail[0].tex)
        }
    }

    // Play a transient animation once, then hand the sprite back to whatever
    // its mode loops. This is upstream's duration-state revert, and the only
    // way non-idle art gets on screen outside a mode change.
    private func playOnce(_ name: String) {
        guard let atlas = species.atlasURL,
              let f = atlasFrames(sheetURL: atlas, anim: name) else { return }
        octopus.removeAction(forKey: "anim")
        octopus.texture = f[0].tex
        octopus.run(.sequence([
            frameSequence(f),
            .run { [weak self] in
                guard let self = self else { return }
                self.applyMode(self.mode, force: true)
            },
        ]), withKey: "anim")
    }

    // Task completed: a quick jump of joy. Upstream spends `jumping` on "the
    // user submitted a prompt", an event we have no equivalent for, so it
    // goes to the one moment our app does celebrate.
    func celebrate() {
        guard mode == .idle || mode == .reviewing || mode == .busy || mode == .sleep
        else { return }
        playOnce("jumping")
    }

    // Upstream's pat (main.zig ~1947): a click that does not move alternates
    // jumping / waving so repeated pats do not feel canned.
    func pat() {
        patFlip.toggle()
        playOnce(patFlip ? "jumping" : "waving")
    }

    // Rows 1 and 2 are directional runs, played while the pet is being
    // dragged sideways. Size is carried as a node scale, so swapping the
    // texture set mid-drag cannot disturb the layout.
    private func runDragAnimation(_ name: String) {
        guard let atlas = species.atlasURL, dragAnim != name,
              let f = atlasFrames(sheetURL: atlas, anim: name) else { return }
        dragAnim = name
        octopus.removeAction(forKey: "anim")
        octopus.texture = f[0].tex
        octopus.run(.repeatForever(frameSequence(f)), withKey: "anim")
    }

    private func endDragAnimation() {
        guard dragAnim != nil else { return }
        dragAnim = nil
        applyMode(mode, force: true)
    }

    private func frames(for mode: PetMode) -> ([SKTexture], TimeInterval) {
        let cacheKey = "\(species.id)-\(mode)-\(stage)"
        if let cached = frameCache[cacheKey] { return cached }
        let compose = species.compose ?? builtinPetSpecies[0].compose!
        func f(_ eyes: EyeStyle, _ variant: Int, wave: Bool = false, phase: Int = 0) -> SKTexture {
            texture(from: compose(eyes, variant, stage, wave, phase), scale: 4)
        }
        let result: ([SKTexture], TimeInterval)
        switch mode {
        case .idle:    result = ([f(.open, 0), f(.open, 1)], 0.5)
        case .sleep:   result = ([f(.closed, 0), f(.closed, 1)], 0.9)
        // The code-drawn pets have one two-frame idle per mood and no
        // read-only pose to spend on `reviewing`, so both working moods look
        // the same for them, exactly as `busy` alone used to.
        case .busy, .reviewing:
                       result = ([f(.open, 0), f(.open, 1)], 0.25)
        case .blocked: result = ([f(.open, 0, wave: true, phase: 0),
                                  f(.open, 1, wave: true, phase: 1)], 0.35)
        case .panic:   result = ([f(.wide, 0), f(.wide, 1)], 0.12)
        }
        frameCache[cacheKey] = result
        return result
    }

    // Atlas pets are sized from the animal, not from its padded cell: solve
    // for the cell size that puts the drawn body at the reference height, so
    // every species lands at the same apparent size and stands on the same
    // floor. Size is applied as a node scale because the setTexture actions
    // that drive the animation keep resetting `size` back to the frame's
    // native 192x208, the resize:false flag notwithstanding.
    private func layoutAtlasPet(_ atlas: URL) {
        let cell = octopus.texture?.size() ?? CGSize(width: 192, height: 208)
        guard cell.width > 0, cell.height > 0 else { return }
        let body = atlasBody(atlas)
        // Round the cell onto whole device pixels so linear sampling has no
        // half-pixel edge to smear, and so dragging the size slider walks
        // through stable sizes instead of shimmering sub-pixel offsets.
        let backing = view?.window?.backingScaleFactor ?? 2
        let snap: (CGFloat) -> CGFloat = { ($0 * backing).rounded() / backing }
        let h = snap(atlasBodyHeight * sizeScale / body.heightFraction)
        let w = snap(h * cell.width / cell.height)
        octopus.size = cell
        octopus.xScale = w / cell.width
        octopus.yScale = h / cell.height

        let bodyW = body.widthFraction * w
        let bodyH = body.heightFraction * h
        // Anchoring on the animal rather than the cell keeps a pet whose art
        // hugs one side of its sheet from being shoved out of the window.
        let centerX = max(bodyW / 2 + 6, min(bodyCenter.x, size.width - 6 - bodyW / 2))
        octopus.position = CGPoint(
            x: centerX - (body.centerXFraction - 0.5) * w,
            y: atlasFloorY + h / 2 - body.bottomFraction * h)
        animalRect = CGRect(x: centerX - bodyW / 2, y: atlasFloorY,
                            width: bodyW, height: bodyH)
    }

    // The overview strip is right-anchored just left of the animal, a third
    // of the way up it.
    private func layoutOverview() {
        overview.position = CGPoint(x: animalRect.minX - 10,
                                    y: animalRect.minY + animalRect.height * 0.3)
    }

    private func applyMode(_ newMode: PetMode, force: Bool = false) {
        guard force || newMode != mode else { return }
        mode = newMode
        octopus.removeAction(forKey: "anim")
        if let atlas = species.atlasURL, let built = atlasAction(for: newMode, atlas: atlas) {
            octopus.texture = built.first
            octopus.run(built.action, withKey: "anim")
        } else {
            let (texs, perFrame) = frames(for: newMode)
            octopus.texture = texs[0]
            octopus.run(.repeatForever(.animate(with: texs, timePerFrame: perFrame)), withKey: "anim")
        }
        if let atlas = species.atlasURL {
            layoutAtlasPet(atlas)
        } else {
            octopus.xScale = 1
            octopus.yScale = 1
            let side = 80 * sizeScale
            octopus.size = CGSize(width: side, height: side)
            // Keep the sprite's feet on the floor when scaled up, and its
            // right side inside the window: at the top of the size slider an
            // 80pt body becomes 160pt and used to run off the edge.
            let cx = max(side / 2 + 6, min(bodyCenter.x, size.width - 6 - side / 2))
            octopus.position = CGPoint(x: cx, y: max(bodyCenter.y, side / 2 + 10))
            animalRect = octopus.frame
        }
        layoutOverview()
        // The bubble rides on top of the animal, whatever its scale.
        if !bubble.isHidden {
            bubble.position = CGPoint(x: size.width - 6, y: animalRect.maxY + 6)
        }

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
        // Just off the top corner of the animal. Measured from `animalRect` so
        // it lands over an atlas pet's head too; for the 80x80 code-drawn pets
        // this is the same point it always was.
        z.position = CGPoint(x: animalRect.midX + animalRect.width * 0.42,
                             y: animalRect.maxY - 6)
        addChild(z)
        z.run(.sequence([
            .group([.moveBy(x: 14, y: 30, duration: 1.6), .fadeOut(withDuration: 1.6)]),
            .removeFromParent(),
        ]))
    }

    // Whether a scene point lands on something the pet actually draws (the
    // body or the speech bubble). Everything else is empty transparent window
    // that should let clicks fall through to whatever is underneath.
    // Upstream fits its window to the sprite and treats the whole 192x208
    // cell as the pet, but a padded cell is up to a third empty and this
    // window exists to be clicked through, so the animal's own bounds are
    // what capture the mouse.
    func isInteractive(at sceneLocation: CGPoint) -> Bool {
        if !bubble.isHidden && bubble.contains(sceneLocation) { return true }
        return animalRect.contains(sceneLocation)
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

    // Where the body sits inside the window. The window is mostly
    // transparent padding for the bubble, so this - not the window frame -
    // is what has to stay on screen for the pet to be findable.
    var bodyRect: CGRect { animalRect }

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
        guard animalRect.contains(loc), let win = view?.window else { return }
        // Dragging the body moves the window, applied via setFrameOrigin,
        // which skips the system's screen-edge clamping entirely. A tap is
        // shared: the bubble is load-bearing here in a way petdex's is not,
        // so it keeps the plain tap whenever it has rows to show, and the
        // pat takes the case that used to do nothing at all. Option-click
        // always pats, so the gesture is reachable either way.
        let wantsPat = event.modifierFlags.contains(.option)
        let startMouse = NSEvent.mouseLocation
        let startOrigin = win.frame.origin
        var samples: [(x: CGFloat, y: CGFloat, t: TimeInterval)] = []
        isDragging = true
        defer {
            isDragging = false
            endDragAnimation()
        }
        while true {
            guard let next = win.nextEvent(matching: [.leftMouseUp, .leftMouseDragged])
            else { return }
            if next.type == .leftMouseUp {
                let moved = hypot(NSEvent.mouseLocation.x - startMouse.x,
                                  NSEvent.mouseLocation.y - startMouse.y)
                // The pet stops where it is let go: no throw, no coasting.
                if moved < dragSlop {
                    if wantsPat || bubbleRows.isEmpty { pat() } else { toggleBubble() }
                }
                return
            }
            let now = NSEvent.mouseLocation
            let origin = NSPoint(x: startOrigin.x + now.x - startMouse.x,
                                 y: startOrigin.y + now.y - startMouse.y)
            win.setFrameOrigin(origin)
            let t = CACurrentMediaTime()
            samples.removeAll { t - $0.t > dragSampleWindow }
            samples.append((origin.x, origin.y, t))
            applyDragAnimation(dragVelocity(samples))
        }
    }

    // Velocity over the tail of the gesture, upstream's computeVelocity: the
    // newest sample against the oldest one more than a frame older, so it
    // averages the whole 100ms window instead of chasing two frames.
    private func dragVelocity(_ samples: [(x: CGFloat, y: CGFloat, t: TimeInterval)])
        -> CGVector? {
        guard let last = samples.last,
              let anchor = samples.first(where: { last.t - $0.t > 0.016 }),
              last.t > anchor.t else { return nil }
        let dt = CGFloat(last.t - anchor.t)
        return CGVector(dx: (last.x - anchor.x) / dt, dy: (last.y - anchor.y) / dt)
    }

    // The pet runs toward wherever it is being pulled, and stands still while
    // the hand holding it does.
    private func applyDragAnimation(_ velocity: CGVector?) {
        guard let v = velocity else { return }
        if v.dx >= dragMinVelocity {
            runDragAnimation("running-right")
        } else if v.dx <= -dragMinVelocity {
            runDragAnimation("running-left")
        } else if abs(v.dx) < dragRestVelocity && abs(v.dy) < dragRestVelocity {
            runDragAnimation("idle")
        } else if (dragAnim == "running-right" && v.dx <= -dragRestVelocity)
            || (dragAnim == "running-left" && v.dx >= dragRestVelocity) {
            // The dead band between the rest and run thresholds keeps a
            // wobbling hand from flapping the legs, but it must not leave the
            // pet running one way while it is plainly being pulled the other.
            runDragAnimation("idle")
        }
    }
}

// Upstream's drag constants (main.zig): a 100ms velocity window, 65pt/s
// before the pet is considered running, 3px of slop before a press counts as
// a drag rather than a tap. The velocity is only ever read to pick the run
// direction; upstream's throw physics are deliberately not implemented, so
// releasing the mouse leaves the pet exactly where it was dropped.
private let dragSampleWindow: TimeInterval = 0.1
private let dragMinVelocity: CGFloat = 65
private let dragRestVelocity: CGFloat = 20
private let dragSlop: CGFloat = 3

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
    private let skView: SKView
    private var mouseMonitors: [Any] = []
    private var enabled = true
    private(set) var xp: Int
    private(set) var speciesID: String

    var origin: NSPoint { panel.frame.origin }

    var onAttach: ((String) -> Void)?
    var onXPChanged: ((Int) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    private var moveDebounce: Timer?
    // App Nap throttles background apps after a few minutes, which makes
    // the animation stutter and drift. This opts the process out while
    // still allowing normal system sleep.
    private let activityToken = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "desktop pet animation")

    init(initialXP: Int, initialSpecies: String, savedOrigin: NSPoint?) {
        xp = initialXP
        speciesID = petSpecies(withID: initialSpecies).id

        // Mostly transparent padding: it has to hold the largest pet the size
        // slider can produce (an atlas pet at 2.0 stands ~300pt tall) plus a
        // full speech bubble above it. The pet is anchored to the bottom
        // edge, so the extra height grows upward and a saved origin still
        // puts the pet back where it was left.
        let size = CGSize(width: 440, height: 400)
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

        skView = SKView(frame: NSRect(origin: .zero, size: size))
        skView.allowsTransparency = true
        skView.preferredFramesPerSecond = 30  // plenty for sprite flips, stable pacing
        scene = PetScene(size: size)
        scene.scaleMode = .resizeFill
        skView.presentScene(scene)
        panel.contentView = skView

        // Most of the window is empty transparent space. Start click-through
        // and only capture the mouse while the cursor is actually over the
        // pet or its bubble (updated below as the mouse moves).
        panel.ignoresMouseEvents = true

        scene.setSpecies(speciesID)
        scene.setStage(PetController.stage(forXP: xp))
        scene.onRowClick = { [weak self] id in
            if !id.isEmpty { self?.onAttach?(id) }
        }

        // Restore the last dragged position, nudged back on screen if the
        // display layout changed under it; fall back to bottom-right when
        // there's nothing saved and no screen to nudge onto.
        if let origin = savedOrigin, let safe = onScreenOrigin(origin) {
            panel.setFrameOrigin(safe)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 30, y: vf.minY + 10))
        }

        startMouseTracking()

        // Persist the position after a drag settles, so the pet comes back
        // where the user left it.
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

    deinit {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    // The window can't receive mouse-moved events while it's click-through
    // (ignoresMouseEvents == true), so watch the cursor globally and locally
    // and flip click-through on/off as it crosses the pet's visible pixels.
    private func startMouseTracking() {
        let events: NSEvent.EventTypeMask = [.mouseMoved]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.updateClickThrough()
        }) {
            mouseMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.updateClickThrough()
            return event
        }) {
            mouseMonitors.append(l)
        }
    }

    private func updateClickThrough() {
        guard enabled, panel.isVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        let winPoint = panel.convertPoint(fromScreen: screenPoint)
        let viewPoint = skView.convert(winPoint, from: nil)
        let scenePoint = skView.convert(viewPoint, to: scene)
        let interactive = scene.isInteractive(at: scenePoint)
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }

    // Slide a window origin the shortest distance that brings the pet's body
    // fully inside the visible frame of whichever screen it already overlaps
    // most (its own screen, when it's on one, so this is a no-op in the
    // normal case). Returns nil only when there are no screens at all.
    private func onScreenOrigin(_ origin: NSPoint) -> NSPoint? {
        let body = scene.bodyRect.offsetBy(dx: origin.x, dy: origin.y)
        let overlapping = NSScreen.screens
            .map { ($0, $0.visibleFrame.intersection(body)) }
            .filter { !$0.1.isEmpty }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
        guard let vf = (overlapping ?? NSScreen.main)?.visibleFrame else { return nil }
        // max(vf.minX, ...) keeps the clamp sane if the body ever outgrows
        // the screen: pinning the near edge beats an inverted range.
        let x = min(max(body.minX, vf.minX), max(vf.minX, vf.maxX - body.width))
        let y = min(max(body.minY, vf.minY), max(vf.minY, vf.maxY - body.height))
        return NSPoint(x: origin.x + x - body.minX, y: origin.y + y - body.minY)
    }

    // Adopt a position that came from outside the drag loop: a hand-edited
    // config.json, or a rescue after the pet has ended up somewhere
    // unreachable. Ignored mid-drag so it can't fight the mouse. Writing the
    // clamped result back to config is left to the usual didMove path.
    func setOrigin(_ origin: NSPoint) {
        guard !scene.isDragging, let safe = onScreenOrigin(origin),
              safe != panel.frame.origin else { return }
        panel.setFrameOrigin(safe)
    }

    static func stage(forXP xp: Int) -> Int {
        if xp >= 100 { return 2 }
        if xp >= 25 { return 1 }
        return 0
    }

    func setScale(_ scale: Double) {
        scene.setSizeScale(CGFloat(scale))
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
        scene.celebrate()
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
