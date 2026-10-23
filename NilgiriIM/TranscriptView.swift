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
                                        Ansi.text(line.text, fontSize: fontSize, columns: terminalColumns)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(line.seq)
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
                        .scrollDismissesKeyboard(.interactively)
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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        commandFocused = false
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

    // Login fills `lines` before this view exists, so the first backlog is not an
    // onChange. Resume catchUp appends later and does change the array. Wait until
    // after layout; the bottom anchor is not ready on the triggering frame.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let scroll = { proxy.scrollTo(transcriptBottomID, anchor: .bottom) }
        DispatchQueue.main.async(execute: scroll)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: scroll)
    }

}
