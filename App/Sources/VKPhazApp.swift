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
    @State private var tab = 0

    var body: some View {
        if let vk = store.vk, let acc = store.active {
            Group {
                if tab == 0 { ChatListView(vk: vk, ownId: acc.id, tab: $tab) }
                else { SettingsView(vk: vk, tab: $tab) }
            }
            .id(acc.id)
            .onAppear { live.requestAuth(); live.start(vk: vk) }
            .onDisappear { live.stop() }
        } else {
            LoginView(title: "TK") { try await store.addAccount(token: $0) }
        }
    }
}

struct GlassTabBar: View {
    @Binding var tab: Int
    var body: some View {
        HStack(spacing: 4) {
            item(0, "bubble.left.and.bubble.right.fill", "Чаты")
            item(1, "gearshape.fill", "Настройки")
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, 4)
    }

    private func item(_ i: Int, _ icon: String, _ label: String) -> some View {
        Button { tab = i } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(tab == i ? Color.accentColor : .secondary)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(tab == i ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
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

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text(title).font(.largeTitle.bold())
            Text("Вставь access_token аккаунта VK")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("access_token", text: $input)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(.horizontal)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button {
                Task {
                    loading = true; error = nil
                    do { try await onSubmit(input); dismiss() }
                    catch let e as VKError { error = e.error_msg }
                    catch { self.error = error.localizedDescription }
                    loading = false
                }
            } label: {
                if loading { ProgressView() } else { Text("Войти").bold() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(loading || input.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding()
    }
}
