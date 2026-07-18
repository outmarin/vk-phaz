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
    @EnvironmentObject var store: AccountStore
    @AppStorage("notifsEnabled") private var notifs = true
    @AppStorage("tg_target") private var tgTarget = ""
    @AppStorage("notifyServer") private var server = "http://178.105.123.75:8787"
    @AppStorage("serverNotifyEnabled") private var serverOn = false
    @State private var tgToken = Keychain.get("tg_bot_token") ?? ""
    @State private var showConsent = false
    @State private var status = ""

    private var canServer: Bool {
        !tgToken.isEmpty && !tgTarget.isEmpty && store.active != nil
    }

    var body: some View {
        List {
            Section { Toggle("Локальные уведомления", isOn: $notifs) }
                footer: { Text("Приходят пока приложение открыто.") }

            Section {
                SecureField("Токен Telegram-бота", text: $tgToken)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: tgToken) { _ in Keychain.set(tgToken, for: "tg_bot_token") }
                TextField("chat_id или @канал", text: $tgTarget)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: { Text("Telegram-бот") }
            footer: { Text("Создай бота у @BotFather, вставь токен и свой chat_id (у @userinfobot; сначала напиши /start боту).") }

            Section {
                TextField("Адрес сервера", text: $server)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if serverOn {
                    Label("Включено — сервер мониторит под вашим аккаунтом", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.footnote)
                    Button(role: .destructive) { Task { await disable() } } label: { Text("Выключить на сервере") }
                } else {
                    Button { showConsent = true } label: { Label("Включить уведомления при закрытом приложении", systemImage: "server.rack") }
                        .disabled(!canServer)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Сервер (при закрытом приложении)") }
            footer: { Text("Сервер держит подключение к VK вместо телефона и шлёт входящие в ваш Telegram. Токен передаётся на сервер и хранится там в зашифрованном виде. Заполни бота и chat_id выше.") }
        }
        .navigationTitle("Уведомления").navigationBarTitleDisplayMode(.inline)
        .alert("Разрешить мониторинг?", isPresented: $showConsent) {
            Button("Отмена", role: .cancel) {}
            Button("Разрешить") { Task { await enable() } }
        } message: {
            Text("Сервер будет под вашим аккаунтом VK читать входящие сообщения и пересылать их в ваш Telegram — чтобы уведомления приходили при закрытом приложении. Ваш VK-токен будет храниться на сервере в зашифрованном виде. Согласны?")
        }
    }

    private func enable() async {
        guard let token = store.active?.token else { return }
        status = "Подключаю к серверу…"
        do {
            try await NotifierServer.register(vkToken: token, tgBot: tgToken, tgChat: tgTarget)
            serverOn = true; status = "Готово"
        } catch let e as VKError { status = e.error_msg }
        catch { status = error.localizedDescription }
    }

    private func disable() async {
        guard let token = store.active?.token else { return }
        status = "Отключаю…"
        do { try await NotifierServer.unregister(vkToken: token); serverOn = false; status = "Выключено" }
        catch { status = "Ошибка отключения" }
    }
}

struct AISettings: View {
    @StateObject private var local = LocalLLM.shared
    @AppStorage("aiProvider") private var providerRaw = ""
    @AppStorage("openrouter_model") private var orModel = "openai/gpt-4o-mini"
    @State private var geminiKey = Keychain.get("gemini_key") ?? ""
    @State private var orKey = Keychain.get("openrouter_key") ?? ""

    var body: some View {
        List {
            Section {
                Picker("Провайдер", selection: $providerRaw) {
                    Text("Авто (\(AIEngine.autoDefault.title))").tag("")
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: { Text("Что использовать") }
            footer: { Text("«Авто» само берёт лучшее из доступного: локальная → Apple → Gemini → OpenRouter.") }

            Section {
                ForEach(LocalLLM.catalog) { m in modelRow(m) }
            } header: { Text("Локальные модели (на любом телефоне)") }
            footer: { Text("Работают без интернета, ключей и лимитов, данные не уходят. Больше параметров — умнее, но тяжелее и медленнее.") }

            if AIEngine.onDeviceReady {
                Section { Label("Apple Intelligence доступна", systemImage: "apple.logo") }
            }

            Section {
                SecureField("Gemini API-ключ", text: $geminiKey)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: geminiKey) { _ in Keychain.set(geminiKey, for: "gemini_key") }
            } header: { Text("Gemini") } footer: { Text("Ключ с aistudio.google.com.") }

            Section {
                SecureField("OpenRouter API-ключ", text: $orKey)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: orKey) { _ in Keychain.set(orKey, for: "openrouter_key") }
                TextField("Модель (напр. openai/gpt-4o-mini)", text: $orModel)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: { Text("OpenRouter") }
            footer: { Text("Ключ с openrouter.ru/openrouter.ai. Доступ к десяткам моделей (в т.ч. бесплатным). Текст чата уходит на их серверы.") }
        }
        .navigationTitle("Нейросеть").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func modelRow(_ m: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.body)
                    Text("~\(m.sizeMB) МБ · \(m.fitLabel)")
                        .font(.caption).foregroundStyle(m.fits ? Color.secondary : Color.orange)
                }
                Spacer()
                if local.isDownloaded(m.id) {
                    if local.activeId == m.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Выбрать") { local.setActive(m.id) }
                    }
                } else if local.downloadingId == m.id {
                    EmptyView()
                } else {
                    Button { local.download(m) } label: { Image(systemName: "arrow.down.circle") }
                        .disabled(local.downloadingId != nil)
                }
            }
            if local.downloadingId == m.id {
                ProgressView(value: local.progress)
                Text("\(Int(local.progress * 100))%  ·  \(local.speed)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if local.isDownloaded(m.id) {
                Button(role: .destructive) { local.delete(m.id) } label: {
                    Text("Удалить").font(.caption)
                }
            }
        }
    }
}
