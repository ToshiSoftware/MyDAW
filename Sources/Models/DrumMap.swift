import AudioToolbox
import Foundation

/// How a drum instrument's keys are grouped in the piano roll, from a JSON
/// file in ~/Documents/MyDAW/DrumMaps. MyDAW ships no maps: without one for
/// the track's instrument, the piano roll shows plain keys.
struct DrumMap: Codable, Equatable {
    struct Hit: Codable, Equatable {
        let note: Int
        let name: String
        /// False for a note that is not another way of striking: the same
        /// sound as another note, or a choke.
        let isVariation: Bool

        init(note: Int, name: String, isVariation: Bool = true) {
            self.note = note
            self.name = name
            self.isVariation = isVariation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            note = try container.decode(Int.self, forKey: .note)
            name = try container.decode(String.self, forKey: .name)
            isVariation = try container.decodeIfPresent(Bool.self, forKey: .isVariation) ?? true
        }
    }

    struct Drum: Codable, Equatable {
        let id: String
        let name: String
        let hits: [Hit]

        /// The next way of striking from `note`, going `step` hits along
        /// (negative: towards the start). Nil at the drum's end.
        func variation(from note: Int, step: Int) -> Int? {
            guard step != 0, var index = hits.firstIndex(where: { $0.note == note }) else { return nil }
            var remaining = abs(step)
            var found: Int?
            while remaining > 0 {
                index += step > 0 ? 1 : -1
                guard hits.indices.contains(index) else { break }
                if hits[index].isVariation {
                    found = hits[index].note
                    remaining -= 1
                }
            }
            return found
        }
    }

    /// Four-character codes of the Audio Unit the map belongs to.
    let subtype: String
    let manufacturer: String
    let drums: [Drum]
    /// Optional: for output bus n + 1, the address of the parameter holding
    /// its pan, so its channel starts where the sound was in the main mix.
    let outputBusPanAddresses: [UInt64]?

    private static func fourCC(_ text: String) -> OSType? {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/MyDAW/DrumMaps", isDirectory: true)

    /// Every readable map, read once per launch.
    private static let all: [DrumMap] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }.compactMap { file in
            do {
                return try JSONDecoder().decode(DrumMap.self, from: Data(contentsOf: file))
            } catch {
                print("Drum map \(file.lastPathComponent): \(error)")
                return nil
            }
        }
    }()

    static func map(subtype: OSType, manufacturer: OSType) -> DrumMap? {
        all.first { fourCC($0.subtype) == subtype && fourCC($0.manufacturer) == manufacturer }
    }
}
