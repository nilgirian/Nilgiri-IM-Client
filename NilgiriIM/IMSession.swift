import Foundation
import Combine
import UIKit
import UserNotifications

@MainActor
final class IMSession: ObservableObject {
    /// Always the public IM host. A URL saved by an older build is removed and never read.
    let serverURL = "https://nilgiri.net/im"
    @Published var name = ""
    @Published var password = ""
    @Published var token: String?
    @Published var sessionId: String?
    @Published var character: String?
    /// Last HMV prompt. Kept across catch-up and relaunch until a newer prompt arrives.
    @Published private(set) var vitals: HMVPrompt.Vitals?
    @Published var lines: [LineDTO] = []
    @Published var status = "Parked on the IM server when this app is in the background."
    /// Set for one login, resume, reconnect, or creation attempt. Nil hides the alert.
    @Published var outageAlert: OutageKind?
    /// After the first alert, since polling stays quiet until a new attempt or a success.
    private var outageLatched = false
    /// Retry dismisses the alert before the new attempt finishes. That dismiss must
    /// not clear an alert the attempt just raised.
    private var suppressOutageDismiss = false
    /// What Retry repeats. Login and resume stay on the parked session.
    /// Creation retries the form, the last answer, or the abort DELETE.
    private enum OutageFollowUp {
        case login
        case create
        case answer(String)
        case delete(String)
    }
    private var outageFollowUp: OutageFollowUp = .login
    @Published var parked = false
    @Published var busy = false
    @Published var command = ""
    /// True while the welcome menu is up. Login, creation, since, and the
    /// stream's `: {"menu":true|false}` comments all write this. The panel
    /// sends 0 or 1; the server answers PRESS RETURN itself.
    @Published private(set) var atMenu = false
    /// A menu choice is in flight. The panel ignores a second tap.
    @Published private(set) var menuBusy = false
    /// Quit, or parking on the menu, is leaving for good.
    /// A close that arrives after the menu flag drops must not log in again.
    private var menuExit = false
    /// Set when login failed because this name is not a character yet.
    @Published var characterMissing = false
    /// Name/email form, then the creation wizard. The account is not written
    /// until the server returns a login body. An open creation id is stored
    /// so a killed app can drop the draft.
    @Published var creating = false
    @Published var createName = ""
    @Published var createEmail = ""
    @Published var createError: String?
    /// ANSI greeting for the creation wizard. Shown as sent, not as a transcript line.
    @Published var createGreeting: String?
    @Published var createStep: CreateStep?
    /// Bumped for every decoded step so the wizard resets its fields, including a reroll.
    @Published private(set) var createStepSerial = 0
    /// One section per server step whose info was copied, in arrival order.
    /// Password-step info is included. The password itself is never in that text.
    /// The line strings are unchanged. Rules between sections are view chrome.
    @Published var createLog: [CreateLogSection] = []
    @Published var createBusy = false
    /// Open creation. Also stored under the UserDefaults key `createCID` so the
    /// next launch can drop a draft the app did not get to cancel.
    private var createCID: String?
    /// The password just submitted. Stored only after the login body arrives.
    private var createPassword: String?
    /// Bumped on cancel and on an ended creation so a late response is ignored.
    private var createGeneration = 0
    /// Info lines of the last step copied into `createLog`. An error re-send
    /// of that same block is not copied again.
    private var createLogBlock: [String]?
    @Published private(set) var savedName = ""
    /// True after the app writes `name` (restore, or the name taken after creation)
    /// until the user edits Name to something else. LoginView must not clear Password
    /// for the app's write.
    private(set) var suppressNameClear = false
    /// `name` stored with `suppressNameClear`.
    private var nameAssignedByApp: String?
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
    /// When the scene last became active. The resume instant for a disconnect
    /// that happened before that return.
    private var foregroundedAt: Date?
    /// A disconnect-to-resume gap shorter than this is not marked.
    private static let minimumDisconnectGap: TimeInterval = 60
    private let defaults = UserDefaults.standard

    private enum StoreKey {
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
        /// Draft id while creation is open. Cleared on finish and on cancel.
        static let createCID = "createCID"
    }

    private enum ResumeOutcome: Equatable {
        case ready
        case rejected
        case closed
        case offline
        /// Proxy or MUD outage. The stored token and session id stay.
        case outage(OutageKind)
        /// Since applied a restored session that is not attached yet (`closed` and `resumed`).
        /// Login follows. The transcript and the divider stay.
        case detached
    }

    private struct HTTPFailure: Error {
        let status: Int
        let message: String
    }

    init() {
        defaults.removeObject(forKey: "im.serverURL")
        if let storedName = defaults.string(forKey: StoreKey.name), storedName.isEmpty == false {
            assignNameFromApp(storedName)
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

    /// Restore and the name taken after creation. Login must not clear Password for this write.
    private func assignNameFromApp(_ value: String) {
        nameAssignedByApp = value
        suppressNameClear = true
        name = value
    }

    /// True when `newName` is the app's own write and Password must stay.
    /// A user edit to a different name returns false and drops the marker.
    func acknowledgeNameWrite(_ newName: String) -> Bool {
        guard suppressNameClear else { return false }
        if nameAssignedByApp == newName {
            return true
        }
        suppressNameClear = false
        nameAssignedByApp = nil
        return false
    }

    /// True when Enter should try the saved bearer token before posting a login.
    var offersResume: Bool {
        guard savedTokenAvailable || (token != nil && sessionId != nil) else { return false }
        if savedName.isEmpty { return false }
        if namesEqual(name, savedName) { return true }
        if let character, namesEqual(name, character) { return true }
        return false
    }

    func restoreOnLaunch() async {
        guard didRestore == false else { return }
        didRestore = true
        discardOrphanedCreation()
        guard token != nil, sessionId != nil else { return }
        busy = true
        status = "Resuming parked session…"
        defer { busy = false }
        outageLatched = false
        switch await resumeDirect() {
        case .ready:
            break
        case .offline:
            pendingUnpark = true
            status = "Could not reach the IM server. The parked session is still saved."
            startLive()
        case .outage(let kind):
            holdSessionThroughOutage(kind)
        case .closed:
            await handleClosedSession()
        case .detached:
            // since already inserted the divider. Login reattaches; it must not clear it.
            await autoPasswordLogin()
        case .rejected:
            await handleRejectedSession(thenLogin: true)
        }
    }

    func login() async {
        menuExit = false
        busy = true
        characterMissing = false
        defer { busy = false }
        outageLatched = false
        outageFollowUp = .login
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
            case .outage(let kind):
                holdSessionThroughOutage(kind)
                return
            case .closed:
                await handleClosedSession()
                return
            case .detached:
                break
            case .rejected:
                if await handleRejectedSession(thenLogin: false) { return }
            }
        }
        await passwordLogin()
    }

    /// OK on the outage alert. The token and session id stay so a later retry can resume.
    func acknowledgeOutage() {
        if suppressOutageDismiss {
            suppressOutageDismiss = false
            return
        }
        outageAlert = nil
    }

    /// Retry repeats the request that failed. A stored bearer resumes.
    /// Create retries the form. A step retries the last answer. An abort retries DELETE.
    func retryOutage() async {
        suppressOutageDismiss = true
        let followUp = outageFollowUp
        outageAlert = nil
        outageLatched = false
        switch followUp {
        case .login:
            await login()
        case .create:
            await startCharacterCreation()
        case .answer(let value):
            await answerCharacterCreation(value)
        case .delete(let cid):
            await performDeleteCreation(cid)
        }
        // A dismiss of the alert Retry just closed can arrive after the new
        // attempt has raised another one. Leave the flag set so that dismiss
        // does not clear the new alert. If this attempt raised nothing, drop it.
        if outageAlert == nil {
            suppressOutageDismiss = false
        }
    }

    /// Opens the name and email form. The name is left blank; the saved character is not copied in.
    func openCharacterCreation() {
        createGeneration += 1
        setCreateCID(nil)
        createPassword = nil
        createGreeting = nil
        createStep = nil
        createError = nil
        createBusy = false
        resetCreateLog()
        createName = ""
        createEmail = ""
        characterMissing = false
        creating = true
    }

    func startCharacterCreation() async {
        let trimmedName = createName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = createEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false, trimmedEmail.isEmpty == false, createBusy == false else { return }
        let generation = createGeneration
        createBusy = true
        createError = nil
        defer { createBusy = false }
        do {
            let http = try await createSend(
                method: "POST",
                path: "/v1/create",
                json: ["name": trimmedName, "email": trimmedEmail]
            )
            guard generation == createGeneration else {
                abortLateCreation(http.data)
                return
            }
            if let message = OutageKind.creationFormMessage(status: http.status, data: http.data) {
                presentCreationInlineError(message, phase: .start)
                return
            }
            if let kind = OutageKind.http(status: http.status, data: http.data) {
                reportOutage(kind, retry: .create)
                return
            }
            await handleCreateHTTP(http, phase: .start, generation: generation)
        } catch {
            guard generation == createGeneration else { return }
            if let kind = OutageKind.transport(error) {
                reportOutage(kind, retry: .create)
                return
            }
            presentCreateFailure(failureMessage(error), phase: .start)
        }
    }

    func answerCharacterCreation(_ value: String) async {
        guard let cid = createCID, createBusy == false else { return }
        guard value.isEmpty == false else { return }
        if createStep?.isPassword == true {
            createPassword = value
        }
        let generation = createGeneration
        createBusy = true
        defer { createBusy = false }
        do {
            let http = try await createSend(
                method: "POST",
                path: "/v1/create/\(pathComponent(cid))/answer",
                json: ["value": value]
            )
            guard generation == createGeneration else {
                abortLateCreation(http.data)
                return
            }
            if let message = OutageKind.creationFormMessage(status: http.status, data: http.data) {
                presentCreationInlineError(message, phase: .answer)
                return
            }
            if let kind = OutageKind.http(status: http.status, data: http.data) {
                reportOutage(kind, retry: .answer(value))
                return
            }
            await handleCreateHTTP(http, phase: .answer, generation: generation)
        } catch {
            guard generation == createGeneration else { return }
            if let kind = OutageKind.transport(error) {
                reportOutage(kind, retry: .answer(value))
                return
            }
            presentCreateFailure(failureMessage(error), phase: .answer)
        }
    }

    /// Cancel, the creation screen leaving, or the app backgrounding before the
    /// password step. DELETE is fire-and-forget. The password step stays up:
    /// the player has to switch away to read the email.
    func cancelCharacterCreation() {
        let cid = createCID
        createGeneration += 1
        clearCreationMemory()
        status = "Character creation cancelled."
        if let cid {
            deleteCreation(cid)
        }
    }

    /// Safety net when the wizard view goes away while a creation is still open.
    func abandonCharacterCreationIfNeeded() {
        guard createCID != nil else { return }
        cancelCharacterCreation()
    }

    func send() async {
        // The welcome menu is the panel. A typed line would answer it.
        guard atMenu == false else { return }
        menuExit = false
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }
        command = ""
        do {
            let data = try await post("/input", ["text": text])
            noteMenuFlag(data)
        } catch {
            status = failureMessage(error)
        }
    }

    /// Welcome-menu choice. `1` enters the game. `0` quits and unlinks.
    /// Change-password is the dialog, not choice `2`.
    /// The server answers PRESS RETURN itself; this does not send a blank line.
    func chooseMenu(_ choice: String) async {
        guard atMenu, menuBusy == false else { return }
        guard choice == "0" || choice == "1" else { return }
        menuBusy = true
        if choice == "0" {
            menuExit = true
        } else {
            menuExit = false
        }
        defer { menuBusy = false }
        do {
            let data = try await post("/input", ["text": choice])
            // A since poll may have already dropped this menu session.
            guard token != nil else { return }
            if responseClosed(data) {
                finishMenuUnlink()
                return
            }
            noteMenuFlag(data)
            if choice == "0", atMenu {
                menuExit = false
            }
        } catch {
            if choice == "0", token != nil {
                menuExit = false
            }
            if token != nil {
                status = failureMessage(error)
            }
        }
    }

    /// `POST /v1/sessions/{id}/password` with `{current, new}` while the menu is up.
    /// Nil means the password was stored. Any other string is shown as-is when it
    /// is the game's own sentence, or a short message for 400/409/502/504.
    /// The passwords are never written to the status line or a log.
    func changePassword(current: String, new newPassword: String) async -> String? {
        if current.isEmpty || newPassword.isEmpty {
            return "Enter the current and new password."
        }
        do {
            let data = try await post("/password", ["current": current, "new": newPassword])
            let object = jsonObject(data) ?? [:]
            if boolValue(object, "ok") == true {
                password = newPassword
                SessionSecrets.set(newPassword, account: SessionSecrets.Account.password)
                status = "Password changed."
                return nil
            }
            if let sentence = object["error"] as? String, sentence.isEmpty == false {
                return sentence
            }
            return "Could not change the password."
        } catch let failure as HTTPFailure {
            return passwordFailureMessage(status: failure.status, serverMessage: failure.message)
        } catch {
            return "Could not change the password."
        }
    }

    @discardableResult
    func park(_ value: Bool) async -> Bool {
        let closingMenu = value && atMenu
        parked = value
        if value, closingMenu == false {
            noteDisconnect()
        }
        // A menu park is about to drop the session. Leave the Keychain token
        // unset so a kill during the request cannot resume it.
        if token != nil, sessionId != nil, closingMenu == false {
            persistAccount()
        }
        do {
            let data = try await post("/park", ["parked": value])
            // Unlink during this request already returned to the login screen.
            guard token != nil else { return true }
            // Parking on the menu sends choice 0 and answers {"closed":true}.
            if responseClosed(data) {
                finishMenuUnlink()
                return true
            }
            if closingMenu {
                menuExit = false
            }
            noteMenuFlag(data)
            status = value
                ? "Parked. Tells, death, combat start, idle, and link loss can notify."
                : "Live. Full transcript while the app is open."
            return true
        } catch {
            if token == nil {
                return true
            }
            if closingMenu {
                menuExit = false
            }
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
            atMenu = false
            menuBusy = false
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
    /// Backgrounding on the welcome menu unlinks: the server answers choice 0
    /// with {"closed":true}, and that drops the Keychain session.
    func sceneWentBackground() async {
        let closingMenu = atMenu
        if closingMenu == false {
            noteDisconnect()
        }
        persistAccount()
        if closingMenu {
            menuExit = true
            clearSessionSecrets()
        }
        stopLive()
        guard token != nil, sessionId != nil else { return }
        await setParked(true)
    }

    func sceneBecameActive() async {
        foregroundedAt = Date()
        guard token != nil, sessionId != nil else { return }
        // Returning to the app is one reconnect attempt, not a poll tick.
        outageLatched = false
        await setParked(false)
        // A menu park may have closed the session while this was waiting.
        guard token != nil, sessionId != nil else { return }
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
            outageLatched = false
            outageAlert = nil
            if pendingUnpark && inForeground && desiredParked == false {
                await setParked(false)
                if lastParkOK && desiredParked == false {
                    pendingUnpark = false
                }
            }
        case .offline:
            break
        case .outage(let kind):
            // The repeating since poll must not raise the dialog again.
            if outageLatched == false {
                reportOutage(kind)
            }
        case .closed:
            stopLive()
            await handleClosedSession()
        case .detached:
            // A login is already reattaching this restore. Don't drop the bearer.
            guard didAutoLogin == false else { return }
            stopLive()
            await autoPasswordLogin()
        case .rejected:
            stopLive()
            await handleRejectedSession(thenLogin: true)
        }
    }

    private func passwordLogin() async {
        characterMissing = false
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
            if let kind = OutageKind.http(status: http.statusCode, data: respData) {
                // Leave the Keychain pair in place. Retry resumes it.
                // This was not a rejected login, so the one automatic re-login stays armed.
                didAutoLogin = false
                reportOutage(kind)
                return
            }
            if http.statusCode == 401 {
                // Wrong password leaves the parked session alone. Do not close it.
                status = (try? JSONDecoder().decode(ErrorResponse.self, from: respData))?.error
                    ?? "Login failed (401)"
                characterMissing = Self.indicatesMissingCharacter(status)
                atMenu = false
                menuBusy = false
                stopLive()
                token = nil
                return
            }
            if http.statusCode != 200 {
                status = (try? JSONDecoder().decode(ErrorResponse.self, from: respData))?.error
                    ?? "Login failed (\(http.statusCode))"
                characterMissing = Self.indicatesMissingCharacter(status) || http.statusCode == 404
                atMenu = false
                menuBusy = false
                token = nil
                return
            }
            let login = try JSONDecoder().decode(LoginResponse.self, from: respData)
            let switching = isDifferentCharacter(login.character)
            if switching {
                resetPreviousCharacterMemory()
            }
            token = login.token
            sessionId = login.sessionId
            adoptCharacter(login.character)
            parked = login.parked ?? false
            savedName = name
            // A fresh login stops on the menu. A resumed reattach is linkdead:
            // stay in the game unless the server still says menu.
            applyArrivedMenu(
                menu: login.menu,
                state: login.state,
                whenAbsent: login.resumed == true ? .playing : .menu
            )
            // A brand-new session has nothing to split. Older servers omit both flags.
            // A live reattach is resumed with no disconnectedAt: the device-clock
            // marker is the fallback. A restored login repeats the since value;
            // that instant is already shown, so it must not add a second row.
            let serverDisconnectedAt = login.resumed == false ? nil : login.disconnectedAt
            if login.resumed == false {
                clearDisconnectMarker()
                clearShownDisconnect()
                cancelResumeReveal()
            }
            if switching == false && login.resumed == true && includeSince {
                append(login.lines ?? [], animatedScroll: true, serverDisconnectedAt: serverDisconnectedAt)
            } else {
                replaceTranscript(
                    login.lines ?? [],
                    animatedScroll: true,
                    serverDisconnectedAt: serverDisconnectedAt,
                    trustCursor: switching == false && login.resumed != false && nameMatchesHeld()
                )
                if includeSince && lines.isEmpty {
                    lastSeq = 0
                    persistCursor()
                }
            }
            persistAccount()
            if switching {
                resetServerBadge()
            }
            await settleAfterResume(announcement: arrivalAnnouncement(login.character, resumed: login.resumed))
        } catch {
            if let kind = OutageKind.transport(error) {
                didAutoLogin = false
                reportOutage(kind)
                return
            }
            status = failureMessage(error)
        }
    }

    /// Bearer token never expires. Prefer GET since, then unpark, before logging in again.
    /// A detached restore (`closed` with `resumed`) has already placed the divider.
    /// The caller logs in next and must not wipe that transcript.
    private func resumeDirect() async -> ResumeOutcome {
        let outcome = await fetchSince()
        guard outcome == .ready else { return outcome }
        // Linkdead resume is already in the game. A session left on the menu
        // shows the panel and does not send 1.
        let announcement: String
        if atMenu, let character, character.isEmpty == false {
            announcement = "At the menu as \(character)."
        } else {
            announcement = character.map { "Resumed \($0)." } ?? "Resumed parked session."
        }
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
            // Menu unlink clears the token. A late since must not log in again.
            guard self.token != nil else { return .offline }
            guard let http = resp as? HTTPURLResponse else { return .offline }
            switch http.statusCode {
            case 200:
                guard let since = try? JSONDecoder().decode(SinceResponse.self, from: data) else {
                    return .offline
                }
                // Apply lines and disconnectedAt before looking at closed.
                // A restored session's first since is closed and resumed, and
                // that response is what places the divider.
                if lines.isEmpty {
                    replaceTranscript(
                        since.lines,
                        animatedScroll: true,
                        serverDisconnectedAt: since.disconnectedAt
                    )
                } else {
                    append(since.lines, animatedScroll: true, serverDisconnectedAt: since.disconnectedAt)
                }
                applyArrivedMenu(menu: since.menu, state: since.state, whenAbsent: .keep)
                if since.closed {
                    if since.resumed == true {
                        return .detached
                    }
                    return .closed
                }
                return .ready
            case 401, 403, 404:
                return .rejected
            default:
                if let kind = OutageKind.http(status: http.statusCode, data: data) {
                    return .outage(kind)
                }
                return .offline
            }
        } catch {
            if let kind = OutageKind.transport(error) {
                return .outage(kind)
            }
            return .offline
        }
    }

    /// Shows the outage alert once for this attempt and does not drop the bearer.
    private func holdSessionThroughOutage(_ kind: OutageKind) {
        reportOutage(kind)
        pendingUnpark = true
        startLive()
    }

    /// Login, resume, reconnect, and character creation share this.
    /// Since polling calls it only while `outageLatched` is false.
    /// `retry` is recorded only when this call is the one that shows the alert.
    private func reportOutage(_ kind: OutageKind, retry: OutageFollowUp = .login) {
        outageLatched = true
        status = kind.message
        guard outageAlert == nil else { return }
        outageFollowUp = retry
        outageAlert = kind
    }

    /// Login reattach and a successful token resume both clear park.
    /// In the background that has to be put back; in front, go live.
    /// The event stream does not replay the buffer, so since has already run.
    private func settleAfterResume(announcement: String) async {
        outageLatched = false
        outageAlert = nil
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
        atMenu = false
        menuBusy = false
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
                if Task.isCancelled || self.token == nil { return }
                if line.hasPrefix("data: ") {
                    let payload = String(line.dropFirst(6))
                    if let data = payload.data(using: .utf8),
                       let dto = try? JSONDecoder().decode(LineDTO.self, from: data) {
                        append([dto])
                    }
                    continue
                }
                // Comment lines carry the menu flag only. Game text stays on data lines.
                // The server answers PRESS RETURN; this client does not send it.
                if line.hasPrefix(":") {
                    applyMenuComment(line)
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
    /// seen, when the disconnect-to-resume gap is at least 60 seconds. A long
    /// resume with no backlog draws it at the end of the transcript. A long
    /// resume with backlog draws it between the last line already seen and the
    /// new lines. A shorter return draws nothing and drops the marker, so a
    /// later poll does not add the row once the clock passes 60 seconds. The
    /// device clock is the fallback when the server omits `disconnectedAt`.
    /// The same gap is not drawn twice (`alreadyShown`, and `shownDisconnectMs`
    /// for a server instant). The stamp is an absolute `Date`, formatted later
    /// in `TimeZone.current`. The separator is not a server seq, so `lastSeq`
    /// stays the since cursor.
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
            // A separator already stored for this seq is that gap drawn from the
            // device clock while the since body had no backlog. Do not add another.
            let drewThisSeq = source.contains {
                $0.localID?.hasPrefix("separator-\(seenSeq)-") == true
            }
            if drewThisSeq == false {
                defaults.set(Double(reportedMs) / 1000, forKey: StoreKey.disconnectAt)
                defaults.set(String(seenSeq), forKey: StoreKey.disconnectSeq)
                defaults.set(character ?? name, forKey: StoreKey.disconnectName)
                defaults.set(String(reportedMs), forKey: StoreKey.disconnectServerMs)
            }
        }
        guard defaults.object(forKey: StoreKey.disconnectAt) != nil else { return source }
        let disconnectSeq = Int64(defaults.string(forKey: StoreKey.disconnectSeq) ?? "") ?? 0
        // Both instants are absolute. The device clock is the fallback when the
        // server omits `disconnectedAt`. Display formats either one in TimeZone.current.
        let deviceDate = Date(timeIntervalSince1970: defaults.double(forKey: StoreKey.disconnectAt))
        let serverMs = storedServerDisconnectMs()
        let disconnected = serverMs.map(DisconnectSeparator.date(epochMilliseconds:)) ?? deviceDate
        // Prefer the foreground return when it is after this drop, so a slow
        // since does not stretch a short resume past 60 seconds. A drop while
        // already in front is measured to this call.
        let resumeAt: Date
        if let foregroundedAt, foregroundedAt >= disconnected {
            resumeAt = foregroundedAt
        } else {
            resumeAt = Date()
        }
        if resumeAt.timeIntervalSince(disconnected) < Self.minimumDisconnectGap {
            if inForeground {
                let resumeMs = Int64((resumeAt.timeIntervalSince1970 * 1000.0).rounded())
                let atMs = serverMs ?? Int64((disconnected.timeIntervalSince1970 * 1000.0).rounded())
                defaults.set(String(max(atMs, resumeMs)), forKey: StoreKey.shownDisconnectMs)
                clearDisconnectMarker()
            }
            return source
        }
        let stamp = DisconnectSeparator.stamp(at: disconnected)
        var next = source
        let afterSeen = next.lastIndex(where: { $0.isServerLine && $0.seq <= disconnectSeq })
        var insertAt = afterSeen.map { $0 + 1 } ?? 0
        // Separators already on this boundary are earlier pauses with no server
        // line between them. A later resume still gets its own row after those.
        // The same stamp is the same gap and is not drawn again.
        while next.indices.contains(insertAt), next[insertAt].isSeparator, next[insertAt].text != stamp {
            insertAt += 1
        }
        let alreadyShown = next.contains { $0.isSeparator && $0.text == stamp }
        if alreadyShown {
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
        defaults.set(String(atMs), forKey: StoreKey.shownDisconnectMs)
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

    @discardableResult
    private func post(_ action: String, _ body: [String: Any]) async throws -> Data {
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
        return data
    }

    /// Where a login or since body left the character when `menu` and `state` are absent.
    private enum MenuWhenAbsent {
        /// Fresh login and finished creation stop on the welcome menu.
        case menu
        /// Linkdead reattach is already in the game.
        case playing
        /// Since and stream comments only move the flag when they send one.
        case keep
    }

    private func arrivalAnnouncement(_ character: String, resumed: Bool?) -> String {
        if atMenu {
            return "At the menu as \(character)."
        }
        if resumed == true {
            return "Resumed \(character)."
        }
        return "Playing as \(character)"
    }

    /// `menu` wins when both fields arrive. `state` is `menu` or `playing`.
    private func applyArrivedMenu(menu: Bool?, state: String?, whenAbsent: MenuWhenAbsent) {
        if let menu {
            atMenu = menu
            return
        }
        if let state {
            switch state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "menu":
                atMenu = true
                return
            case "playing":
                atMenu = false
                return
            default:
                break
            }
        }
        switch whenAbsent {
        case .menu:
            atMenu = true
        case .playing:
            atMenu = false
        case .keep:
            break
        }
    }

    /// SSE comment `: {"menu":true|false}`. Anything else is ignored.
    /// The comment is not game text and is never written into the transcript.
    private func applyMenuComment(_ line: String) {
        let payload = line.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard let data = String(payload).data(using: .utf8),
              let object = jsonObject(data) else { return }
        let menu = boolValue(object, "menu")
        let state = object["state"] as? String
        guard menu != nil || (state?.isEmpty == false) else { return }
        applyArrivedMenu(menu: menu, state: state, whenAbsent: .keep)
    }

    private func noteMenuFlag(_ data: Data) {
        guard let object = jsonObject(data) else { return }
        applyArrivedMenu(
            menu: boolValue(object, "menu"),
            state: object["state"] as? String,
            whenAbsent: .keep
        )
    }

    private func responseClosed(_ data: Data) -> Bool {
        guard let object = jsonObject(data) else { return false }
        return boolValue(object, "closed") == true
    }

    /// JSON booleans only. A numeric 0 or 1 is not a menu flag.
    private func boolValue(_ object: [String: Any], _ key: String) -> Bool? {
        guard let value = object[key] else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        if let raw = value as? String {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    /// 400, 409, 502, and 504 stay short. The game's own sentence arrives as 200 `error`.
    private func passwordFailureMessage(status: Int, serverMessage: String) -> String {
        switch status {
        case 400:
            return "Enter the current and new password."
        case 409:
            if serverMessage.compare("busy", options: .caseInsensitive) == .orderedSame {
                return "Busy. Try again."
            }
            return "Not at the menu."
        case 502:
            return "The game connection dropped."
        case 504:
            return "The game did not answer."
        default:
            return "Could not change the password."
        }
    }

    /// A different character replaces the one this device was holding.
    /// The server drops the other session; the transcript, ids, menu, and badge go too.
    private func isDifferentCharacter(_ next: String) -> Bool {
        guard next.isEmpty == false, let held = heldCharacterName() else { return false }
        return namesEqual(held, next) == false
    }

    private func heldCharacterName() -> String? {
        if let character, character.isEmpty == false { return character }
        if savedName.isEmpty == false { return savedName }
        return nil
    }

    private func resetPreviousCharacterMemory() {
        stopLive()
        cancelResumeReveal()
        resumeSeparatorID = nil
        lines = []
        lastSeq = 0
        pendingVitals = nil
        vitals = nil
        atMenu = false
        menuBusy = false
        menuExit = false
        command = ""
        parked = false
        token = nil
        sessionId = nil
        character = nil
        clearSessionSecrets()
        clearDisconnectMarker()
        clearShownDisconnect()
        defaults.set("0", forKey: StoreKey.lastSeq)
        defaults.removeObject(forKey: StoreKey.character)
        defaults.removeObject(forKey: StoreKey.hmv)
        defaults.removeObject(forKey: StoreKey.hmvName)
        zeroLocalBadge()
    }

    /// Menu quit, or park while the menu is up (`{"closed":true}`).
    /// The Keychain token and session id go. The password stays for the next enter.
    private func finishMenuUnlink() {
        menuExit = false
        stopLive()
        cancelResumeReveal()
        resumeSeparatorID = nil
        lines = []
        lastSeq = 0
        atMenu = false
        menuBusy = false
        command = ""
        parked = false
        token = nil
        sessionId = nil
        character = nil
        clearSessionSecrets()
        clearDisconnectMarker()
        clearShownDisconnect()
        defaults.set("0", forKey: StoreKey.lastSeq)
        defaults.removeObject(forKey: StoreKey.character)
        zeroLocalBadge()
        status = "Unlinked. The MUD session is closed."
    }

    /// Playing sessions still reattach. A close while the menu is up, or a quit
    /// that already dropped the menu flag, stays on the login screen.
    private func handleClosedSession() async {
        if atMenu || menuExit {
            finishMenuUnlink()
            return
        }
        await dropClosedSession()
    }

    /// True when the caller must stop. Menu rejects do not log in again.
    private func handleRejectedSession(thenLogin: Bool) async -> Bool {
        if atMenu || menuExit {
            finishMenuUnlink()
            return true
        }
        token = nil
        if thenLogin {
            await autoPasswordLogin()
        }
        return false
    }

    private func zeroLocalBadge() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        if #available(iOS 16.0, *) {
            center.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
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

    private enum CreatePhase {
        case start
        case answer
    }

    /// `POST /v1/create` and `POST /v1/create/{cid}/answer`.
    /// A body with `token` is the login body and starts the normal session.
    /// Answer 404, or a status of aborted/closed, returns to login with the message.
    /// Other create errors stay on the form or on the current step.
    private func handleCreateHTTP(
        _ http: (status: Int, data: Data),
        phase: CreatePhase,
        generation: Int
    ) async {
        guard generation == createGeneration else { return }
        let object = jsonObject(http.data) ?? [:]
        if phase == .answer, http.status == 404 || http.status == 410 {
            returnToLogin(errorText(from: http.data, status: http.status))
            return
        }
        // A login body wins over an ended flag. Final success is the normal session.
        if object["token"] is String,
           let login = try? JSONDecoder().decode(LoginResponse.self, from: http.data) {
            guard generation == createGeneration else { return }
            await enterCreatedSession(login)
            return
        }
        if phase == .answer, let ended = creationEndedMessage(object) {
            returnToLogin(ended)
            return
        }
        if let step = decodeCreateStep(in: object) {
            if phase == .start {
                guard let cid = stringField(object, "cid") else {
                    createError = (200...299).contains(http.status)
                        ? "Character creation returned an unexpected response."
                        : errorText(from: http.data, status: http.status)
                    return
                }
                setCreateCID(cid)
                createGreeting = greetingText(object["greeting"]) ?? ""
                publishCreateStep(step)
                createError = nil
                return
            }
            if let cid = stringField(object, "cid") {
                setCreateCID(cid)
            }
            if let g = greetingText(object["greeting"]) {
                createGreeting = g
            }
            publishCreateStep(step)
            return
        }
        let message = errorText(from: http.data, status: http.status)
        if phase == .answer, isAbortError(message) {
            returnToLogin(message)
            return
        }
        presentCreateFailure(message, phase: phase)
    }

    /// Same session start as a successful login: Keychain token and session id,
    /// then since polling. The previous character's disconnect gap is not reused.
    private func enterCreatedSession(_ login: LoginResponse) async {
        let keptPassword = createPassword
        let keptName = createName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear the id before the wizard view leaves, so its disappear hook does not DELETE.
        setCreateCID(nil)
        creating = false
        createGreeting = nil
        createStep = nil
        resetCreateLog()
        createPassword = nil
        createError = nil
        createBusy = false
        characterMissing = false
        assignNameFromApp(login.character.isEmpty ? keptName : login.character)
        if let keptPassword, keptPassword.isEmpty == false {
            password = keptPassword
        }
        didAutoLogin = true
        let nextCharacter = login.character.isEmpty ? keptName : login.character
        let switching = isDifferentCharacter(nextCharacter)
        if switching {
            resetPreviousCharacterMemory()
        }
        token = login.token
        sessionId = login.sessionId
        adoptCharacter(login.character)
        parked = login.parked ?? false
        savedName = name
        // Finished creation stops on the menu, same as a fresh login.
        applyArrivedMenu(menu: login.menu, state: login.state, whenAbsent: .menu)
        clearDisconnectMarker()
        clearShownDisconnect()
        cancelResumeReveal()
        replaceTranscript(
            login.lines ?? [],
            animatedScroll: true,
            serverDisconnectedAt: nil,
            trustCursor: false
        )
        persistAccount()
        if switching {
            resetServerBadge()
        }
        let shownCharacter = login.character.isEmpty ? keptName : login.character
        await settleAfterResume(announcement: arrivalAnnouncement(shownCharacter, resumed: login.resumed))
    }

    private func returnToLogin(_ message: String) {
        createGeneration += 1
        clearCreationMemory()
        status = message
    }

    private func clearCreationMemory() {
        setCreateCID(nil)
        creating = false
        createGreeting = nil
        createStep = nil
        resetCreateLog()
        createPassword = nil
        createError = nil
        createBusy = false
        characterMissing = false
    }

    /// Copies a step's info onto the creation transcript, including a password step.
    /// Lines are stored as the server sent them. An error re-send of the same
    /// info is not copied twice. A new roll, with new info and no error, is always copied.
    /// Each copied block is one section. The rule between sections is drawn by
    /// the view and is not inserted into the text. `infoAnsi`, when the server
    /// sent it, is kept beside the plain lines for that section.
    private func appendCreateLog(_ step: CreateStep) {
        let block = step.info
        let failed = step.error?.isEmpty == false
        if let createLogBlock, block == createLogBlock, failed {
            return
        }
        createLogBlock = block
        let ansiLines = step.infoAnsi.flatMap { $0.isEmpty ? nil : $0 }
        guard block.isEmpty == false || ansiLines != nil else { return }
        createLog.append(CreateLogSection(lines: block, ansiLines: ansiLines))
    }

    private func resetCreateLog() {
        createLog = []
        createLogBlock = nil
    }

    /// Every decoded step, including a reroll whose kind, label, and options match.
    private func publishCreateStep(_ step: CreateStep) {
        createStep = step
        createStepSerial += 1
        appendCreateLog(step)
    }

    /// Keeps the in-memory id and the `createCID` default together.
    private func setCreateCID(_ cid: String?) {
        createCID = cid
        if let cid, cid.isEmpty == false {
            defaults.set(cid, forKey: StoreKey.createCID)
        } else {
            defaults.removeObject(forKey: StoreKey.createCID)
        }
    }

    /// A creation left open when the app died. The stored id is cleared and
    /// DELETE /v1/create/{cid} is sent without waiting.
    private func discardOrphanedCreation() {
        guard let cid = defaults.string(forKey: StoreKey.createCID), cid.isEmpty == false else { return }
        defaults.removeObject(forKey: StoreKey.createCID)
        deleteCreation(cid)
    }

    /// A response that arrived after Cancel. Abort that creation and do not log in.
    private func abortLateCreation(_ data: Data) {
        guard let object = jsonObject(data), let cid = stringField(object, "cid") else { return }
        deleteCreation(cid)
    }

    /// Busy and MUD-timeout responses stay on the form (and on the current step).
    /// They do not raise the proxy or server dialog.
    private func presentCreationInlineError(_ message: String, phase: CreatePhase) {
        createError = message
        presentCreateFailure(message, phase: phase)
    }

    private func presentCreateFailure(_ message: String, phase: CreatePhase) {
        if phase == .start || createStep == nil {
            createError = message
            return
        }
        var step = createStep!
        step.error = message
        createStep = step
    }

    private func decodeCreateStep(in object: [String: Any]) -> CreateStep? {
        if let nested = object["step"], let step = CreateStep.decodeJSON(nested) {
            return step
        }
        return CreateStep.decodeJSON(object)
    }

    private func creationEndedMessage(_ object: [String: Any]) -> String? {
        let raw = (object["status"] as? String) ?? (object["state"] as? String) ?? ""
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aborted = status == "aborted" || object["aborted"] as? Bool == true
        let closed = status == "closed" || object["closed"] as? Bool == true
        guard aborted || closed else { return nil }
        if let error = object["error"] as? String, error.isEmpty == false {
            return error
        }
        if status == "aborted" || status == "closed" {
            return raw
        }
        return aborted ? "aborted" : "closed"
    }

    private func isAbortError(_ error: String) -> Bool {
        let key = error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key == "aborted" || key == "closed"
    }

    /// A greeting is one string, or an array of strings joined with newlines.
    /// Each line is kept exactly as the server sent it.
    private func greetingText(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let lines = value as? [String] {
            return lines.joined(separator: "\n")
        }
        if let items = value as? [Any] {
            var lines: [String] = []
            for item in items {
                guard let line = item as? String else { return nil }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
        return nil
    }

    private func errorText(from data: Data, status: Int) -> String {
        if let object = jsonObject(data),
           let error = object["error"] as? String,
           error.isEmpty == false {
            return error
        }
        if (200...299).contains(status) {
            return "Character creation returned an unexpected response."
        }
        return "Creation failed (\(status))"
    }

    private func stringField(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        guard data.isEmpty == false else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func createSend(
        method: String,
        path: String,
        json: [String: Any]?
    ) async throws -> (status: Int, data: Data) {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HTTPFailure(status: 0, message: "No response from the IM server.")
        }
        return (http.statusCode, data)
    }

    /// Does not wait. A proxy or MUD outage still raises the shared alert.
    /// 404 and 410 mean the creation is already gone, so those stay quiet.
    private func deleteCreation(_ cid: String) {
        Task { await performDeleteCreation(cid) }
    }

    private func performDeleteCreation(_ cid: String) async {
        do {
            let http = try await createSend(
                method: "DELETE",
                path: "/v1/create/\(pathComponent(cid))",
                json: nil
            )
            if http.status == 404 || http.status == 410 {
                return
            }
            if let kind = OutageKind.http(status: http.status, data: http.data) {
                reportOutage(kind, retry: .delete(cid))
            }
        } catch {
            if let kind = OutageKind.transport(error) {
                reportOutage(kind, retry: .delete(cid))
            }
        }
    }

    private func pathComponent(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// Login copy that means the name is not a character yet. The create
    /// button is always on the login screen; this is the extra offer beside the error.
    private static func indicatesMissingCharacter(_ message: String) -> Bool {
        let text = message.lowercased()
        let phrases = [
            "does not exist",
            "doesn't exist",
            "doesnt exist",
            "no such",
            "unknown character",
            "unknown player",
            "unknown name",
            "no character",
            "no player",
            "character not found",
            "player not found",
            "name not found",
            "not exist",
            "did i get that right"
        ]
        return phrases.contains { text.contains($0) }
    }
}
