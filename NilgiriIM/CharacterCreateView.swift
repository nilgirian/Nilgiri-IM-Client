import SwiftUI

private let creationColumns = 80
private let creationInk = Color(white: 0.88)
private let creationScreen = Color.black

/// Name and email, then the creation wizard. Descriptions scroll behind the
/// choice panel. Leaving this screen cancels the creation. Backgrounding
/// cancels too, except the password step, which stays up while the player
/// reads the email.
struct CharacterCreateView: View {
    @EnvironmentObject private var session: IMSession
    @State private var selectedIndex: Int?
    @State private var textAnswer = ""
    @State private var passwordAnswer = ""
    @FocusState private var passwordFocused: Bool
    /// Visible height of the choice panel, so the transcript can scroll clear of it.
    @State private var panelHeight: CGFloat = 0
    /// Full height of the choice panel's controls, before the height cap.
    @State private var stepContentHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            Group {
                if session.createGreeting == nil {
                    detailsForm
                } else {
                    wizard
                }
            }
            .preferredColorScheme(.dark)
            .toolbarBackground(Chrome.barBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle("Character Creation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.cancelCharacterCreation()
                    }
                    .foregroundStyle(Color(white: 0.78))
                }
                if session.createStep?.isPassword == true {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            passwordFocused = false
                        }
                    }
                }
            }
        }
        .onDisappear {
            session.abandonCharacterCreationIfNeeded()
        }
    }

    private var detailsForm: some View {
        Form {
            Section("Character") {
                TextField("Name", text: $session.createName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Email", text: $session.createEmail)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
            }
            Section {
                if let createError = session.createError, createError.isEmpty == false {
                    Text(createError)
                        .foregroundStyle(.red)
                }
                Button {
                    Task { await session.startCharacterCreation() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Create")
                        if session.createBusy {
                            ProgressView()
                        }
                    }
                }
                .disabled(canStart == false)
            }
        }
        .scrollContentBackground(.hidden)
        .background(creationScreen)
        .foregroundStyle(Color(white: 0.78))
    }

    private var canStart: Bool {
        session.createBusy == false
            && session.createName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && session.createEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The step button stays labeled Next. A spinner shows while the answer is in flight.
    private var creationContinueLabel: some View {
        HStack(spacing: 8) {
            Text("Next")
            if session.createBusy {
                ProgressView()
            }
        }
    }

    private var wizard: some View {
        GeometryReader { geo in
            let fontSize = max(8, (geo.size.width - 16) / CGFloat(creationColumns) / 0.62)
            let phoneLandscape = UIDevice.current.userInterfaceIdiom == .phone
                && geo.size.width > geo.size.height
            let panelCap = geo.size.height * (phoneLandscape ? 0.55 : 0.62)
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Ansi.text(session.createGreeting ?? "", fontSize: fontSize, columns: creationColumns)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(8)
                            ForEach(Array(session.createLog.enumerated()), id: \.offset) { index, line in
                                Text(verbatim: line.isEmpty ? " " : line)
                                    .font(.system(size: fontSize, design: .monospaced))
                                    .foregroundStyle(creationInk)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .id(createLogLineID(index))
                            }
                            Color.clear
                                .frame(height: panelHeight + 12)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded {
                            passwordFocused = false
                        })
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        guard session.createLog.isEmpty == false else { return }
                        scrollCreateLog(to: 0, proxy: proxy)
                    }
                    .onChange(of: session.createLog.count) { oldCount, newCount in
                        guard newCount > oldCount else { return }
                        scrollCreateLog(to: oldCount, proxy: proxy)
                    }
                }
                .background(creationScreen)
                if let step = session.createStep {
                    VStack {
                        // The log scrolls behind this. On the password step it must
                        // still receive taps and drags so the keyboard can dismiss.
                        Spacer(minLength: 0)
                            .allowsHitTesting(step.isPassword == false)
                        if step.isPassword {
                            passwordDialog(step)
                        } else {
                            stepPanel(step, maxHeight: panelCap)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(creationScreen)
        .onPreferenceChange(CreatePanelHeightKey.self) { panelHeight = $0 }
        .onPreferenceChange(CreateStepContentHeightKey.self) { stepContentHeight = $0 }
        .onChange(of: session.createStepSerial) { _, _ in
            selectedIndex = nil
            textAnswer = ""
            passwordAnswer = ""
        }
    }

    /// Label, error, choices or text field, and Next. Description lines stay in the transcript.
    private func stepPanel(_ step: CreateStep, maxHeight: CGFloat) -> some View {
        let fittedHeight: CGFloat? = stepContentHeight > 0 ? min(stepContentHeight, maxHeight) : nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(step.label)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error = step.error, error.isEmpty == false {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if step.isText {
                    TextField("Answer", text: $textAnswer)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .submitLabel(.next)
                        .onSubmit { submit(answer(for: step)) }
                } else {
                    ForEach(Array(step.choices.enumerated()), id: \.offset) { index, option in
                        Button {
                            selectedIndex = index
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedIndex == index ? "largecircle.fill.circle" : "circle")
                                Text(option.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedIndex == index ? .isSelected : AccessibilityTraits())
                    }
                }
                Button {
                    submit(answer(for: step))
                } label: {
                    creationContinueLabel
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(white: 0.28))
                .disabled(session.createBusy || answer(for: step).isEmpty)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: CreateStepContentHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .frame(height: fittedHeight)
        .foregroundStyle(creationInk)
        .background(Chrome.barBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: CreatePanelHeightKey.self, value: proxy.size.height)
            }
        }
    }

    private func createLogLineID(_ index: Int) -> String {
        "create-log-\(index)"
    }

    /// The newest block starts at `index`. Scroll once the row is in the tree.
    private func scrollCreateLog(to index: Int, proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(createLogLineID(index), anchor: .top)
        }
    }

    /// Prompt, field, error, and Next. Server text for this step is in the log.
    /// Pinned to the bottom so the keyboard lifts it with the rest of the chrome.
    private func passwordDialog(_ step: CreateStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(step.passwordPrompt(fallbackEmail: session.createEmail))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            SecureField("Password", text: $passwordAnswer)
                .focused($passwordFocused)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .submitLabel(.next)
                .onSubmit { submit(passwordAnswer) }
            if let error = step.error, error.isEmpty == false {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                submit(passwordAnswer)
            } label: {
                creationContinueLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(white: 0.28))
            .disabled(session.createBusy || passwordAnswer.isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(creationInk)
        .background(Chrome.barBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: CreatePanelHeightKey.self, value: proxy.size.height)
            }
        }
    }

    private func answer(for step: CreateStep) -> String {
        if step.isPassword {
            return passwordAnswer
        }
        if step.isText {
            return textAnswer
        }
        guard let selectedIndex, step.choices.indices.contains(selectedIndex) else { return "" }
        return step.choices[selectedIndex].value
    }

    private func submit(_ value: String) {
        guard session.createBusy == false, value.isEmpty == false else { return }
        Task { await session.answerCharacterCreation(value) }
    }
}

/// Height of the choice controls, used to hug the panel to its content.
private struct CreateStepContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Visible height of the choice panel, including its height cap.
private struct CreatePanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
