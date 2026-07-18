import Foundation

// --- Wire models (only the fields we use) ---
struct VKResponse<T: Decodable>: Decodable { let response: T?; let error: VKError? }
struct VKError: Decodable, Error { let error_code: Int; let error_msg: String }

struct Conversations: Decodable {
    let items: [ConvItem]
    let profiles: [Profile]?
    let groups: [Group]?
}
struct ConvItem: Decodable { let conversation: Conversation; let last_message: Message? }
struct Conversation: Decodable { let peer: Peer; let chat_settings: ChatSettings? }
struct Peer: Decodable { let id: Int; let type: String }
struct ChatSettings: Decodable { let title: String? }
struct Message: Decodable {
    let from_id: Int
    let text: String
    let date: Int
    var uiId: String { "\(from_id)-\(date)-\(text.hashValue)" }
}
struct Profile: Decodable { let id: Int; let first_name: String; let last_name: String; let photo_100: String? }
struct Group: Decodable { let id: Int; let name: String; let photo_100: String? }
struct History: Decodable { let items: [Message] }

// A resolved row for the chat list.
struct ChatRow: Identifiable {
    let peerId: Int
    let title: String
    let subtitle: String
    let date: Int
    let avatar: URL?
    var id: Int { peerId }
}

// ponytail: single struct, no networking layer — VK is one host, one shape.
struct VK {
    static let base = "https://api.vk.com/method/"
    static let version = "5.199"
    let token: String

    private func call<T: Decodable>(_ method: String, _ params: [String: String]) async throws -> T {
        var comps = URLComponents(string: VK.base + method)!
        var q = params
        q["access_token"] = token
        q["v"] = VK.version
        comps.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Send secrets in the body, not the URL query, so they don't land in logs/caches.
        var req = URLRequest(url: URL(string: VK.base + method)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let wrapped = try JSONDecoder().decode(VKResponse<T>.self, from: data)
        if let e = wrapped.error { throw e }
        guard let r = wrapped.response else { throw VKError(error_code: -1, error_msg: "empty response") }
        return r
    }

    func conversations() async throws -> [ChatRow] {
        let c: Conversations = try await call("messages.getConversations",
            ["extended": "1", "count": "100", "fields": "photo_100"])
        let profiles = Dictionary(uniqueKeysWithValues: (c.profiles ?? []).map { ($0.id, $0) })
        let groups = Dictionary(uniqueKeysWithValues: (c.groups ?? []).map { ($0.id, $0) })
        return c.items.map { item in
            let peer = item.conversation.peer
            return resolveRow(peer: peer, settings: item.conversation.chat_settings,
                       last: item.last_message, profiles: profiles, groups: groups)
        }
    }

    func history(peerId: Int) async throws -> [Message] {
        let h: History = try await call("messages.getHistory",
            ["peer_id": String(peerId), "count": "50", "rev": "0"])
        return h.items.reversed()  // oldest first for a chat view
    }

    func send(peerId: Int, text: String) async throws {
        let rid = Int32.random(in: 1...Int32.max)
        let _: Int = try await call("messages.send",
            ["peer_id": String(peerId), "message": text, "random_id": String(rid)])
    }
}

// Pure resolution — testable without the network. See selfCheck() below.
func resolveRow(peer: Peer, settings: ChatSettings?, last: Message?,
                profiles: [Int: Profile], groups: [Int: Group]) -> ChatRow {
    let title: String
    let avatar: URL?
    switch peer.type {
    case "user":
        let p = profiles[peer.id]
        title = p.map { "\($0.first_name) \($0.last_name)" } ?? "id\(peer.id)"
        avatar = p?.photo_100.flatMap(URL.init(string:))
    case "group":
        let g = groups[abs(peer.id)]
        title = g?.name ?? "club\(abs(peer.id))"
        avatar = g?.photo_100.flatMap(URL.init(string:))
    default: // "chat"
        title = settings?.title ?? "Беседа"
        avatar = nil
    }
    return ChatRow(peerId: peer.id, title: title,
                   subtitle: last?.text ?? "", date: last?.date ?? 0, avatar: avatar)
}

#if DEBUG
// ponytail: one runnable check for the only branchy logic here.
func selfCheck() {
    let p = Peer(id: 42, type: "user")
    let row = resolveRow(peer: p, settings: nil, last: nil,
                         profiles: [42: Profile(id: 42, first_name: "Ada", last_name: "L", photo_100: nil)],
                         groups: [:])
    assert(row.title == "Ada L")
    let g = resolveRow(peer: Peer(id: -7, type: "group"), settings: nil, last: nil,
                       profiles: [:], groups: [7: Group(id: 7, name: "Club", photo_100: nil)])
    assert(g.title == "Club")
}
#endif
