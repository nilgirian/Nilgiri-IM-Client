import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(session.lines) { line in
                                Text(display(line.text))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(color(for: line.kind))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.seq)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: session.lines.last?.seq) { _, seq in
                        if let seq {
                            proxy.scrollTo(seq, anchor: .bottom)
                        }
                    }
                }
                HStack {
                    TextField("command", text: $session.command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await session.send() } }
                    Button("Send") { Task { await session.send() } }
                }
                .padding(12)
            }
            .navigationTitle(session.character ?? "IM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Park") {
                        Task { await session.logout(closeMud: false) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Quit") {
                        Task { await session.logout(closeMud: true) }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    if phase == .background {
                        await session.park(true)
                    } else if phase == .active {
                        await session.park(false)
                        await session.catchUp()
                    }
                }
            }
            .task {
                await PushRegistration.request(session: session)
            }
        }
    }

    private func display(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "tell", "whisper", "pray": return .blue
        case "combat_start": return .orange
        case "death", "linkloss": return .red
        case "idle": return .secondary
        default: return .primary
        }
    }
}
