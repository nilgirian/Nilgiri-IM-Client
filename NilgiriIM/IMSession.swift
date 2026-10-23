import Foundation
import Combine
import UIKit

@MainActor
final class IMSession: ObservableObject {
    @Published var serverURL = "https://nilgiri.net/im"
    @Published var name = ""
    @Published var password = ""
    @Published var token: String?
    @Published var sessionId: String?
    @Published var character: String?
    @Published var lines: [LineDTO] = []
    @Published var status = "Parked on the IM server when this app is in the background."
    @Published var parked = false
    @Published var busy = false
    @Published var command = ""
    @Published private(set) var savedName = ""
    @Published private(set) var savedTokenAvailable = false
    /// Bumped when a resume or catch-up backlog lands. Live lines leave it alone
    /// so the transcript can animate that scroll without animating every line.
    @Published private(set) var backlogScrollToken = 0

    private var lastSeq: Int64 = 0
    private var pollTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var didRestore = false
    private var didAutoLogin = false
    private var desiredParked = false
    private var parkApplying = false
    private var lastParkOK = true
    private var pendingUnpark = false
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private let defaults = UserDefaults.standard

    private enum StoreKey {
        static let serverURL = "im.serverURL"
        static let name = "im.name"
        static let character = "im.character"
        static let lastSeq = "im.lastSeq"
        static let disconnectAt = "im.disconnectAt"
        static let disconnectSeq = "im.disconnectSeq"
        static let disconnectName = "im.disconnectName"
    }

    private enum ResumeOutcome {
        case ready
        case rejected
        case closed
        case offline
    }

    private struct HTTPFailure: Error {
        let status: Int
        let message: String
    }

    init() {
        if let storedURL = defaults.string(forKey: StoreKey.serverURL), storedURL.isEmpty == false {
            serverURL = storedURL
        }
        if let storedName = defaults.string(forKey: StoreKey.name), storedName.isEmpty == false {
            name = storedName
            savedName = storedName
        }
        if let storedCharacter = defaults.string(forKey: StoreKey.character), storedCharacter.isEmpty == false {
            character = storedCharacter
        }
        if let rawSeq = defaults.string(forKey: StoreKey.lastSeq), let seq = Int64(rawSeq) {
            lastSeq = seq
        }
        if let storedPassword = SessionSecrets.get(SessionSecrets.Account.password) {
            password = storedPassword
        }
        token = SessionSecrets.get(SessionSecrets.Account.token)
        sessionId = SessionSecrets.get(SessionSecrets.Account.sessionId)
        savedTokenAvailable = token != nil && sessionId != nil
    }

    /// True when Enter should try the saved bearer token before posting a login.
    var offersResume: Bool {
        guard savedTokenAvailable || (token != nil && sessionId != nil) else { return false }
        let storedURL = defaults.string(forKey: StoreKey.serverURL) ?? ""
        if storedURL.isEmpty == false, normalized(serverURL) != normalized(storedURL) {
            return false
        }
        if savedName.isEmpty { return false }
        if namesEqual(name, savedName) { return true }
        if let character, namesEqual(name, character) { return true }
        return false
    }

    func restoreOnLaunch() async {
        guard didRestore == false else { return }
        didRestore = true
        guard token != nil, sessionId != nil else { return }
        busy = true
        status = "Resuming parked session…"
        defer { busy = false }
        switch await resumeDirect() {
        case .ready:
            break
        case .offline:
            pendingUnpark = true
            status = "Could not reach the IM server. The parked session is still saved."
            startLive()
        case .closed:
            await dropClosedSession()
        case .rejected:
            token = nil
            await autoPasswordLogin()
        }
    }

    func login() async {
        busy = true
        defer { busy = false }
        if offersResume {
            hydrateSavedSession()
            switch await resumeDirect() {
            case .ready:
                return
            case .offline:
                pendingUnpark = true
                status = "Could not reach the IM server. The parked session is still saved."
                startLive()
                return
            case .closed:
                await dropClosedSession()
                return
            case .rejected:
                token = nil
            }
        }
        await passwordLogin()
    }

    func send() async {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }
        command = ""
        do {
            try await post("/input", ["text": text])
        } catch {
            status = failureMessage(error)
        }
    }

    @discardableResult
    func park(_ value: Bool) async -> Bool {
        parked = value
        if value {
            noteDisconnect()
        }
        if token != nil, sessionId != nil {
            persistAccount()
        }
        do {
            try await post("/park", ["parked": value])
            status = value
                ? "Parked. Tells, death, combat start, idle, and link loss can notify."
                : "Live. Full transcript while the app is open."
            return true
        } catch {
            status = failureMessage(error)
            return false
        }
    }

    func registerDevice(token hex: String, environment: String) async {
        do {
            try await post("/device", ["token": hex, "environment": environment])
        } catch {
            status = failureMessage(error)
        }
    }

    func logout(closeMud: Bool) async {
        stopLive()
        if closeMud {
            do {
                try await post("/close", [:])
            } catch {
                status = failureMessage(error)
                return
            }
            lines = []
            lastSeq = 0
            token = nil
            sessionId = nil
            character = nil
            clearSessionSecrets()
            clearDisconnectMarker()
            defaults.set("0", forKey: StoreKey.lastSeq)
            defaults.removeObject(forKey: StoreKey.character)
            status = "Unlinked. The MUD session is closed."
        } else {
            persistAccount()
            await setParked(true)
            // Leave the Keychain pair in place so the next enter can resume.
            token = nil
            status = "Parked. Resume keeps this character where they are."
        }
    }

    /// Resume clears park on the server, so backgrounding has to park again.
    func sceneWentBackground() async {
        noteDisconnect()
        persistAccount()
        stopLive()
        guard token != nil, sessionId != nil else { return }
        await setParked(true)
    }

    func sceneBecameActive() async {
        guard token != nil, sessionId != nil else { return }
        await setParked(false)
        if desiredParked == false {
            if lastParkOK {
                pendingUnpark = false
            }
            startLive()
        }
    }

    func catchUp() async {
        guard token != nil, sessionId != nil else { return }
        switch await fetchSince() {
        case .ready:
            didAutoLogin = false
            if pendingUnpark && inForeground && desiredParked == false {
                await setParked(false)
                if lastParkOK && desiredParked == false {
                    pendingUnpark = false
                }
            }
        case .offline:
            break
        case .closed:
            stopLive()
            await dropClosedSession()
        case .rejected:
            stopLive()
            token = nil
            await autoPasswordLogin()
        }
    }

    private func passwordLogin() async {
        guard name.isEmpty == false else { return }
        guard password.isEmpty == false else {
            token = nil
            status = "Enter the password to reattach the parked character."
            return
        }
        // Block the catch-up poller from firing another login while this one is in flight.
        didAutoLogin = true
        let sameCharacter = nameMatchesHeld()
        let includeSince = sameCharacter && lines.isEmpty == false && lastSeq > 0
        var body: [String: Any] = ["name": name, "password": password, "color": true]
        if includeSince {
            body["since"] = NSNumber(value: lastSeq)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            var req = URLRequest(url: url("/v1/login"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                status = "Login failed."
                return
            }
            if http.statusCode == 401 {
                // Wrong password leaves the parked session alone. Do not close it.
                status = (try? JSONDecoder().decode(ErrorResponse.self, from: respData))?.error
                    ?? "Login failed (401)"
                stopLive()
                token = nil
                return
            }
            if http.statusCode != 200 {
                status = (try? JSONDecoder().decode(ErrorResponse.self, from: respData))?.error
                    ?? "Login failed (\(http.statusCode))"
                token = nil
                return
            }
            let login = try JSONDecoder().decode(LoginResponse.self, from: respData)
            token = login.token
            sessionId = login.sessionId
            character = login.character
            parked = login.parked ?? false
            savedName = name
            if login.resumed == false {
                clearDisconnectMarker()
            }
            if login.resumed == true && includeSince {
                append(login.lines ?? [], animatedScroll: true)
            } else {
                replaceTranscript(login.lines ?? [], animatedScroll: true)
                if includeSince && lines.isEmpty {
                    lastSeq = 0
                    persistCursor()
                }
            }
            persistAccount()
            let announcement = login.resumed == true
                ? "Resumed \(login.character)."
                : "Playing as \(login.character)"
            await settleAfterResume(announcement: announcement)
        } catch {
            status = failureMessage(error)
        }
    }

    /// Bearer token never expires. Prefer GET since, then unpark, before logging in again.
    private func resumeDirect() async -> ResumeOutcome {
        let outcome = await fetchSince()
        guard outcome == .ready else { return outcome }
        let announcement = character.map { "Resumed \($0)." } ?? "Resumed parked session."
        await settleAfterResume(announcement: announcement)
        return .ready
    }

    private func fetchSince() async -> ResumeOutcome {
        guard let token else { return .rejected }
        let seq = lines.isEmpty ? Int64(0) : lastSeq
        guard let requestURL = sessionURL("/since/\(seq)") else { return .rejected }
        var req = URLRequest(url: requestURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .offline }
            switch http.statusCode {
            case 200:
                guard let since = try? JSONDecoder().decode(SinceResponse.self, from: data) else {
                    return .offline
                }
                if lines.isEmpty {
                    replaceTranscript(since.lines, animatedScroll: true)
                } else {
                    append(since.lines, animatedScroll: true)
                }
                if since.closed { return .closed }
                return .ready
            case 401, 403, 404:
                return .rejected
            default:
                return .offline
            }
        } catch {
            return .offline
        }
    }

    /// Login reattach and a successful token resume both clear park.
    /// In the background that has to be put back; in front, go live.
    /// The event stream does not replay the buffer, so since has already run.
    private func settleAfterResume(announcement: String) async {
        persistAccount()
        let foreground = inForeground
        pendingUnpark = foreground == false
        await setParked(foreground ? false : true)
        guard desiredParked == false else { return }
        if lastParkOK {
            status = announcement
            pendingUnpark = false
        } else {
            pendingUnpark = true
        }
        startLive()
        await PushRegistration.flush(session: self)
    }

    /// One automatic re-login per failed resume. A ready since arms it again.
    private func autoPasswordLogin() async {
        guard didAutoLogin == false else {
            token = nil
            status = "Could not reattach the parked session."
            return
        }
        await passwordLogin()
    }

    /// Keeps the last park request aligned with the latest foreground or background.
    private func setParked(_ value: Bool) async {
        desiredParked = value
        if parkApplying {
            await withCheckedContinuation { continuation in
                parkWaiters.append(continuation)
            }
            return
        }
        parkApplying = true
        while token != nil, sessionId != nil {
            let target = desiredParked
            lastParkOK = await park(target)
            if desiredParked == target {
                break
            }
        }
        parkApplying = false
        let waiters = parkWaiters
        parkWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func dropClosedSession() async {
        lines = []
        lastSeq = 0
        token = nil
        sessionId = nil
        character = nil
        clearSessionSecrets()
        clearDisconnectMarker()
        defaults.set("0", forKey: StoreKey.lastSeq)
        defaults.removeObject(forKey: StoreKey.character)
        if password.isEmpty == false && name.isEmpty == false {
            await autoPasswordLogin()
        } else {
            status = "MUD session closed (idle, unlink, or logout)."
        }
    }

    private func hydrateSavedSession() {
        if token == nil {
            token = SessionSecrets.get(SessionSecrets.Account.token)
        }
        if sessionId == nil {
            sessionId = SessionSecrets.get(SessionSecrets.Account.sessionId)
        }
    }

    private func persistAccount() {
        if let token, token.isEmpty == false {
            SessionSecrets.set(token, account: SessionSecrets.Account.token)
        }
        if let sessionId, sessionId.isEmpty == false {
            SessionSecrets.set(sessionId, account: SessionSecrets.Account.sessionId)
        }
        if password.isEmpty == false {
            SessionSecrets.set(password, account: SessionSecrets.Account.password)
        }
        defaults.set(serverURL, forKey: StoreKey.serverURL)
        if name.isEmpty == false {
            defaults.set(name, forKey: StoreKey.name)
            savedName = name
        }
        if let character, character.isEmpty == false {
            defaults.set(character, forKey: StoreKey.character)
        }
        persistCursor()
        savedTokenAvailable = SessionSecrets.get(SessionSecrets.Account.token) != nil
            && SessionSecrets.get(SessionSecrets.Account.sessionId) != nil
    }

    private func persistCursor() {
        defaults.set(String(lastSeq), forKey: StoreKey.lastSeq)
    }

    private func clearSessionSecrets() {
        SessionSecrets.set(nil, account: SessionSecrets.Account.token)
        SessionSecrets.set(nil, account: SessionSecrets.Account.sessionId)
        savedTokenAvailable = false
    }

    private func startLive() {
        stopLive()
        streamTask = Task { await stream() }
        pollTask = Task {
            while Task.isCancelled == false {
                await catchUp()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopLive() {
        streamTask?.cancel()
        pollTask?.cancel()
        streamTask = nil
        pollTask = nil
    }

    private func stream() async {
        guard let token, let requestURL = sessionURL("/stream") else { return }
        var req = URLRequest(url: requestURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                if line.hasPrefix("data: ") {
                    let payload = String(line.dropFirst(6))
                    if let data = payload.data(using: .utf8),
                       let dto = try? JSONDecoder().decode(LineDTO.self, from: data) {
                        append([dto])
                    }
                }
            }
            if Task.isCancelled == false {
                noteDisconnect()
                status = "Live stream dropped; polling catch-up."
            }
        } catch {
            if Task.isCancelled { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            noteDisconnect()
            status = "Live stream dropped; polling catch-up."
        }
    }

    private func replaceTranscript(_ incoming: [LineDTO], animatedScroll: Bool = false) {
        var shown: [LineDTO] = []
        var maxSeq: Int64 = 0
        for line in incoming {
            if line.seq > maxSeq {
                maxSeq = line.seq
            }
            guard shouldShow(line) else { continue }
            shown.append(line)
        }
        lastSeq = maxSeq
        // Keep the newest window before the separator is placed, so a long
        // replace does not anchor the gap in lines that are about to be dropped.
        let window = shown.count > 4000 ? Array(shown.suffix(4000)) : shown
        publishLines(trimmed(applyingDisconnectSeparator(window)), animatedScroll: animatedScroll)
        persistCursor()
    }

    private func append(_ incoming: [LineDTO], animatedScroll: Bool = false) {
        var next = lines
        for line in incoming where line.seq > lastSeq {
            lastSeq = line.seq
            guard shouldShow(line) else { continue }
            next.append(line)
        }
        publishLines(trimmed(applyingDisconnectSeparator(next)), animatedScroll: animatedScroll)
        persistCursor()
    }

    /// One assignment so SwiftUI scrolls once, after the separator is in place.
    /// The token is bumped first so that scroll sees the resume and animates.
    private func publishLines(_ next: [LineDTO], animatedScroll: Bool) {
        guard next != lines else { return }
        if animatedScroll {
            backlogScrollToken += 1
        }
        lines = next
    }

    /// First disconnect wins until a resume actually inserts the separator.
    private func noteDisconnect() {
        guard token != nil, sessionId != nil else { return }
        guard defaults.object(forKey: StoreKey.disconnectAt) == nil else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: StoreKey.disconnectAt)
        defaults.set(String(lastSeq), forKey: StoreKey.disconnectSeq)
        defaults.set(character ?? name, forKey: StoreKey.disconnectName)
    }

    private func clearDisconnectMarker() {
        defaults.removeObject(forKey: StoreKey.disconnectAt)
        defaults.removeObject(forKey: StoreKey.disconnectSeq)
        defaults.removeObject(forKey: StoreKey.disconnectName)
    }

    /// Places a local separator after the last server line the user had already
    /// seen. The separator is not a server seq, so `lastSeq` stays the since cursor.
    private func applyingDisconnectSeparator(_ source: [LineDTO]) -> [LineDTO] {
        guard defaults.object(forKey: StoreKey.disconnectAt) != nil else { return source }
        let heldName = defaults.string(forKey: StoreKey.disconnectName) ?? ""
        let currentName = character ?? name
        if heldName.isEmpty == false, namesEqual(heldName, currentName) == false {
            clearDisconnectMarker()
            return source
        }
        let disconnectSeq = Int64(defaults.string(forKey: StoreKey.disconnectSeq) ?? "") ?? 0
        let hasNewLine = source.contains { $0.isServerLine && $0.seq > disconnectSeq }
        guard hasNewLine else { return source }
        let text = DisconnectSeparator.text(
            at: Date(timeIntervalSince1970: defaults.double(forKey: StoreKey.disconnectAt))
        )
        var next = source
        let afterSeen = next.lastIndex(where: { $0.isServerLine && $0.seq <= disconnectSeq })
        let insertAt = afterSeen.map { $0 + 1 } ?? 0
        if next.indices.contains(insertAt), next[insertAt].kind == "separator" {
            clearDisconnectMarker()
            return next
        }
        if next.contains(where: { $0.kind == "separator" && $0.text == text }) {
            clearDisconnectMarker()
            return next
        }
        next.insert(
            LineDTO(
                seq: -1,
                at: 0,
                kind: "separator",
                text: text,
                localID: "separator-\(disconnectSeq)-\(text)"
            ),
            at: insertAt
        )
        clearDisconnectMarker()
        return next
    }

    private func trimmed(_ source: [LineDTO]) -> [LineDTO] {
        var copy = source
        while copy.count > 4000 {
            guard let index = copy.firstIndex(where: { $0.isServerLine }) else { break }
            copy.remove(at: index)
        }
        return copy
    }

    private func shouldShow(_ line: LineDTO) -> Bool {
        line.text.contains("Do you want text color") == false
    }

    private func post(_ action: String, _ body: [String: Any]) async throws {
        guard let requestURL = sessionURL(action) else {
            throw HTTPFailure(status: 0, message: "No session to update.")
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HTTPFailure(status: 0, message: "No response from the IM server.")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
                ?? "Request failed (\(http.statusCode))"
            throw HTTPFailure(status: http.statusCode, message: message)
        }
    }

    private func sessionURL(_ suffix: String) -> URL? {
        guard let sessionId, sessionId.isEmpty == false else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let escaped = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionId
        return url("/v1/sessions/\(escaped)\(suffix)")
    }

    private func url(_ path: String) -> URL {
        URL(string: normalized(serverURL) + path)!
    }

    private func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func nameMatchesHeld() -> Bool {
        if savedName.isEmpty == false && namesEqual(name, savedName) { return true }
        if let character, namesEqual(name, character) { return true }
        return false
    }

    private func namesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private var inForeground: Bool {
        UIApplication.shared.applicationState != .background
    }

    private func failureMessage(_ error: Error) -> String {
        if let http = error as? HTTPFailure {
            return http.message
        }
        return error.localizedDescription
    }
}
