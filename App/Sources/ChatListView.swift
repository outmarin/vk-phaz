import SwiftUI

struct ChatListView: View {
    let vk: VK
    let logout: () -> Void
    @State private var rows: [ChatRow] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(rows) { row in
                NavigationLink(value: row) {
                    HStack(spacing: 12) {
                        Avatar(url: row.avatar)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.body.weight(.semibold)).lineLimit(1)
                            Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Чаты")
            .navigationDestination(for: ChatRow.self) { row in
                ChatView(vk: vk, peerId: row.peerId, title: row.title)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Выйти", role: .destructive, action: logout)
                }
            }
            .overlay { if let error { Text(error).foregroundStyle(.red).padding() } }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        do { rows = try await vk.conversations(); error = nil }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }
}

extension ChatRow: Hashable {
    static func == (a: ChatRow, b: ChatRow) -> Bool { a.peerId == b.peerId }
    func hash(into h: inout Hasher) { h.combine(peerId) }
}

struct Avatar: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(.gray.opacity(0.3))
        }
        .frame(width: 48, height: 48).clipShape(Circle())
    }
}
