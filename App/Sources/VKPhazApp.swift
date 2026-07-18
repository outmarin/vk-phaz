import SwiftUI

@main
struct VKPhazApp: App {
    @State private var token: String? = Keychain.load()

    var body: some Scene {
        WindowGroup {
            if let token {
                ChatListView(vk: VK(token: token)) {
                    Keychain.clear()
                    self.token = nil
                }
            } else {
                LoginView { t in
                    Keychain.save(t)
                    token = t
                }
            }
        }
    }
}

struct LoginView: View {
    let onLogin: (String) -> Void
    @State private var input = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 60)).foregroundStyle(.blue)
            Text("VK Phaz").font(.largeTitle.bold())
            Text("Вставь access_token своего аккаунта VK")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("access_token", text: $input)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal)
            Button("Войти") {
                let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { onLogin(t) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
        .padding()
    }
}
