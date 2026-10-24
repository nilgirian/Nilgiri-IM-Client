import SwiftUI

private let creationColumns = 80
private let creationInk = Color(white: 0.88)
private let creationScreen = Color.black

/// Name and email, then each creation step over the ANSI greeting.
/// Leaving this screen cancels the creation. Backgrounding does not: the
/// password step has to stay up while the player reads the email.
struct CharacterCreateView: View {
    @EnvironmentObject private var session: IMSession
    @State private var selectedIndex: Int?
    @State private var textAnswer = ""
    @State private var passwordAnswer = ""

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
            .toolbarBackground(creationScreen, for: .navigationBar)
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
            ZStack {
                ScrollView {
                    Ansi.text(session.createGreeting ?? "", fontSize: fontSize, columns: creationColumns)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .background(creationScreen)
                if let step = session.createStep {
                    if step.isPassword {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        passwordDialog(step)
                    } else {
                        VStack {
                            Spacer(minLength: 0)
                            stepPanel(step)
                                .frame(maxHeight: geo.size.height * 0.62)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .background(creationScreen)
        .onChange(of: session.createStep?.signature) { _, _ in
            selectedIndex = nil
            textAnswer = ""
            passwordAnswer = ""
        }
    }

    private func stepPanel(_ step: CreateStep) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(step.label)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(step.info.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        }
        .foregroundStyle(creationInk)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func passwordDialog(_ step: CreateStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(step.passwordPrompt(fallbackEmail: session.createEmail))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(step.info.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SecureField("Password", text: $passwordAnswer)
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
        .frame(maxWidth: 420)
        .foregroundStyle(creationInk)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
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
