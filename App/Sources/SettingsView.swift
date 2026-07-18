import SwiftUI

struct SettingsView: View {
    let vk: VK
    @EnvironmentObject var store: AccountStore
    @AppStorage("accentHex") private var accentHex = "#3A8DFF"
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("notifsEnabled") private var notifs = true
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

                Section("Уведомления") {
                    Toggle("Уведомления о сообщениях", isOn: $notifs)
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
}
