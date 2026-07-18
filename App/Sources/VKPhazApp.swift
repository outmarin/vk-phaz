import SwiftUI

@main
struct VKPhazApp: App {
    @StateObject private var store = AccountStore()
    @StateObject private var live = LiveUpdates()
    @AppStorage("accentHex") private var accentHex = "#3A8DFF"
    @AppStorage("appearance") private var appearance = 0

    private var accent: Color { Color(hex: accentHex) ?? .blue }
    private var scheme: ColorScheme? {
        switch appearance { case 1: return .light; case 2: return .dark; default: return nil }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(live)
                .tint(accent)
                .preferredColorScheme(scheme)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var live: LiveUpdates

    var body: some View {
        if let vk = store.vk, let acc = store.active {
            TabView {
                Tab("Чаты", systemImage: "bubble.left.and.bubble.right.fill") {
                    ChatListView(vk: vk, ownId: acc.id)
                }
                Tab("Настройки", systemImage: "gearshape.fill") {
                    SettingsView(vk: vk)
                }
            }
            .id(acc.id)
            .onAppear { live.requestAuth(); live.start(vk: vk) }
            .onDisappear { live.stop() }
        } else {
            LoginView(title: "TK") { try await store.addAccount(token: $0) }
        }
    }
}

struct LoginView: View {
    var title = "Добавить аккаунт"
    let onSubmit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var loading = false
    @State private var error: String?
    @State private var showWeb = false
    @State private var showManual = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text(title).font(.largeTitle.bold())
            Text("Войди через VK — токен подхватится сам")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)

            if loading { ProgressView() }

            Button { showWeb = true } label: {
                Label("Войти через VK", systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .disabled(loading)

            Button("Ввести токен вручную") { withAnimation { showManual.toggle() } }
                .font(.footnote)

            if showManual {
                SecureField("access_token", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .padding(.horizontal)
                Button("Войти") { submit(input) }
                    .disabled(loading || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
            Spacer()
        }
        .padding()
        .sheet(isPresented: $showWeb) {
            NavigationStack {
                VKAuthWeb { token in showWeb = false; submit(token) }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Вход VK").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Отмена") { showWeb = false } } }
            }
        }
    }

    private func submit(_ token: String) {
        Task {
            loading = true; error = nil
            do { try await onSubmit(token); dismiss() }
            catch let e as VKError { error = e.error_msg }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
