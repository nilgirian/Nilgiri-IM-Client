import SwiftUI

private let terminalColumns = 80
private let ink = Color(white: 0.78)
private let screen = Color.black
private let transcriptBottomID = "transcript-bottom"

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var commandFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let fontSize = max(8, (geo.size.width - 16) / CGFloat(terminalColumns) / 0.62)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(session.lines) { line in
                                        transcriptLine(line, fontSize: fontSize)
                                            .id(line.id)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .frame(minHeight: geo.size.height, alignment: .topLeading)
                                Color.clear
                                    .frame(height: 1)
                                    .allowsHitTesting(false)
                                    .id(transcriptBottomID)
                            }
                        }
                        .defaultScrollAnchor(.bottom)
                        .onAppear { scrollToBottom(proxy) }
                        .onChange(of: session.lines) { _, _ in
                            scrollToBottom(proxy)
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
                        .focused($commandFocused)
                        .onSubmit { Task { await sendCommand() } }
                    Button("Send") { Task { await sendCommand() } }
                        .foregroundStyle(ink)
                }
                .padding(12)
                .background(screen)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15)
                        .onEnded { value in
                            let translation = value.translation
                            if translation.height > abs(translation.width), translation.height > 0 {
                                commandFocused = false
                            }
                        }
                )
            }
            .background(screen)
            .preferredColorScheme(.dark)
            .toolbarBackground(screen, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(session.character ?? "IM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Unlink") {
                        Task { await session.logout(closeMud: true) }
                    }
                    .foregroundStyle(ink)
                    .accessibilityLabel("Unlink")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    if phase == .background {
                        await session.sceneWentBackground()
                    } else if phase == .active {
                        await session.sceneBecameActive()
                    }
                }
            }
            .task {
                await PushRegistration.request(session: session)
            }
        }
    }

    private func sendCommand() async {
        await session.send()
        commandFocused = false
    }

    // Login fills `lines` before this view exists, so the first backlog is not an
    // onChange. Resume replace, catch-up append, and a disconnect separator all
    // change the array. Wait until after layout; the bottom anchor is not ready
    // on the triggering frame.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let scroll = { proxy.scrollTo(transcriptBottomID, anchor: .bottom) }
        DispatchQueue.main.async(execute: scroll)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: scroll)
    }

    @ViewBuilder
    private func transcriptLine(_ line: LineDTO, fontSize: CGFloat) -> some View {
        if line.kind == "separator" {
            Text(line.text)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Ansi.text(line.text, fontSize: fontSize, columns: terminalColumns)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
