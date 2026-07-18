import Foundation

// MARK: - Wire models (only fields we use)

struct VKError: Decodable, Error { let error_code: Int; let error_msg: String }
struct VKResponse<T: Decodable>: Decodable { let response: T?; let error: VKError? }

struct Profile: Decodable, Identifiable {
    let id: Int
    let first_name: String
    let last_name: String
    var photo_100: String?
    var photo_200: String?
    var online: Int?
    var last_seen: LastSeen?
    var status: String?
    var screen_name: String?
    var city: City?
    var is_closed: Bool?
    struct LastSeen: Decodable { let time: Int }
    struct City: Decodable { let title: String }
    var fullName: String { "\(first_name) \(last_name)" }
    var avatar: URL? { (photo_200 ?? photo_100).flatMap(URL.init(string:)) }
}

struct Group: Decodable {
    let id: Int
    let name: String
    var photo_100: String?
    var photo_200: String?
    var screen_name: String?
}

struct AttachmentImage: Decodable { let url: String; let width: Int }
struct Attachment: Decodable {
    let type: String
    let sticker: Sticker?
    let photo: Photo?
    let doc: Doc?
    struct Sticker: Decodable { let images: [AttachmentImage] }
    struct Photo: Decodable { let sizes: [AttachmentImage] }
    struct Doc: Decodable { let title: String?; let url: String?; let ext: String?; let size: Int? }
}

struct Msg: Decodable, Identifiable {
    let id: Int
    let from_id: Int
    let text: String
    let date: Int
    var attachments: [Attachment]?
    var reply_message: Reply?
    var fwd_messages: [Reply]?
    struct Reply: Decodable { let from_id: Int; let text: String }

    var stickerURL: URL? {
        guard let img = (attachments ?? []).first(where: { $0.type == "sticker" })?
            .sticker?.images.max(by: { $0.width < $1.width }) else { return nil }
        return URL(string: img.url)
    }
    var photoURL: URL? {
        guard let img = (attachments ?? []).first(where: { $0.type == "photo" })?
            .photo?.sizes.max(by: { $0.width < $1.width }) else { return nil }
        return URL(string: img.url)
    }
    var doc: Attachment.Doc? { (attachments ?? []).first(where: { $0.type == "doc" })?.doc }

    // A human preview for the chat list when text is empty.
    var preview: String {
        if !text.isEmpty { return text }
        if stickerURL != nil { return "🩷 Стикер" }
        if photoURL != nil { return "🖼 Фото" }
        if let d = doc { return "📎 " + (d.title ?? "Файл") }
        if fwd_messages?.isEmpty == false { return "↪️ Пересланное" }
        return ""
    }
}

struct HistoryResponse: Decodable {
    let items: [Msg]
    let profiles: [Profile]?
    let groups: [Group]?
}

struct Conversations: Decodable {
    let items: [ConvItem]
    let profiles: [Profile]?
    let groups: [Group]?
}
struct ConvItem: Decodable { let conversation: Conv; let last_message: Msg? }
struct Conv: Decodable {
    let peer: Peer
    let chat_settings: ChatSettings?
    struct ChatSettings: Decodable {
        let title: String?
        let photo: Ph?
        struct Ph: Decodable { let photo_100: String? }
    }
}
struct Peer: Decodable { let id: Int; let type: String }

struct FriendsResponse: Decodable { let count: Int; let items: [Profile] }
struct LongPollServer: Decodable { let server: String; let key: String; let ts: Int }

// A resolved chat-list row.
struct ChatRow: Identifiable, Hashable {
    let peerId: Int
    let title: String
    let subtitle: String
    let date: Int
    let avatar: URL?
    let online: Bool
    var isChat: Bool { peerId >= 2_000_000_000 }
    var id: Int { peerId }
    static func == (a: ChatRow, b: ChatRow) -> Bool { a.peerId == b.peerId }
    func hash(into h: inout Hasher) { h.combine(peerId) }
}

// A message plus its resolved sender (for group chats / replies).
struct ChatMessage: Identifiable {
    let msg: Msg
    let senderName: String
    let senderAvatar: URL?
    let replyAuthor: String?
    var id: Int { msg.id }
}

// MARK: - API client

struct VK {
    static let base = "https://api.vk.com/method/"
    static let version = "5.199"
    let token: String

    // Build a name/avatar directory from extended profiles + groups.
    private func directory(_ profiles: [Profile]?, _ groups: [Group]?) -> (names: [Int: String], avatars: [Int: URL]) {
        var names: [Int: String] = [:], avatars: [Int: URL] = [:]
        for p in profiles ?? [] { names[p.id] = p.fullName; avatars[p.id] = p.avatar }
        for g in groups ?? [] {
            names[-g.id] = g.name
            avatars[-g.id] = (g.photo_100).flatMap(URL.init(string:))
        }
        return (names, avatars)
    }

    private func call<T: Decodable>(_ method: String, _ params: [String: String]) async throws -> T {
        var comps = URLComponents()
        var q = params
        q["access_token"] = token
        q["v"] = VK.version
        comps.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: URL(string: VK.base + method)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let wrapped = try JSONDecoder().decode(VKResponse<T>.self, from: data)
        if let e = wrapped.error { throw e }
        guard let r = wrapped.response else { throw VKError(error_code: -1, error_msg: "Пустой ответ") }
        return r
    }

    // MARK: Chats

    func conversations() async throws -> [ChatRow] {
        let c: Conversations = try await call("messages.getConversations",
            ["extended": "1", "count": "100", "fields": "photo_100,online"])
        let (names, avatars) = directory(c.profiles, c.groups)
        let onlineIds = Set((c.profiles ?? []).filter { $0.online == 1 }.map { $0.id })
        return c.items.map { item in
            let peer = item.conversation.peer
            let title: String
            let avatar: URL?
            switch peer.type {
            case "user", "group":
                title = names[peer.id] ?? "id\(peer.id)"
                avatar = avatars[peer.id]
            default:
                title = item.conversation.chat_settings?.title ?? "Беседа"
                avatar = item.conversation.chat_settings?.photo?.photo_100.flatMap(URL.init(string:))
            }
            return ChatRow(peerId: peer.id, title: title,
                           subtitle: item.last_message?.preview ?? "",
                           date: item.last_message?.date ?? 0,
                           avatar: avatar, online: onlineIds.contains(peer.id))
        }
    }

    func history(peerId: Int) async throws -> [ChatMessage] {
        let h: HistoryResponse = try await call("messages.getHistory",
            ["peer_id": String(peerId), "count": "80", "extended": "1", "fields": "photo_100"])
        return resolve(h.items.reversed(), h.profiles, h.groups)
    }

    func search(peerId: Int, query: String) async throws -> [ChatMessage] {
        let h: HistoryResponse = try await call("messages.search",
            ["peer_id": String(peerId), "q": query, "count": "100", "extended": "1", "fields": "photo_100"])
        return resolve(h.items, h.profiles, h.groups)
    }

    private func resolve(_ items: [Msg], _ profiles: [Profile]?, _ groups: [Group]?) -> [ChatMessage] {
        let (names, avatars) = directory(profiles, groups)
        return items.map { m in
            ChatMessage(msg: m,
                        senderName: names[m.from_id] ?? "id\(m.from_id)",
                        senderAvatar: avatars[m.from_id],
                        replyAuthor: m.reply_message.flatMap { names[$0.from_id] })
        }
    }

    func send(peerId: Int, text: String, replyTo: Int? = nil, attachment: String? = nil) async throws {
        var p = ["peer_id": String(peerId), "message": text,
                 "random_id": String(Int32.random(in: 1...Int32.max))]
        if let replyTo { p["reply_to"] = String(replyTo) }
        if let attachment { p["attachment"] = attachment }
        let _: Int = try await call("messages.send", p)
    }

    func setActivity(peerId: Int) async {
        let _: Int? = try? await call("messages.setActivity",
            ["peer_id": String(peerId), "type": "typing"])
    }

    // MARK: Users & friends

    func user(id: Int?) async throws -> Profile {
        var p = ["fields": "photo_200,photo_100,online,last_seen,status,screen_name,city,is_closed"]
        if let id { p["user_ids"] = String(id) }
        let arr: [Profile] = try await call("users.get", p)
        guard let u = arr.first else { throw VKError(error_code: -1, error_msg: "Нет пользователя") }
        return u
    }

    func friends(userId: Int) async throws -> [Profile] {
        let r: FriendsResponse = try await call("friends.get",
            ["user_id": String(userId), "count": "1000", "fields": "photo_100,online"])
        return r.items
    }

    // MARK: Uploads

    func uploadPhoto(peerId: Int, data: Data) async throws -> String {
        struct Up: Decodable { let upload_url: String }
        let up: Up = try await call("photos.getMessagesUploadServer", ["peer_id": String(peerId)])
        struct Uploaded: Decodable { let server: Int; let photo: String; let hash: String }
        let u: Uploaded = try await multipart(up.upload_url, field: "photo",
                                              filename: "image.jpg", mime: "image/jpeg", data: data)
        struct Saved: Decodable { let owner_id: Int; let id: Int }
        let saved: [Saved] = try await call("photos.saveMessagesPhoto",
            ["server": String(u.server), "photo": u.photo, "hash": u.hash])
        guard let s = saved.first else { throw VKError(error_code: -1, error_msg: "upload failed") }
        return "photo\(s.owner_id)_\(s.id)"
    }

    func uploadDoc(peerId: Int, data: Data, name: String) async throws -> String {
        struct Up: Decodable { let upload_url: String }
        let up: Up = try await call("docs.getMessagesUploadServer",
            ["peer_id": String(peerId), "type": "doc"])
        struct Uploaded: Decodable { let file: String }
        let u: Uploaded = try await multipart(up.upload_url, field: "file",
                                              filename: name, mime: "application/octet-stream", data: data)
        struct SaveResp: Decodable { let doc: D; struct D: Decodable { let owner_id: Int; let id: Int } }
        let saved: SaveResp = try await call("docs.save", ["file": u.file])
        return "doc\(saved.doc.owner_id)_\(saved.doc.id)"
    }

    private func multipart<T: Decodable>(_ urlString: String, field: String, filename: String,
                                         mime: String, data: Data) async throws -> T {
        let boundary = "----vkphaz\(Int32.random(in: 0...Int32.max))"
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body
        let (respData, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: respData)
    }

    // MARK: Long poll

    func longPollServer() async throws -> LongPollServer {
        try await call("messages.getLongPollServer", ["lp_version": "3", "need_pts": "0"])
    }
}
