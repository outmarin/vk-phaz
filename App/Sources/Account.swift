import Foundation

struct Account: Codable, Identifiable, Equatable {
    var id: Int          // VK user id
    var name: String
    var token: String
    var photo: String?
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published var activeId: Int?

    private let key = "vk_accounts"

    init() { load() }

    var active: Account? { accounts.first { $0.id == activeId } }
    var vk: VK? { active.map { VK(token: $0.token) } }

    func addAccount(token: String) async throws {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let me = try await VK(token: t).user(id: nil)
        let acc = Account(id: me.id,
                          name: "\(me.first_name) \(me.last_name)",
                          token: t,
                          photo: me.photo_200 ?? me.photo_100)
        accounts.removeAll { $0.id == acc.id }
        accounts.append(acc)
        activeId = acc.id
        save()
    }

    func switchTo(_ id: Int) { activeId = id; save() }

    func remove(_ id: Int) {
        accounts.removeAll { $0.id == id }
        if activeId == id { activeId = accounts.first?.id }
        save()
    }

    private struct Blob: Codable { let accounts: [Account]; let activeId: Int? }

    private func save() {
        if let d = try? JSONEncoder().encode(Blob(accounts: accounts, activeId: activeId)),
           let s = String(data: d, encoding: .utf8) {
            Keychain.set(s, for: key)
        }
    }

    private func load() {
        guard let s = Keychain.get(key), let d = s.data(using: .utf8),
              let blob = try? JSONDecoder().decode(Blob.self, from: d) else { return }
        accounts = blob.accounts
        activeId = blob.activeId ?? blob.accounts.first?.id
    }
}
