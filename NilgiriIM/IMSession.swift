import Foundation
import Combine

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

    private var lastSeq: Int64 = 0
    private var pollTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    func login() async {
        busy = true
        defer { busy = false }
        do {
            let body = ["name": name, "password": password, "color": true] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: body)
            var req = URLRequest(url: url("/v1/login"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode != 200 {
                status = (try? JSONDecoder().decode(ErrorResponse.self, from: respData))?.error
                    ?? "Login failed (\(http.statusCode))"
                return
            }
            let login = try JSONDecoder().decode(LoginResponse.self, from: respData)
            token = login.token
            sessionId = login.sessionId
            character = login.character
            status = "Playing as \(login.character)"
            lastSeq = 0
            lines = []
            append(login.lines ?? [])
            await park(false)
            startLive()
            await PushRegistration.flush(session: self)
        } catch {
            status = error.localizedDescription
        }
    }

    func send() async {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }
        command = ""
        do {
            try await post("/input", ["text": text])
        } catch {
            status = error.localizedDescription
        }
    }

    func park(_ value: Bool) async {
        parked = value
        do {
            try await post("/park", ["parked": value])
            status = value
                ? "Parked. Tells, death, combat start, idle, and link loss can notify."
                : "Live. Full transcript while the app is open."
        } catch {
            status = error.localizedDescription
        }
    }

    func registerDevice(token hex: String, environment: String) async {
        do {
            try await post("/device", ["token": hex, "environment": environment])
        } catch {
            status = error.localizedDescription
        }
    }

    func logout(closeMud: Bool) async {
        stopLive()
        if closeMud {
            try? await post("/close", [:])
        } else {
            await park(true)
        }
        token = nil
        sessionId = nil
        character = nil
        lines = []
        lastSeq = 0
    }

    func catchUp() async {
        guard let sessionId, token != nil else { return }
        do {
            var req = URLRequest(url: url("/v1/sessions/\(sessionId)/since/\(lastSeq)"))
            req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let since = try JSONDecoder().decode(SinceResponse.self, from: data)
            append(since.lines)
            if since.closed {
                status = "MUD session closed (idle, unlink, or logout)."
            }
        } catch {
            status = error.localizedDescription
        }
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
        guard let sessionId, let token else { return }
        var req = URLRequest(url: url("/v1/sessions/\(sessionId)/stream"))
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
        } catch {
            if Task.isCancelled == false {
                status = "Live stream dropped; polling catch-up."
            }
        }
    }

    private func append(_ incoming: [LineDTO]) {
        for line in incoming where line.seq > lastSeq {
            lastSeq = line.seq
            if line.text.contains("Do you want text color") {
                continue
            }
            lines.append(line)
        }
        if lines.count > 4000 {
            lines.removeFirst(lines.count - 4000)
        }
    }

    private func post(_ action: String, _ body: [String: Any]) async throws {
        guard let sessionId else { return }
        var req = URLRequest(url: url("/v1/sessions/\(sessionId)\(action)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func url(_ path: String) -> URL {
        URL(string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!
    }
}
