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

/// Why the IM host could not serve this attempt.
/// `proxy` is the machine in front (unreachable, or Apache 502/503).
/// `server` is the MUD itself (`503` and `{"error":"mud_unavailable"}`).
/// Character creation `busy`, `mud_timeout`, `504`, and a `502` whose error
/// mentions timeout are not this dialog. Those stay on the creation form.
enum OutageKind: Equatable {
    case proxy
    case server

    private struct Body: Decodable {
        let error: String?
        let message: String?
    }

    var message: String {
        switch self {
        case .proxy:
            return "Nilgiri proxy is currently unavailable."
        case .server:
            return "Nilgiri server is currently unavailable."
        }
    }

    /// `503` with `mud_unavailable` is the MUD. Any other `502` or `503` is Apache
    /// with the IM server down. A `502` that already carries `mud_unavailable`
    /// is not relabeled as the proxy.
    /// `503` `busy`, `504`, `mud_timeout`, and a `502` whose error contains
    /// "timeout" are creation-form errors, not this alert.
    static func http(status: Int, data: Data) -> OutageKind? {
        let error = body(from: data)?.error
        if error == "mud_unavailable" {
            return status == 503 ? .server : nil
        }
        if isCreationFormFailure(status: status, error: error) {
            return nil
        }
        if status == 502 || status == 503 {
            return .proxy
        }
        return nil
    }

    /// Copy for the creation form. Nil when this response is a real outage.
    /// `busy` is app copy. A timeout uses the server's `message` when it sent one.
    static func creationFormMessage(status: Int, data: Data) -> String? {
        let parsed = body(from: data)
        let error = parsed?.error ?? ""
        guard isCreationFormFailure(status: status, error: parsed?.error) else { return nil }
        if status == 503 && error == "busy" {
            return "Character creation is busy. Try again in a moment."
        }
        let serverMessage = parsed?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if serverMessage.isEmpty == false {
            return serverMessage
        }
        if status == 502 && error.localizedCaseInsensitiveContains("timeout") && error != "mud_timeout" {
            return error
        }
        return "Nilgiri did not answer in time."
    }

    /// `503` `{"error":"busy"}`, `504`, `mud_timeout`, or `502` with "timeout" in the error.
    private static func isCreationFormFailure(status: Int, error: String?) -> Bool {
        let error = error ?? ""
        if status == 503 && error == "busy" { return true }
        if status == 504 || error == "mud_timeout" { return true }
        if status == 502 && error.localizedCaseInsensitiveContains("timeout") { return true }
        return false
    }

    private static func body(from data: Data) -> Body? {
        guard data.isEmpty == false else { return nil }
        return try? JSONDecoder().decode(Body.self, from: data)
    }

    /// DNS, connection refused, timeout, and TLS failures. Other URL errors,
    /// including no network and cancellation, are not this dialog.
    static func transport(_ error: Error) -> OutageKind? {
        guard let code = (error as? URLError)?.code else { return nil }
        switch code {
        case .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .timedOut,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return .proxy
        default:
            return nil
        }
    }
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
    /// Spaces and tabs that follow the prompt are removed with it. ANSI next to
    /// the `>` is left in place, so a reset still applies to the text after it.
    /// Everything else, including a newline or the leading spaces of the next
    /// line, stays byte for byte. An empty result means the line was only a prompt.
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
            removals.append(contentsOf: trailingSeparators(after: original.upperBound, in: raw))
        }
        guard removals.isEmpty == false else { return (raw, vitals) }
        let holes = merged(removals)
        var text = ""
        var cursor = raw.startIndex
        for hole in holes {
            if cursor < hole.lowerBound {
                text.append(contentsOf: raw[cursor..<hole.lowerBound])
            }
            cursor = max(cursor, hole.upperBound)
        }
        if cursor < raw.endIndex {
            text.append(contentsOf: raw[cursor...])
        }
        if text.isEmpty { return ("", vitals) }
        let (remainder, _) = strippingANSI(text)
        let visible = remainder.contains { $0.isNewline == false && $0 != " " && $0 != "\t" }
        if visible { return (text, vitals) }
        // Prompt plus its separator, or only a color code. A newline is a blank line.
        if remainder.contains(where: \.isNewline) { return (text, vitals) }
        return ("", vitals)
    }

    /// Spaces and tabs after the prompt. Color codes between `>` and those
    /// spaces are skipped, not deleted, and a newline stops the scan so the
    /// next line's own indent is left alone.
    private static func trailingSeparators(
        after start: String.Index,
        in raw: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = start
        while index < raw.endIndex {
            if raw[index] == " " || raw[index] == "\t" {
                let begin = index
                while index < raw.endIndex, raw[index] == " " || raw[index] == "\t" {
                    index = raw.index(after: index)
                }
                ranges.append(begin..<index)
                continue
            }
            if let afterCode = endOfCSI(raw, from: index) {
                index = afterCode
                continue
            }
            break
        }
        return ranges
    }

    /// The index just after a CSI sequence starting at `index`, if one is there.
    private static func endOfCSI(_ raw: String, from index: String.Index) -> String.Index? {
        guard raw[index] == "\u{001B}" else { return nil }
        let bracket = raw.index(after: index)
        guard bracket < raw.endIndex, raw[bracket] == "[" else { return nil }
        var cursor = raw.index(after: bracket)
        while cursor < raw.endIndex {
            let character = raw[cursor]
            cursor = raw.index(after: cursor)
            if character.isLetter { return cursor }
        }
        return cursor
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

/// One screen in `POST /v1/create`. `info` is either a string of lines or an
/// array of lines. `options` are strings or `{value, label}` objects.
/// A confirm step with no options is answered with yes/no.
struct CreateStep: Decodable {
    let kind: String
    let label: String
    let info: [String]
    let options: [CreateOption]
    var error: String?
    let email: String?

    private enum CodingKeys: String, CodingKey {
        case kind, label, info, options, error, email
    }

    var normalizedKind: String {
        kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isPassword: Bool { normalizedKind == "password" }
    var isText: Bool { normalizedKind == "text" }
    var isConfirm: Bool { normalizedKind == "confirm" }

    /// Radios for this step. Confirm synthesizes yes/no when the server sends none.
    var choices: [CreateOption] {
        if options.isEmpty, isConfirm {
            return [
                CreateOption(value: "yes", label: "yes"),
                CreateOption(value: "no", label: "no")
            ]
        }
        return options
    }

    /// Changes when the question changes. An `error` update does not, so a
    /// rejected password keeps what the player typed.
    var signature: String {
        let values = options.map(\.value).joined(separator: "\u{1e}")
        return "\(normalizedKind)\u{1e}\(label)\u{1e}\(values)"
    }

    /// Dialog title. The address on the step wins; the address from the form is the fallback.
    func passwordPrompt(fallbackEmail: String) -> String {
        let fromStep = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = fromStep.isEmpty
            ? fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            : fromStep
        return "Please enter the password sent to \(address)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        guard kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "missing kind"
            )
        }
        self.kind = kind
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        info = Self.decodeInfo(container)
        options = Self.decodeOptions(container)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        email = try container.decodeIfPresent(String.self, forKey: .email)
    }

    static func decodeJSON(_ object: Any) -> CreateStep? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(CreateStep.self, from: data)
    }

    private static func decodeInfo(_ container: KeyedDecodingContainer<CodingKeys>) -> [String] {
        if let lines = try? container.decode([String].self, forKey: .info) {
            return lines
        }
        if let text = try? container.decode(String.self, forKey: .info) {
            return splitLines(text)
        }
        return []
    }

    private static func decodeOptions(_ container: KeyedDecodingContainer<CodingKeys>) -> [CreateOption] {
        (try? container.decode([CreateOption].self, forKey: .options)) ?? []
    }

    /// Splits on LF or CRLF and drops a trailing empty piece from a final newline.
    /// Spaces inside a line stay. `\r\n` is one Swift grapheme, so this walks scalars.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                    index = scalars.index(after: next)
                } else {
                    index = next
                }
                lines.append(current)
                current = ""
                continue
            }
            current.unicodeScalars.append(scalar)
            index = next
        }
        lines.append(current)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}

struct CreateOption: Decodable {
    var value: String
    var label: String

    private enum CodingKeys: String, CodingKey {
        case value, label, text
    }

    init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            value = text
            label = text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(String.self, forKey: .value)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let resolvedValue = value ?? text ?? label ?? ""
        let resolvedLabel = label ?? text ?? value ?? ""
        guard resolvedValue.isEmpty == false || resolvedLabel.isEmpty == false else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "empty option")
            )
        }
        self.value = resolvedValue.isEmpty ? resolvedLabel : resolvedValue
        self.label = resolvedLabel.isEmpty ? self.value : resolvedLabel
    }
}
