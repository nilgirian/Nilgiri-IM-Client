import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: IMSession

    var body: some View {
        NavigationStack {
            Form {
                Section("Character") {
                    TextField("Name", text: $session.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .onChange(of: session.name) { old, new in
                            guard old != new else { return }
                            if session.acknowledgeNameWrite(new) { return }
                            session.password = ""
                        }
                    SecureField("Password", text: $session.password)
                        .textContentType(.password)
                }
                Section {
                    Button(session.offersResume ? "Resume parked session" : "Enter Nilgiri") {
                        Task { await session.login() }
                    }
                    .disabled(session.busy || session.name.isEmpty)
                    Button("Create new character") {
                        session.openCharacterCreation()
                    }
                    .disabled(session.busy)
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
}
