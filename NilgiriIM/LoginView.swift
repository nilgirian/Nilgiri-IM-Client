import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: IMSession
    @FocusState private var passwordFocused: Bool
    /// Bumped on every password write. A name edit clears Password only when
    /// this is unchanged across one main-actor turn, so AutoFill can write
    /// the name and the password together.
    @State private var passwordWriteToken: UInt = 0
    @State private var passwordWriteAt = Date.distantPast
    @State private var pendingPasswordClear: Task<Void, Never>?

    /// Password writes closer than this belong to the same turn as the name edit.
    private static let sameTurnSeconds: TimeInterval = 0.05

    var body: some View {
        NavigationStack {
            Form {
                Section("Character") {
                    ClearableTextField(
                        title: "Name",
                        text: $session.name,
                        contentType: .username,
                        onClear: {
                            session.name = ""
                            session.password = ""
                        }
                    )
                    RevealableSecureField(
                        "Password",
                        text: $session.password,
                        textContentType: .password,
                        focus: $passwordFocused
                    )
                }
                Section {
                    VStack(spacing: 0) {
                        Button {
                            Task { await session.login() }
                        } label: {
                            Text(session.offersResume ? "Resume parked session" : "Enter Nilgiri")
                                .foregroundStyle(Color.black)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Color(white: 0.86))
                        .disabled(session.busy || session.name.isEmpty)

                        Text("– OR –")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.78))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .accessibilityLabel("or")

                        Button {
                            session.openCharacterCreation()
                        } label: {
                            Text("Create new character")
                                .foregroundStyle(Color(white: 0.78))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(Color(white: 0.78))
                        .disabled(session.busy)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.status)
                            .foregroundStyle(session.characterMissing ? Color.red : Color(white: 0.78))
                        if session.characterMissing {
                            Button("Create new character") {
                                session.openCharacterCreation()
                            }
                            .disabled(session.busy)
                        }
                    }
                }
            }
            .onChange(of: session.password) { _, _ in
                passwordWriteToken &+= 1
                passwordWriteAt = Date()
            }
            .onChange(of: session.name) { old, new in
                userChangedName(from: old, to: new)
            }
            .onDisappear {
                pendingPasswordClear?.cancel()
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .foregroundStyle(Color(white: 0.78))
            .preferredColorScheme(.dark)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Nilgiri the Forgotten World")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Nilgiri the Forgotten World")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    /// A typed Name still drops a stale password. AutoFill writes the password
    /// in the same turn, either just before this handler or before the next
    /// main-actor turn; that write must not be wiped. The app's own name
    /// restore is ignored by `acknowledgeNameWrite`.
    private func userChangedName(from old: String, to new: String) {
        guard old != new else { return }
        if session.acknowledgeNameWrite(new) { return }
        let token = passwordWriteToken
        if Date().timeIntervalSince(passwordWriteAt) < Self.sameTurnSeconds {
            pendingPasswordClear?.cancel()
            return
        }
        pendingPasswordClear?.cancel()
        pendingPasswordClear = Task { @MainActor in
            await Task.yield()
            guard Task.isCancelled == false else { return }
            guard passwordWriteToken == token else { return }
            guard session.token == nil else { return }
            session.password = ""
        }
    }
}

/// Name field with a trailing clear control. The control is shown only while
/// the field is focused and non-empty. Hiding is deferred one turn when focus
/// leaves, so the tap that clears is not swallowed by the field resigning.
struct ClearableTextField: View {
    let title: String
    @Binding var text: String
    var contentType: UITextContentType?
    let onClear: () -> Void

    @FocusState private var focused: Bool
    @State private var showClear = false

    var body: some View {
        HStack(spacing: 0) {
            TextField(title, text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .modifier(ContentTypeModifier(type: contentType))
                .frame(maxWidth: .infinity, alignment: .leading)
            if showClear {
                FieldClearButton(action: onClear)
            }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                showClear = text.isEmpty == false
            } else {
                Task { @MainActor in
                    if focused == false {
                        showClear = false
                    }
                }
            }
        }
        .onChange(of: text) { _, newValue in
            if focused {
                showClear = newValue.isEmpty == false
            }
        }
    }
}

/// Trailing clear. At least a 44pt target, labeled "Clear".
struct FieldClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(white: 0.55))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Clear")
    }
}

/// Password row that shows either a `SecureField` or a plain `TextField` on
/// the same binding. The eye toggles that. Reveal goes back to hidden when
/// the row leaves the screen. A focused field is focused again after the
/// swap so the caret stays in it.
struct RevealableSecureField: View {
    let title: String
    @Binding var text: String
    var textContentType: UITextContentType?
    var submitLabel: SubmitLabel
    var submitAction: () -> Void
    var focus: FocusState<Bool>.Binding

    @State private var revealed = false

    init(
        _ title: String,
        text: Binding<String>,
        textContentType: UITextContentType? = .password,
        submitLabel: SubmitLabel = .return,
        submitAction: @escaping () -> Void = {},
        focus: FocusState<Bool>.Binding
    ) {
        self.title = title
        self._text = text
        self.textContentType = textContentType
        self.submitLabel = submitLabel
        self.submitAction = submitAction
        self.focus = focus
    }

    var body: some View {
        HStack(spacing: 0) {
            entry
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggleReveal) {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(Color(white: 0.78))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel(revealed ? "Hide password" : "Show password")
        }
        .onDisappear { revealed = false }
    }

    @ViewBuilder
    private var entry: some View {
        if revealed {
            styled(TextField(title, text: $text))
        } else {
            styled(SecureField(title, text: $text))
        }
    }

    private func styled<V: View>(_ field: V) -> some View {
        field
            .focused(focus)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            .submitLabel(submitLabel)
            .modifier(ContentTypeModifier(type: textContentType))
            .onSubmit { submitAction() }
    }

    private func toggleReveal() {
        let keepFocus = focus.wrappedValue
        revealed.toggle()
        guard keepFocus else { return }
        focus.wrappedValue = false
        Task { @MainActor in
            focus.wrappedValue = true
        }
    }
}

/// Applies a content type only when one was asked for, so a field that had
/// none keeps that.
private struct ContentTypeModifier: ViewModifier {
    let type: UITextContentType?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let type {
            content.textContentType(type)
        } else {
            content
        }
    }
}
