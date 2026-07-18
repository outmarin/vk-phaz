import SwiftUI

struct ProfileView: View {
    let vk: VK
    let userId: Int
    let ownId: Int
    @State private var profile: Profile?
    @State private var friends: [Profile] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let p = profile {
                VStack(spacing: 12) {
                    AvatarView(url: p.avatar, name: p.fullName, id: p.id, size: 110)
                    Text(p.fullName).font(.title2.bold())
                    if let s = p.screen_name { Text("@\(s)").foregroundStyle(.secondary) }
                    let seen = lastSeenText(online: p.online == 1, ts: p.last_seen?.time)
                    if !seen.isEmpty { Text(seen).font(.subheadline).foregroundStyle(.secondary) }
                    if let st = p.status, !st.isEmpty {
                        Text(st).font(.callout).italic().multilineTextAlignment(.center).padding(.horizontal)
                    }
                    if let c = p.city {
                        Label(c.title, systemImage: "mappin.and.ellipse").font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if userId != ownId {
                            NavigationLink {
                                ChatView(vk: vk, peerId: userId, title: p.fullName, ownId: ownId)
                            } label: {
                                Label("Написать", systemImage: "bubble.left.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent)
                        }
                        Link(destination: URL(string: "https://vk.com/\(p.screen_name ?? "id\(p.id)")")!) {
                            Label("В VK", systemImage: "safari").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }.padding(.horizontal)
                    friendsSection(p)
                }.padding(.vertical)
            } else if loading {
                ProgressView().padding(.top, 60)
            } else if let error {
                Text(error).foregroundStyle(.secondary).padding(.top, 60)
            }
        }
        .navigationTitle(userId == ownId ? "Мой профиль" : "Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder private func friendsSection(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Друзья").font(.headline)
                Spacer()
                if !friends.isEmpty { Text("\(friends.count)").foregroundStyle(.secondary) }
            }.padding(.horizontal)

            if friends.isEmpty && p.is_closed == true && userId != ownId {
                Text("Профиль закрыт").foregroundStyle(.secondary).padding(.horizontal)
            } else if friends.isEmpty {
                Text("Список пуст").foregroundStyle(.secondary).padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(friends) { f in
                            NavigationLink {
                                ProfileView(vk: vk, userId: f.id, ownId: ownId)
                            } label: {
                                VStack(spacing: 4) {
                                    AvatarView(url: f.avatar, name: f.fullName, id: f.id, size: 60, online: f.online == 1)
                                    Text(f.first_name).font(.caption).lineLimit(1).frame(width: 68)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }

    private func load() async {
        loading = true
        do {
            profile = try await vk.user(id: userId == ownId ? nil : userId)
            friends = (try? await vk.friends(userId: userId)) ?? []
            error = nil
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}
