import SwiftUI

struct SettingsView: View {
    let vk: VK
    @EnvironmentObject var store: AccountStore
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("Аккаунты") {
                    ForEach(store.accounts) { acc in
                        Button { store.switchTo(acc.id) } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: acc.photo.flatMap(URL.init(string:)), name: acc.name, id: acc.id, size: 40)
                                Text(acc.name).foregroundStyle(.primary)
                                Spacer()
                                if acc.id == store.activeId {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.remove(acc.id) } label: {
                                Label("Выйти", systemImage: "trash")
                            }
                        }
                    }
                    Button { showAdd = true } label: { Label("Добавить аккаунт", systemImage: "plus") }
                }

                Section {
                    NavigationLink {
                        ProfileView(vk: vk, userId: store.activeId ?? 0, ownId: store.activeId ?? 0)
                    } label: { Label("Мой профиль", systemImage: "person.crop.circle") }
                }

                Section("Настройки") {
                    NavigationLink { AppearanceSettings() } label: { row("Оформление", "paintbrush.fill", .pink) }
                    NavigationLink { WallpaperSettings() } label: { row("Обои чатов", "photo.fill", .teal) }
                    NavigationLink { NotificationSettings() } label: { row("Уведомления", "bell.fill", .red) }
                    NavigationLink { AISettings() } label: { row("Нейросеть", "sparkles", .purple) }
                }

                Section {
                    Text("TK — неофициальный клиент VK. Токены и данные хранятся только на этом устройстве.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .sheet(isPresented: $showAdd) { LoginView { try await store.addAccount(token: $0) } }
        }
    }

    private func row(_ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.footnote).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
            Text(title)
        }
    }
}

struct AppearanceSettings: View {
    @AppStorage("accentHex") private var accentHex = "#3A8DFF"
    @AppStorage("appearance") private var appearance = 0
    var body: some View {
        List {
            Section("Тема") {
                Picker("Тема", selection: $appearance) {
                    Text("Система").tag(0); Text("Светлая").tag(1); Text("Тёмная").tag(2)
                }.pickerStyle(.segmented)
            }
            Section("Акцент") {
                HStack(spacing: 14) {
                    ForEach(accentPresets, id: \.hex) { preset in
                        Circle().fill(Color(hex: preset.hex) ?? .blue)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.primary, lineWidth: accentHex == preset.hex ? 2 : 0).padding(-3))
                            .onTapGesture { accentHex = preset.hex }
                    }
                }.padding(.vertical, 4)
            }
        }
        .navigationTitle("Оформление").navigationBarTitleDisplayMode(.inline)
    }
}

struct WallpaperSettings: View {
    @AppStorage("wallpaper") private var wallpaper = 0
    var body: some View {
        List {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(Wallpaper.presets) { p in
                        VStack(spacing: 6) {
                            swatch(p).frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentColor, lineWidth: wallpaper == p.id ? 3 : 0))
                                .onTapGesture { wallpaper = p.id }
                            Text(p.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 6)
            } footer: {
                Text("Отдельному чату можно поставить свою картинку в меню по тапу на имя внутри чата.")
            }
        }
        .navigationTitle("Обои чатов").navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private func swatch(_ p: WPPreset) -> some View {
        if p.colors.isEmpty { Color(.systemBackground) }
        else { LinearGradient(colors: p.colors, startPoint: .top, endPoint: .bottom) }
    }
}

struct NotificationSettings: View {
    @AppStorage("notifsEnabled") private var notifs = true
    @AppStorage("tg_target") private var tgTarget = ""
    @State private var tgToken = Keychain.get("tg_bot_token") ?? ""
    var body: some View {
        List {
            Section { Toggle("Локальные уведомления", isOn: $notifs) }
            Section {
                SecureField("Токен Telegram-бота", text: $tgToken)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: tgToken) { _ in Keychain.set(tgToken, for: "tg_bot_token") }
                TextField("chat_id или @канал", text: $tgTarget)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: { Text("Уведомления в Telegram") }
            footer: { Text("Создай бота у @BotFather, вставь токен и свой chat_id (у @userinfobot; сначала напиши /start боту). Работает пока приложение открыто. Для уведомлений при закрытом приложении — см. server/ в репозитории.") }
        }
        .navigationTitle("Уведомления").navigationBarTitleDisplayMode(.inline)
    }
}

struct AISettings: View {
    @StateObject private var local = LocalLLM.shared
    @State private var geminiKey = Keychain.get("gemini_key") ?? ""

    var body: some View {
        List {
            Section {
                if local.isDownloaded {
                    Label("Локальная модель загружена", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button(role: .destructive) { local.delete() } label: { Text("Удалить модель") }
                } else if local.downloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: local.progress)
                        Text(local.status).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button { local.startDownload() } label: {
                        Label("Скачать локальную модель (~400 МБ)", systemImage: "arrow.down.circle.fill")
                    }
                }
            } header: { Text("Локальная модель") }
            footer: {
                Text("Работает на любом телефоне без интернета и лимитов, данные не уходят. Модель Qwen2.5-0.5B. Маленькая и медленная — свод большого чата собирается долго.")
            }

            if AIEngine.onDeviceReady {
                Section { Label("Apple Intelligence на устройстве доступна", systemImage: "apple.logo") }
                    footer: { Text("Если локальная модель не скачана — используется системная модель Apple.") }
            }

            Section {
                SecureField("Gemini API-ключ", text: $geminiKey)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: geminiKey) { _ in Keychain.set(geminiKey, for: "gemini_key") }
            } header: { Text("Gemini (запасной вариант)") }
            footer: { Text("Ключ с aistudio.google.com. Используется, только если нет локальной и системной модели. Текст чата уходит в Google.") }
        }
        .navigationTitle("Нейросеть").navigationBarTitleDisplayMode(.inline)
    }
}
