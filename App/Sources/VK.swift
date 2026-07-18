import Foundation

// MARK: - Wire models (only fields we use)

struct VKError: Decodable, Error { let error_code: Int; let error_msg: String }
struct VKResponse<T: Decodable>: Decodable { let response: T?; let error: VKError? }
struct VKIgnored: Decodable {}  // for responses whose body we don't need

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

struct VKGroup: Decodable {
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
    let audio_message: AudioMessage?
    struct Sticker: Decodable { let images: [AttachmentImage] }
    struct Photo: Decodable { let sizes: [AttachmentImage] }
    struct Doc: Decodable { let title: String?; let url: String?; let ext: String?; let size: Int? }
    struct AudioMessage: Decodable { let duration: Int?; let link_mp3: String?; let link_ogg: String? }
}

struct Msg: Decodable, Identifiable {
    let id: Int
    let from_id: Int
    let text: String
    let date: Int
    var conversation_message_id: Int?
    var attachments: [Attachment]?
    var reply_message: Reply?
    var fwd_messages: [Reply]?
    var reactions: [Reaction]?
    struct Reply: Decodable { let from_id: Int; let text: String }
    struct Reaction: Decodable { let reaction_id: Int; let count: Int }

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
    var voice: Attachment.AudioMessage? {
        (attachments ?? []).first(where: { $0.type == "audio_message" })?.audio_message
    }

    // A human preview for the chat list when text is empty.
    var preview: String {
        if !text.isEmpty { return text }
        if stickerURL != nil { return "🩷 Стикер" }
        if photoURL != nil { return "🖼 Фото" }
        if voice != nil { return "🎤 Голосовое" }
        if let d = doc { return "📎 " + (d.title ?? "Файл") }
        if fwd_messages?.isEmpty == false { return "↪️ Пересланное" }
        return ""
    }
}

struct HistoryResponse: Decodable {
    let count: Int?
    let items: [Msg]
    let profiles: [Profile]?
    let groups: [VKGroup]?
}

struct Conversations: Decodable {
    let items: [ConvItem]
    let profiles: [Profile]?
    let groups: [VKGroup]?
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

struct StickerItem: Decodable, Identifiable {
    let sticker_id: Int
    let images: [AttachmentImage]?
    var id: Int { sticker_id }
    var url: URL? {
        guard let img = (images ?? []).max(by: { $0.width < $1.width }) else { return nil }
        return URL(string: img.url)
    }
}
struct StoreProducts: Decodable {
    let items: [Product]
    struct Product: Decodable { let id: Int?; let title: String?; let stickers: [StickerItem]? }
}
struct StickerPack: Identifiable {
    let id: Int
    let title: String
    let stickers: [StickerItem]
}

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
    private func directory(_ profiles: [Profile]?, _ groups: [VKGroup]?) -> (names: [Int: String], avatars: [Int: URL]) {
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

    // For AI summarization: a page of history, oldest-first, at an offset from the newest.
    func historyPage(peerId: Int, offset: Int, count: Int = 200) async throws -> [ChatMessage] {
        let h: HistoryResponse = try await call("messages.getHistory",
            ["peer_id": String(peerId), "count": String(count), "offset": String(offset),
             "extended": "1", "fields": "photo_100"])
        return resolve(h.items.reversed(), h.profiles, h.groups)
    }

    func historyTotal(peerId: Int) async throws -> Int {
        let h: HistoryResponse = try await call("messages.getHistory",
            ["peer_id": String(peerId), "count": "1"])
        return h.count ?? 0
    }

    // A window of messages centered on a specific message (for in-chat search jump).
    func historyAround(peerId: Int, messageId: Int, count: Int = 40) async throws -> [ChatMessage] {
        let h: HistoryResponse = try await call("messages.getHistory",
            ["peer_id": String(peerId), "start_message_id": String(messageId),
             "offset": String(-count / 2), "count": String(count),
             "extended": "1", "fields": "photo_100"])
        return resolve(h.items.reversed(), h.profiles, h.groups)
    }

    // Search returns matching message ids, oldest-first, for stepping through in the chat.
    func searchIds(peerId: Int, query: String) async throws -> [Int] {
        let h: HistoryResponse = try await call("messages.search",
            ["peer_id": String(peerId), "q": query, "count": "200"])
        return h.items.map { $0.id }.sorted()
    }

    func search(peerId: Int, query: String, before: Date? = nil) async throws -> [ChatMessage] {
        var p = ["peer_id": String(peerId), "q": query, "count": "100",
                 "extended": "1", "fields": "photo_100"]
        if let before {
            let f = DateFormatter()
            f.dateFormat = "ddMMyyyy"
            p["date"] = f.string(from: before)   // VK: только сообщения до этой даты
        }
        let h: HistoryResponse = try await call("messages.search", p)
        return resolve(h.items, h.profiles, h.groups)
    }

    private func resolve(_ items: [Msg], _ profiles: [Profile]?, _ groups: [VKGroup]?) -> [ChatMessage] {
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

    func sendSticker(peerId: Int, stickerId: Int) async throws {
        let _: Int = try await call("messages.send",
            ["peer_id": String(peerId), "sticker_id": String(stickerId),
             "random_id": String(Int32.random(in: 1...Int32.max))])
    }

    func sendReaction(peerId: Int, cmid: Int, reactionId: Int) async throws {
        let _: Int = try await call("messages.sendReaction",
            ["peer_id": String(peerId), "cmid": String(cmid), "reaction_id": String(reactionId)])
    }

    func deleteMessages(peerId: Int, cmids: [Int], forAll: Bool) async throws {
        let p = ["peer_id": String(peerId),
                 "cmids": cmids.map(String.init).joined(separator: ","),
                 "delete_for_all": forAll ? "1" : "0"]
        let _: VKIgnored = try await call("messages.delete", p)
    }

    func deleteReaction(peerId: Int, cmid: Int) async throws {
        let _: VKIgnored = try await call("messages.deleteReaction",
            ["peer_id": String(peerId), "cmid": String(cmid)])
    }

    // Last outgoing message id the peer has read. A message id <= this is "read" (✓✓).
    func outRead(peerId: Int) async throws -> Int {
        struct R: Decodable { let items: [Item]?; struct Item: Decodable { let out_read: Int? } }
        let r: R = try await call("messages.getConversationsById", ["peer_ids": String(peerId)])
        return r.items?.first?.out_read ?? 0
    }

    func forward(peerId: Int, messageIds: [Int]) async throws {
        let _: Int = try await call("messages.send",
            ["peer_id": String(peerId),
             "forward_messages": messageIds.map(String.init).joined(separator: ","),
             "random_id": String(Int32.random(in: 1...Int32.max))])
    }

    func pinMessage(peerId: Int, cmid: Int) async throws {
        let _: VKIgnored = try await call("messages.pin",
            ["peer_id": String(peerId), "conversation_message_id": String(cmid)])
    }

    func stickers() async throws -> [StickerItem] {
        try await stickerPacks().flatMap { $0.stickers }
    }

    func stickerPacks() async throws -> [StickerPack] {
        let r: StoreProducts = try await call("store.getProducts",
            ["type": "stickers", "filters": "purchased,active", "extended": "1"])
        return r.items.enumerated().compactMap { i, prod in
            let items = prod.stickers ?? []
            guard !items.isEmpty else { return nil }
            return StickerPack(id: prod.id ?? i, title: prod.title ?? "Стикеры", stickers: items)
        }
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
        try await uploadDocTyped(peerId: peerId, data: data, name: name, type: "doc",
                                 field: "file", mime: "application/octet-stream")
    }

    // VK voice message: upload as an audio_message doc (m4a). May render as a file if VK rejects the codec.
    func uploadVoice(peerId: Int, data: Data) async throws -> String {
        try await uploadDocTyped(peerId: peerId, data: data, name: "voice.m4a",
                                 type: "audio_message", field: "file", mime: "audio/m4a")
    }

    private func uploadDocTyped(peerId: Int, data: Data, name: String, type: String,
                                field: String, mime: String) async throws -> String {
        struct Up: Decodable { let upload_url: String }
        let up: Up = try await call("docs.getMessagesUploadServer",
            ["peer_id": String(peerId), "type": type])
        struct Uploaded: Decodable { let file: String }
        let u: Uploaded = try await multipart(up.upload_url, field: field,
                                              filename: name, mime: mime, data: data)
        struct SaveResp: Decodable {
            let type: String?
            let doc: D?
            let audio_message: D?
            struct D: Decodable { let owner_id: Int; let id: Int }
        }
        let saved: SaveResp = try await call("docs.save", ["file": u.file])
        if let am = saved.audio_message { return "doc\(am.owner_id)_\(am.id)" }
        if let d = saved.doc { return "doc\(d.owner_id)_\(d.id)" }
        throw VKError(error_code: -1, error_msg: "upload failed")
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
