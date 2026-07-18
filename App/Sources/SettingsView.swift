import SwiftUI

struct SettingsView: View {
    let vk: VK
    @EnvironmentObject var store: AccountStore
    @AppStorage("accentHex") private var accentHex = "#3A8DFF"
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("notifsEnabled") private var notifs = true
    @AppStorage("wallpaper") private var wallpaper = 0
    @AppStorage("tg_target") private var tgTarget = ""
    @State private var showAdd = false
    @State private var geminiKey = Keychain.get("gemini_key") ?? ""
    @State private var tgToken = Keychain.get("tg_bot_token") ?? ""

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
                    } label: {
                        Label("Мой профиль", systemImage: "person.crop.circle")
                    }
                }

                Section("Оформление") {
                    Picker("Тема", selection: $appearance) {
                        Text("Система").tag(0)
                        Text("Светлая").tag(1)
                        Text("Тёмная").tag(2)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Акцент").font(.subheadline)
                        HStack(spacing: 14) {
                            ForEach(accentPresets, id: \.hex) { preset in
                                Circle().fill(Color(hex: preset.hex) ?? .blue)
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: accentHex == preset.hex ? 2 : 0).padding(-3))
                                    .onTapGesture { accentHex = preset.hex }
                            }
                        }
                    }
                }

                Section("Обои чата") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Wallpaper.presets) { p in
                                VStack(spacing: 4) {
                                    swatch(p)
                                        .frame(width: 48, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.accentColor, lineWidth: wallpaper == p.id ? 3 : 0))
                                        .onTapGesture { wallpaper = p.id }
                                    Text(p.name).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                    Text("Отдельному чату можно поставить свою картинку в меню «•••» внутри чата.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Уведомления") {
                    Toggle("Локальные уведомления", isOn: $notifs)
                }

                Section {
                    SecureField("Токен Telegram-бота", text: $tgToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: tgToken) { _ in Keychain.set(tgToken, for: "tg_bot_token") }
                    TextField("chat_id или @канал", text: $tgTarget)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: {
                    Text("Уведомления в Telegram")
                } footer: {
                    Text("Создай бота у @BotFather, вставь токен и свой chat_id (узнать у @userinfobot; сначала напиши /start своему боту). Работает пока приложение открыто.")
                }

                Section {
                    SecureField("Gemini API-ключ", text: $geminiKey)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: geminiKey) { _ in Keychain.set(geminiKey, for: "gemini_key") }
                } header: {
                    Text("Нейросеть (Gemini)")
                } footer: {
                    Text("Ключ с aistudio.google.com. Кнопка ✨ в чате даёт ИИ, который читает всю переписку и отвечает на вопросы. Текст чата уходит в Google.")
                }

                Section {
                    Text("TK — неофициальный клиент VK. Токены и данные хранятся только на этом устройстве.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .sheet(isPresented: $showAdd) {
                LoginView { try await store.addAccount(token: $0) }
            }
        }
    }

    @ViewBuilder private func swatch(_ p: WPPreset) -> some View {
        if p.colors.isEmpty {
            Color(.systemBackground)
        } else {
            LinearGradient(colors: p.colors, startPoint: .top, endPoint: .bottom)
        }
    }
}
