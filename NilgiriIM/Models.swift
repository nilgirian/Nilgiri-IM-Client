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
    /// `Oct 23, 2026 17:14:32` — en_US_POSIX, 24-hour, device timezone. No dashes.
    static func stamp(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct SinceResponse: Decodable {
    let closed: Bool
    let lines: [LineDTO]
    /// Epoch milliseconds when the server dropped the session. Older servers omit it.
    let disconnectedAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case closed, lines, disconnectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        closed = try container.decode(Bool.self, forKey: .closed)
        lines = try container.decode([LineDTO].self, forKey: .lines)
        disconnectedAt = EpochMillis.decodeIfPresent(container, forKey: .disconnectedAt)
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
