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
    /// Last HMV prompt. Kept across catch-up and relaunch until a newer prompt arrives.
    @Published private(set) var vitals: HMVPrompt.Vitals?
    @Published var lines: [LineDTO] = []
    @Published var status = "Parked on the IM server when this app is in the background."
    @Published var parked = false
    @Published var busy = false
    @Published var command = ""
    @Published private(set) var savedName = ""
    @Published private(set) var savedTokenAvailable = false
    /// Set before the resume or catch-up lines are published, and cleared only
    /// after the transcript finishes easing. While this is true the view must not
    /// snap to the bottom.
    @Published private(set) var pendingResumeReveal = false
    /// Id of the separator the transcript should park on before easing to the bottom.
    @Published private(set) var resumeSeparatorID: String?

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
    /// Prompt parsed from the batch currently being applied. Committed once.
    private var pendingVitals: HMVPrompt.Vitals?
    private let defaults = UserDefaults.standard

    private enum StoreKey {
        static let serverURL = "im.serverURL"
        static let name = "im.name"
        static let character = "im.character"
        static let lastSeq = "im.lastSeq"
        static let disconnectAt = "im.disconnectAt"
        static let disconnectSeq = "im.disconnectSeq"
        static let disconnectName = "im.disconnectName"
        /// Server `disconnectedAt` (epoch ms) saved for a gap that has no new line yet.
        static let disconnectServerMs = "im.disconnectServerMs"
        /// Last server instant already drawn, so a later poll of the same value does not
        /// add another separator.
        static let shownDisconnectMs = "im.shownDisconnectMs"
        /// "hp,mana,moves" for the character in `hmvName`.
        static let hmv = "im.hmv"
        static let hmvName = "im.hmvName"
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
        restoreVitals()
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
            cancelResumeReveal()
            lines = []
            lastSeq = 0
            token = nil
            sessionId = nil
            character = nil
            clearSessionSecrets()
            clearDisconnectMarker()
            clearShownDisconnect()
            defaults.set("0", forKey: StoreKey.lastSeq)
            defaults.removeObject(forKey: StoreKey.character)
            status = "Unlinked. The MUD session is closed."
        } else {
            persistAccount()
            await setParked(true)
            // Leave the Keychain pair in place so the next enter can resume.
            cancelResumeReveal()
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

    /// Fire-and-forget. Login, resume, and since also zero the counter.
    /// Older servers have no route and answer 404.
    func resetServerBadge() {
        guard token != nil, sessionId != nil else { return }
        Task { try? await post("/badge/reset", [:]) }
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
            adoptCharacter(login.character)
            parked = login.parked ?? false
            savedName = name
            // A brand-new session has nothing to split. Older servers omit both flags.
            let serverDisconnectedAt = login.resumed == false ? nil : login.disconnectedAt
            if login.resumed == false {
                clearDisconnectMarker()
                clearShownDisconnect()
                cancelResumeReveal()
            }
            if login.resumed == true && includeSince {
                append(login.lines ?? [], animatedScroll: true, serverDisconnectedAt: serverDisconnectedAt)
            } else {
                replaceTranscript(
                    login.lines ?? [],
                    animatedScroll: true,
                    serverDisconnectedAt: serverDisconnectedAt,
                    trustCursor: login.resumed != false && nameMatchesHeld()
                )
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
                    replaceTranscript(
                        since.lines,
                        animatedScroll: true,
                        serverDisconnectedAt: since.disconnectedAt
                    )
                } else {
                    append(since.lines, animatedScroll: true, serverDisconnectedAt: since.disconnectedAt)
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
        cancelResumeReveal()
        lines = []
        lastSeq = 0
        token = nil
        sessionId = nil
        character = nil
        clearSessionSecrets()
        clearDisconnectMarker()
        clearShownDisconnect()
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

    private func replaceTranscript(
        _ incoming: [LineDTO],
        animatedScroll: Bool = false,
        serverDisconnectedAt: Int64? = nil,
        trustCursor: Bool = true
    ) {
        // Another character's saved cursor is not a gap in this transcript.
        let seenSeq = trustCursor ? lastSeq : 0
        var shown: [LineDTO] = []
        var maxSeq: Int64 = 0
        for line in incoming {
            if line.seq > maxSeq {
                maxSeq = line.seq
            }
            guard let shownLine = presentable(line) else { continue }
            shown.append(shownLine)
        }
        commitVitals()
        lastSeq = maxSeq
        // Keep the newest window before the separator is placed, so a long
        // replace does not anchor the gap in lines that are about to be dropped.
        let window = shown.count > 4000 ? Array(shown.suffix(4000)) : shown
        publishLines(
            trimmed(applyingDisconnectSeparator(
                window,
                seenSeq: seenSeq,
                serverDisconnectedAt: serverDisconnectedAt
            )),
            animatedScroll: animatedScroll
        )
        persistCursor()
    }

    private func append(
        _ incoming: [LineDTO],
        animatedScroll: Bool = false,
        serverDisconnectedAt: Int64? = nil
    ) {
        let seenSeq = lastSeq
        var next = lines
        for line in incoming where line.seq > lastSeq {
            lastSeq = line.seq
            guard let shownLine = presentable(line) else { continue }
            next.append(shownLine)
        }
        commitVitals()
        publishLines(
            trimmed(applyingDisconnectSeparator(
                next,
                seenSeq: seenSeq,
                serverDisconnectedAt: serverDisconnectedAt
            )),
            animatedScroll: animatedScroll
        )
        persistCursor()
    }

    /// One assignment so the transcript lays out once, with the separator already
    /// in place. The pending flag is set first so that layout does not snap to
    /// the bottom before the reveal can run.
    private func publishLines(_ next: [LineDTO], animatedScroll: Bool) {
        guard next != lines else { return }
        if animatedScroll, let separatorID = revealSeparatorID(previous: lines, next: next),
           separatorID != resumeSeparatorID {
            resumeSeparatorID = separatorID
            pendingResumeReveal = true
        }
        lines = next
    }

    /// The transcript calls this after the ease to the bottom has finished.
    func finishResumeReveal(separatorID: String) {
        guard resumeSeparatorID == separatorID else { return }
        pendingResumeReveal = false
    }

    private func cancelResumeReveal() {
        guard pendingResumeReveal else { return }
        pendingResumeReveal = false
    }

    /// Separator that splits lines the user had seen from lines added in this update.
    /// A separator already revealed is returned too, and the caller skips it when
    /// its id matches `resumeSeparatorID`, so later catch-up does not replay the ease.
    private func revealSeparatorID(previous: [LineDTO], next: [LineDTO]) -> String? {
        let previousIDs = Set(previous.map(\.id))
        if let inserted = next.last(where: { $0.isSeparator && previousIDs.contains($0.id) == false }) {
            return inserted.id
        }
        guard let index = next.lastIndex(where: { $0.isSeparator }) else { return nil }
        let addedAfter = next.suffix(from: next.index(after: index)).contains {
            $0.isServerLine && previousIDs.contains($0.id) == false
        }
        guard addedAfter else { return nil }
        return next[index].id
    }

    /// First disconnect wins until a resume actually inserts the separator.
    /// The stamp prefers a later server `disconnectedAt`; this only freezes the
    /// device clock and the last seq the user had seen.
    private func noteDisconnect() {
        guard token != nil, sessionId != nil else { return }
        guard defaults.object(forKey: StoreKey.disconnectAt) == nil else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: StoreKey.disconnectAt)
        defaults.set(String(lastSeq), forKey: StoreKey.disconnectSeq)
        defaults.set(character ?? name, forKey: StoreKey.disconnectName)
        defaults.removeObject(forKey: StoreKey.disconnectServerMs)
    }

    private func clearDisconnectMarker() {
        defaults.removeObject(forKey: StoreKey.disconnectAt)
        defaults.removeObject(forKey: StoreKey.disconnectSeq)
        defaults.removeObject(forKey: StoreKey.disconnectName)
        defaults.removeObject(forKey: StoreKey.disconnectServerMs)
    }

    private func clearShownDisconnect() {
        defaults.removeObject(forKey: StoreKey.shownDisconnectMs)
    }

    private func shownDisconnectMs() -> Int64? {
        guard let raw = defaults.string(forKey: StoreKey.shownDisconnectMs),
              let ms = Int64(raw), ms > 0 else { return nil }
        return ms
    }

    private func storedServerDisconnectMs() -> Int64? {
        guard let raw = defaults.string(forKey: StoreKey.disconnectServerMs),
              let ms = Int64(raw), ms > 0 else { return nil }
        return ms
    }

    /// Remembers a server instant only when it is newer than the last separator drawn.
    private func stashServerDisconnect(_ reportedMs: Int64?) {
        guard let reportedMs, isNewerServerInstant(reportedMs) else { return }
        defaults.set(String(reportedMs), forKey: StoreKey.disconnectServerMs)
    }

    /// A missing record is older than any positive `disconnectedAt`.
    private func isNewerServerInstant(_ reportedMs: Int64) -> Bool {
        guard reportedMs > 0 else { return false }
        guard let shown = shownDisconnectMs() else { return true }
        return reportedMs > shown
    }

    /// Places one local separator after the last server line the user had already
    /// seen. A login or since `disconnectedAt` newer than the last separator is
    /// enough — the app does not also need to have watched the drop. The device
    /// clock is the fallback when the field is absent. The stamp is an absolute
    /// `Date`, formatted later in `TimeZone.current`. The separator is not a
    /// server seq, so `lastSeq` stays the since cursor.
    private func applyingDisconnectSeparator(
        _ source: [LineDTO],
        seenSeq: Int64 = 0,
        serverDisconnectedAt: Int64? = nil
    ) -> [LineDTO] {
        let reportedMs = serverDisconnectedAt.flatMap { $0 > 0 ? $0 : nil }
        if disconnectMarkerNameMismatch() {
            clearDisconnectMarker()
        }
        if defaults.object(forKey: StoreKey.disconnectAt) != nil {
            stashServerDisconnect(reportedMs)
        } else if let reportedMs, isNewerServerInstant(reportedMs), seenSeq > 0 {
            // Server restart or a drop this process never observed. Remember the
            // instant so a later line can still land under the same gap.
            defaults.set(Double(reportedMs) / 1000, forKey: StoreKey.disconnectAt)
            defaults.set(String(seenSeq), forKey: StoreKey.disconnectSeq)
            defaults.set(character ?? name, forKey: StoreKey.disconnectName)
            defaults.set(String(reportedMs), forKey: StoreKey.disconnectServerMs)
        }
        guard defaults.object(forKey: StoreKey.disconnectAt) != nil else { return source }
        let disconnectSeq = Int64(defaults.string(forKey: StoreKey.disconnectSeq) ?? "") ?? 0
        let hasNewLine = source.contains { $0.isServerLine && $0.seq > disconnectSeq }
        let hasAnchor = source.contains { $0.isServerLine && $0.seq <= disconnectSeq }
        // Device-only gaps wait for a line after the drop. A newer server instant
        // is drawn as soon as the lines the user had seen are on screen.
        if hasNewLine == false {
            guard storedServerDisconnectMs() != nil, hasAnchor else { return source }
        }
        // Both instants are absolute. The device clock is the fallback when the
        // server omits `disconnectedAt`. Display formats either one in TimeZone.current.
        let deviceDate = Date(timeIntervalSince1970: defaults.double(forKey: StoreKey.disconnectAt))
        let serverMs = storedServerDisconnectMs()
        let disconnected = serverMs.map(DisconnectSeparator.date(epochMilliseconds:)) ?? deviceDate
        let stamp = DisconnectSeparator.stamp(at: disconnected)
        var next = source
        let afterSeen = next.lastIndex(where: { $0.isServerLine && $0.seq <= disconnectSeq })
        let insertAt = afterSeen.map { $0 + 1 } ?? 0
        // One row for this gap. A separator already at the insert point, or the same
        // stamp already in the transcript, means the device clock and the server
        // instant must not each add a line.
        let alreadyShown = next.contains { $0.isSeparator && $0.text == stamp }
        if (next.indices.contains(insertAt) && next[insertAt].isSeparator) || alreadyShown {
            if let serverMs { defaults.set(String(serverMs), forKey: StoreKey.shownDisconnectMs) }
            clearDisconnectMarker()
            return next
        }
        let atMs = serverMs ?? Int64((disconnected.timeIntervalSince1970 * 1000.0).rounded())
        next.insert(
            LineDTO(
                seq: -1,
                at: atMs,
                kind: "separator",
                text: stamp,
                localID: "separator-\(disconnectSeq)-\(stamp)",
                disconnectAt: disconnected
            ),
            at: insertAt
        )
        if let serverMs { defaults.set(String(serverMs), forKey: StoreKey.shownDisconnectMs) }
        clearDisconnectMarker()
        return next
    }

    private func disconnectMarkerNameMismatch() -> Bool {
        guard defaults.object(forKey: StoreKey.disconnectAt) != nil else { return false }
        let heldName = defaults.string(forKey: StoreKey.disconnectName) ?? ""
        let currentName = character ?? name
        return heldName.isEmpty == false && namesEqual(heldName, currentName) == false
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

    /// Drops the color question and a line that is only an HMV prompt.
    /// A prompt fused with other text keeps that text. The newest prompt in
    /// the batch is remembered for the header.
    private func presentable(_ line: LineDTO) -> LineDTO? {
        guard shouldShow(line) else { return nil }
        let stripped = HMVPrompt.strip(line.text)
        if let found = stripped.vitals {
            pendingVitals = found
        }
        guard stripped.text.isEmpty == false else { return nil }
        guard stripped.text != line.text else { return line }
        return LineDTO(seq: line.seq, at: line.at, kind: line.kind, text: stripped.text)
    }

    private func commitVitals() {
        guard let found = pendingVitals else { return }
        pendingVitals = nil
        guard vitals != found else { return }
        vitals = found
        defaults.set(found.stored, forKey: StoreKey.hmv)
        let owner = character ?? name
        if owner.isEmpty == false {
            defaults.set(owner, forKey: StoreKey.hmvName)
        }
    }

    private func restoreVitals() {
        guard let raw = defaults.string(forKey: StoreKey.hmv),
              let held = defaults.string(forKey: StoreKey.hmvName),
              let found = HMVPrompt.Vitals.parse(raw) else { return }
        let owner = character ?? name
        guard owner.isEmpty == false, namesEqual(held, owner) else { return }
        vitals = found
    }

    /// Another character's saved prompt is not this header.
    private func adoptCharacter(_ next: String?) {
        character = next
        guard let next, next.isEmpty == false else { return }
        guard let held = defaults.string(forKey: StoreKey.hmvName),
              namesEqual(held, next) == false else { return }
        vitals = nil
        defaults.removeObject(forKey: StoreKey.hmv)
        defaults.removeObject(forKey: StoreKey.hmvName)
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
