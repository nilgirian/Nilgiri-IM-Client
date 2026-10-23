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

    var isServerLine: Bool { localID == nil }

    init(seq: Int64, at: Int64, kind: String, text: String, localID: String? = nil) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.text = text
        self.localID = localID
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
    }
}

enum DisconnectSeparator {
    /// `----------- Oct 23, 2026 17:14:32 --------`
    static func text(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, yyyy HH:mm:ss"
        let stamp = formatter.string(from: date)
        return String(repeating: "-", count: 11) + " " + stamp + " " + String(repeating: "-", count: 8)
    }
}

struct SinceResponse: Decodable {
    let closed: Bool
    let lines: [LineDTO]
}

struct ErrorResponse: Decodable {
    let error: String
}
