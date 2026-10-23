import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: IMSession

    var body: some View {
        NavigationStack {
            Form {
                Section("IM server") {
                    TextField("https://nilgiri.net/im", text: $session.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Character") {
                    TextField("Name", text: $session.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $session.password)
                }
                Section {
                    Button("Enter Nilgiri") {
                        Task { await session.login() }
                    }
                    .disabled(session.busy || session.name.isEmpty)
                } footer: {
                    Text(session.status)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .foregroundStyle(Color(white: 0.78))
            .preferredColorScheme(.dark)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Nilgiri IM")
        }
    }
}
