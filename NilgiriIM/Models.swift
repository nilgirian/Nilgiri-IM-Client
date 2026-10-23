import Foundation

struct LoginResponse: Decodable {
    let token: String
    let sessionId: String
    let character: String
    let lines: [LineDTO]?
    /// True when this login reattached a session that was already open.
    let resumed: Bool?
    /// False after a successful reattach; the server clears park on resume.
    let parked: Bool?
    /// Epoch milliseconds when the server dropped the session. Older servers omit it.
    let disconnectedAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case token, sessionId, character, lines, resumed, parked, disconnectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        character = try container.decode(String.self, forKey: .character)
        lines = try container.decodeIfPresent([LineDTO].self, forKey: .lines)
        resumed = try container.decodeIfPresent(Bool.self, forKey: .resumed)
        parked = try container.decodeIfPresent(Bool.self, forKey: .parked)
        disconnectedAt = EpochMillis.decodeIfPresent(container, forKey: .disconnectedAt)
    }
}

struct LineDTO: Decodable, Identifiable, Equatable {
    /// Server lines use their seq. Local separators use `localID` so they do not
    /// collide with a server seq or move the since cursor.
    var id: String { localID ?? String(seq) }
    let seq: Int64
    let at: Int64
    let kind: String
    let text: String
    var localID: String?
    /// Set only for a local disconnect separator. Server lines leave this nil.
    var disconnectAt: Date?

    var isServerLine: Bool { localID == nil }
    var isSeparator: Bool { kind == "separator" }

    init(seq: Int64, at: Int64, kind: String, text: String, localID: String? = nil, disconnectAt: Date? = nil) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.text = text
        self.localID = localID
        self.disconnectAt = disconnectAt
    }

    private enum CodingKeys: String, CodingKey {
        case seq, at, kind, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int64.self, forKey: .seq)
        at = try container.decode(Int64.self, forKey: .at)
        kind = try container.decode(String.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        localID = nil
        disconnectAt = nil
    }
}

enum DisconnectSeparator {
    /// Absolute instant from server epoch milliseconds. `Date` has no zone;
    /// `stamp(at:)` is what places it on the device clock.
    static func date(epochMilliseconds ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// `Oct 23, 2026 17:14:32` — en_US_POSIX, 24-hour, no dashes.
    /// Always the device zone (`TimeZone.current`) and that zone's gregorian calendar.
    /// No zone identifier is hardcoded, and the server's zone is never consulted.
    /// The zone is applied after the POSIX locale: that locale otherwise formats in GMT.
    static func stamp(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d, yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct SinceResponse: Decodable {
    let closed: Bool
    let lines: [LineDTO]
    /// Epoch milliseconds when the server dropped the session. Later polls omit it.
    let disconnectedAt: Int64?
    /// True when a restarted server restored the session but it is not attached yet.
    /// Later polls omit it. A real close leaves it out.
    let resumed: Bool?

    private enum CodingKeys: String, CodingKey {
        case closed, lines, disconnectedAt, resumed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        closed = try container.decode(Bool.self, forKey: .closed)
        lines = try container.decode([LineDTO].self, forKey: .lines)
        disconnectedAt = EpochMillis.decodeIfPresent(container, forKey: .disconnectedAt)
        resumed = try container.decodeIfPresent(Bool.self, forKey: .resumed)
    }
}

/// `disconnectedAt` is epoch milliseconds. Servers send an integer, sometimes a
/// JSON number that decodes as a double, and older servers leave the field out.
enum EpochMillis {
    static func decodeIfPresent<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Int64? {
        guard container.contains(key) else { return nil }
        if (try? container.decodeNil(forKey: key)) == true { return nil }
        if let ms = try? container.decode(Int64.self, forKey: key) {
            return ms > 0 ? ms : nil
        }
        if let ms = try? container.decode(Double.self, forKey: key), ms.isFinite {
            let rounded = ms.rounded()
            // Reject values Double cannot round into Int64. A too-large conversion traps.
            guard rounded > 0, rounded < Double(Int64.max) else { return nil }
            return Int64(rounded)
        }
        return nil
    }
}

struct ErrorResponse: Decodable {
    let error: String
}

/// The MUD status prompt, for example `<30h 100m 97v>` or `<30h 100m 97v fighting>`.
/// Real sessions put that token on its own line or fused with the text around it,
/// including after a carriage-return redraw. ANSI around the token is ignored.
/// A prompt cut in half across two server lines is not reassembled here.
enum HMVPrompt {
    struct Vitals: Equatable {
        var hp: Int
        var mana: Int
        var moves: Int

        var label: String { "\(hp)h \(mana)m \(moves)v" }

        var stored: String { "\(hp),\(mana),\(moves)" }

        static func parse(_ raw: String) -> Vitals? {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let hp = Int(parts[0]), hp >= 0,
                  let mana = Int(parts[1]), mana >= 0,
                  let moves = Int(parts[2]), moves >= 0 else { return nil }
            return Vitals(hp: hp, mana: mana, moves: moves)
        }
    }

    /// Removes every prompt from `raw`. The last one supplies the vitals.
    /// Leftover text is trimmed; an empty result means the line was only a prompt.
    static func strip(_ raw: String) -> (text: String, vitals: Vitals?) {
        let (plain, map) = strippingANSI(raw)
        let ns = plain as NSString
        let matches = promptExpression.matches(in: plain, range: NSRange(location: 0, length: ns.length))
        guard matches.isEmpty == false else { return (raw, nil) }
        var vitals: Vitals?
        var removals: [Range<String.Index>] = []
        for match in matches {
            guard match.numberOfRanges >= 4,
                  let hpRange = Range(match.range(at: 1), in: plain),
                  let manaRange = Range(match.range(at: 2), in: plain),
                  let movesRange = Range(match.range(at: 3), in: plain),
                  let whole = Range(match.range, in: plain),
                  let hp = Int(plain[hpRange]),
                  let mana = Int(plain[manaRange]),
                  let moves = Int(plain[movesRange]),
                  let original = originalRange(of: whole, in: plain, map: map, raw: raw) else { continue }
            vitals = Vitals(hp: hp, mana: mana, moves: moves)
            removals.append(original)
        }
        guard removals.isEmpty == false else { return (raw, vitals) }
        let holes = merged(removals.map { eatingHorizontalSpace($0, in: raw) })
        var text = ""
        var cursor = raw.startIndex
        for hole in holes {
            if cursor < hole.lowerBound {
                append(raw[cursor..<hole.lowerBound], to: &text)
            }
            cursor = max(cursor, hole.upperBound)
        }
        if cursor < raw.endIndex {
            append(raw[cursor...], to: &text)
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let (remainder, _) = strippingANSI(trimmed)
        if remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("", vitals)
        }
        return (trimmed, vitals)
    }

    /// Pulls in spaces next to the prompt so `<30h 100m 97v>` between two words
    /// leaves one space, and a prompt-only line leaves nothing.
    private static func eatingHorizontalSpace(
        _ range: Range<String.Index>,
        in raw: String
    ) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower > raw.startIndex {
            let previous = raw.index(before: lower)
            if raw[previous] == " " || raw[previous] == "\t" {
                lower = previous
            } else {
                break
            }
        }
        while upper < raw.endIndex, raw[upper] == " " || raw[upper] == "\t" {
            upper = raw.index(after: upper)
        }
        return lower..<upper
    }

    /// One space when a prompt sat between two words. Newlines stay put.
    private static func append(_ chunk: Substring, to text: inout String) {
        guard chunk.isEmpty == false else { return }
        let boundary = { (character: Character) in
            character == " " || character == "\t" || character.isNewline
        }
        if text.isEmpty == false,
           let last = text.last, boundary(last) == false,
           let first = chunk.first, boundary(first) == false {
            text.append(" ")
        }
        text.append(contentsOf: chunk)
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<String.Index>] = []
        for range in ordered {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if last.upperBound >= range.lowerBound {
                let upper = max(last.upperBound, range.upperBound)
                result[result.count - 1] = last.lowerBound..<upper
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `<30h 100m 97v>`, spaces optional around the brackets, extra fields allowed
    /// before `>` (`fighting`, and anything else that is not another bracket).
    private static let promptExpression: NSRegularExpression = {
        let pattern = #"<\s*(\d+)h\s+(\d+)m\s+(\d+)v([^<>]*)>"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Plain text plus the original index of each plain character.
    private static func strippingANSI(_ raw: String) -> (String, [String.Index]) {
        var plain = ""
        var map: [String.Index] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(after: index)
            if raw[index] == "\u{001B}", next < raw.endIndex, raw[next] == "[" {
                var cursor = raw.index(after: next)
                while cursor < raw.endIndex {
                    let character = raw[cursor]
                    cursor = raw.index(after: cursor)
                    if character.isLetter { break }
                }
                index = cursor
                continue
            }
            plain.append(raw[index])
            map.append(index)
            index = raw.index(after: index)
        }
        return (plain, map)
    }

    /// Maps a range of `plain` back onto `raw`, including any ANSI that sat
    /// between those characters.
    private static func originalRange(
        of plainRange: Range<String.Index>,
        in plain: String,
        map: [String.Index],
        raw: String
    ) -> Range<String.Index>? {
        let start = plain.distance(from: plain.startIndex, to: plainRange.lowerBound)
        let end = plain.distance(from: plain.startIndex, to: plainRange.upperBound)
        guard start >= 0, end > start, end <= map.count else { return nil }
        let lower = map[start]
        let upper = raw.index(after: map[end - 1])
        return lower..<upper
    }
}
