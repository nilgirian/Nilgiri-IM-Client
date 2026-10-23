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
}

struct ErrorResponse: Decodable {
    let error: String
}
