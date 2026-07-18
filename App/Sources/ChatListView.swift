import SwiftUI

struct AvatarView: View {
    let url: URL?
    let name: String
    let id: Int
    var size: CGFloat = 50
    var online = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(avatarTint(for: id).gradient)
                    .overlay(Text(initials(name))
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white))
                if url != nil { CachedImage(url: url, placeholder: .clear) }
            }
            .frame(width: size, height: size).clipShape(Circle())
            if online {
                Circle().fill(.green)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: size * 0.06))
            }
        }
    }
}

struct ChatListView: View {
    let vk: VK
    let ownId: Int
    @Binding var tab: Int
    @EnvironmentObject var live: LiveUpdates
    @State private var rows: [ChatRow] = []
    @State private var query = ""
    @State private var error: String?
    @State private var showOwnProfile = false
    @State private var pinsTick = 0

    private var shown: [ChatRow] {
        _ = pinsTick
        let pins = Pins.get()
        let f = query.isEmpty ? rows
              : rows.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return f.sorted { a, b in
            let pa = pins.contains(a.peerId), pb = pins.contains(b.peerId)
            if pa != pb { return pa }
            return a.date > b.date
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { row in
                    NavigationLink(value: row) { rowView(row) }
                        .swipeActions(edge: .leading) {
                            Button {
                                Pins.toggle(row.peerId); pinsTick += 1
                            } label: {
                                Label(Pins.has(row.peerId) ? "Открепить" : "Закрепить",
                                      systemImage: "pin")
                            }.tint(.orange)
                        }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Чаты")
            .searchable(text: $query, prompt: "Поиск чатов")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showOwnProfile = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: ChatRow(peerId: ownId, title: "Избранное",
                                                  subtitle: "", date: 0, avatar: nil, online: false)) {
                        Image(systemName: "bookmark.circle")
                    }
                }
            }
            .navigationDestination(for: ChatRow.self) { row in
                ChatView(vk: vk, peerId: row.peerId, title: row.title, ownId: ownId)
            }
            .sheet(isPresented: $showOwnProfile) {
                NavigationStack { ProfileView(vk: vk, userId: ownId, ownId: ownId) }
            }
            .overlay { if rows.isEmpty, let error { Text(error).foregroundStyle(.secondary).padding() } }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: live.bump) { _ in Task { await load() } }
            .safeAreaInset(edge: .bottom) { GlassTabBar(tab: $tab) }
        }
    }

    private func rowView(_ row: ChatRow) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: row.avatar, name: row.title, id: row.peerId, online: row.online)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(shortTime(row.date)).font(.caption).foregroundStyle(.secondary)
                if Pins.has(row.peerId) {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do { rows = try await vk.conversations(); error = nil }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }
}
