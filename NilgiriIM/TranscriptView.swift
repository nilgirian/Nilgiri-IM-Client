import SwiftUI

private let terminalColumns = 80
private let ink = Color(white: 0.78)
private let screen = Color.black

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let fontSize = max(8, (geo.size.width - 16) / CGFloat(terminalColumns) / 0.62)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(session.lines) { line in
                                    Ansi.text(line.text, fontSize: fontSize, columns: terminalColumns)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.seq)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .frame(minHeight: geo.size.height, alignment: .topLeading)
                        }
                        .onChange(of: session.lines.last?.seq) { _, seq in
                            if let seq {
                                proxy.scrollTo(seq, anchor: .bottom)
                            }
                        }
                    }
                }
                HStack {
                    Text(">")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(ink)
                    TextField("command", text: $session.command)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await session.send() } }
                    Button("Send") { Task { await session.send() } }
                        .foregroundStyle(ink)
                }
                .padding(12)
                .background(screen)
            }
            .background(screen)
            .preferredColorScheme(.dark)
            .toolbarBackground(screen, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(session.character ?? "IM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Park") {
                        Task { await session.logout(closeMud: false) }
                    }
                    .foregroundStyle(ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Quit") {
                        Task { await session.logout(closeMud: true) }
                    }
                    .foregroundStyle(ink)
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

}
