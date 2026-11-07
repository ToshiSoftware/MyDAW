import Foundation

/// The piano roll's rows for a drum instrument: the hits grouped by drum,
/// instead of one row per pitch. Only the display order changes; the notes
/// keep their numbers. A folded drum is one row holding all its notes. Pitches
/// of the clip that are no hit of the kit get rows at the end, so that every
/// note stays visible.
struct DrumRollLayout {
    struct Group {
        let id: String
        let name: String
        let firstRow: Int
        let rowCount: Int
        let isFolded: Bool
    }

    struct Row {
        let group: Int
        /// The hit; on a folded drum, its first hit (a new note lands there).
        let pitch: Int
        let name: String
        let isVariation: Bool
    }

    static let otherGroupID = "other"

    let groups: [Group]
    let rows: [Row]
    /// What the layout was made from, to tell whether it is still right.
    let folded: Set<String>
    let otherPitches: [Int]

    private let drums: [DrumMap.Drum]
    private let rowOfPitch: [Int]
    private let hitNames: [String?]
    private let drumOfPitch: [Int]

    init(drums: [DrumMap.Drum], folded: Set<String>, otherPitches: [Int], otherName: String,
         noteName: (Int) -> String) {
        self.drums = drums
        self.folded = folded
        self.otherPitches = otherPitches
        var groups: [Group] = []
        var rows: [Row] = []
        var rowOfPitch = [Int](repeating: -1, count: 128)
        var hitNames = [String?](repeating: nil, count: 128)
        var drumOfPitch = [Int](repeating: -1, count: 128)

        func add(id: String, name: String, hits: [(note: Int, name: String, isVariation: Bool)]) {
            guard let first = hits.first else { return }
            let isFolded = folded.contains(id)
            groups.append(Group(id: id, name: name, firstRow: rows.count, rowCount: isFolded ? 1 : hits.count, isFolded: isFolded))
            for hit in hits where hit.note >= 0 && hit.note < 128 {
                rowOfPitch[hit.note] = rows.count + (isFolded ? 0 : hits.firstIndex { $0.note == hit.note } ?? 0)
                hitNames[hit.note] = hit.name
            }
            if isFolded {
                rows.append(Row(group: groups.count - 1, pitch: first.note, name: first.name, isVariation: first.isVariation))
            } else {
                rows += hits.map { Row(group: groups.count - 1, pitch: $0.note, name: $0.name, isVariation: $0.isVariation) }
            }
        }

        for (index, drum) in drums.enumerated() {
            for hit in drum.hits where hit.note >= 0 && hit.note < 128 { drumOfPitch[hit.note] = index }
            add(id: drum.id, name: drum.name, hits: drum.hits.map { ($0.note, $0.name, $0.isVariation) })
        }
        add(id: Self.otherGroupID, name: otherName, hits: otherPitches.map { ($0, noteName($0), false) })
        self.groups = groups
        self.rows = rows
        self.rowOfPitch = rowOfPitch
        self.hitNames = hitNames
        self.drumOfPitch = drumOfPitch
    }

    /// The clip's pitches that are no hit of the kit, highest first.
    static func otherPitches(of pitches: Set<Int>, drums: [DrumMap.Drum]) -> [Int] {
        let mapped = Set(drums.flatMap { $0.hits.map(\.note) })
        return pitches.subtracting(mapped).sorted(by: >)
    }

    /// Its row; a pitch without one (only for a moment, until the layout is
    /// remade) is shown on the last row.
    func row(ofPitch pitch: Int) -> Int {
        guard rowOfPitch.indices.contains(pitch), rowOfPitch[pitch] >= 0 else { return max(0, rows.count - 1) }
        return rowOfPitch[pitch]
    }

    func hitName(ofPitch pitch: Int) -> String? {
        hitNames.indices.contains(pitch) ? hitNames[pitch] : nil
    }

    /// "HiHat Closed Tip": the name that says what a note plays.
    func fullName(ofPitch pitch: Int) -> String? {
        guard let hit = hitName(ofPitch: pitch) else { return nil }
        guard drumOfPitch[pitch] >= 0 else { return hit }
        return "\(drums[drumOfPitch[pitch]].name) \(hit)"
    }

    /// The next way of striking the same drum; nil at the drum's end and for
    /// a pitch that is no hit of the kit. With `crossesDrums`, the drum's end
    /// leads on to the nearest way of striking of the next drum along.
    func variation(from pitch: Int, step: Int, crossesDrums: Bool = false) -> Int? {
        guard drumOfPitch.indices.contains(pitch), drumOfPitch[pitch] >= 0 else { return nil }
        if let same = drums[drumOfPitch[pitch]].variation(from: pitch, step: step) { return same }
        guard crossesDrums, step != 0 else { return nil }
        var index = drumOfPitch[pitch] + (step > 0 ? 1 : -1)
        while drums.indices.contains(index) {
            let hits = drums[index].hits.filter(\.isVariation)
            if let hit = step > 0 ? hits.first : hits.last { return hit.note }
            index += step > 0 ? 1 : -1
        }
        return nil
    }
}
