import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private func hhmm(_ ts: Int) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

private func dayLabel(_ ts: Int) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(ts))
    if Calendar.current.isDateInToday(d) { return "Сегодня" }
    if Calendar.current.isDateInYesterday(d) { return "Вчера" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMMM"
    return f.string(from: d)
}

// ponytail: fixed id->emoji table; VK serves reaction art via assets we don't fetch.
let reactionSet: [(id: Int, emoji: String)] = [
    (1, "❤️"), (2, "🔥"), (3, "😆"), (4, "👍"), (5, "👎"), (6, "😢"), (7, "😡"), (8, "👌"),
]
func reactionEmoji(_ id: Int) -> String { reactionSet.first { $0.id == id }?.emoji ?? "👍" }

struct ChatView: View {
    let vk: VK
    let peerId: Int
    let title: String
    let ownId: Int
    @EnvironmentObject var live: LiveUpdates

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var replyingTo: ChatMessage?
    @State private var error: String?
    @State private var peerProfile: Profile?
    @State private var showProfile = false
    @State private var showSearch = false
    @State private var showAttach = false
    @State private var showStickers = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var uploading = false
    @State private var lastTyping = Date.distantPast

    private var isChat: Bool { peerId >= 2_000_000_000 }
    private var isUser: Bool { peerId > 0 && peerId < 2_000_000_000 }

    private var subtitle: String {
        if live.isTyping(peerId) { return "печатает…" }
        if peerId == ownId { return "заметки для себя" }
        guard let p = peerProfile else { return "" }
        return lastSeenText(online: p.online == 1, ts: p.last_seen?.time)
    }

    // Day separators between messages of different days.
    private var timeline: [(cm: ChatMessage, day: String?)] {
        var out: [(ChatMessage, String?)] = []
        var last = ""
        for cm in messages {
            let d = dayLabel(cm.msg.date)
            out.append((cm, d == last ? nil : d))
            last = d
        }
        return out
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.16),
                                    Color.purple.opacity(0.10),
                                    Color.accentColor.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            messageList
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        if let reply = replyingTo { replyBanner(reply) }
                        if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
                        inputBar
                    }
                }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { if isUser && peerId != ownId { showProfile = true } } label: {
                    VStack(spacing: 1) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption2)
                                .foregroundStyle(live.isTyping(peerId) ? Color.accentColor : Color.secondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .glassEffect(in: Capsule())
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .onAppear { live.setActive(peer: peerId) }
        .onDisappear { live.setActive(peer: nil) }
        .task {
            await load()
            if isUser && peerId != ownId { peerProfile = try? await vk.user(id: peerId) }
        }
        .onChange(of: live.bump) { _ in Task { await load() } }
        .sheet(isPresented: $showProfile) {
            NavigationStack { ProfileView(vk: vk, userId: peerId, ownId: ownId) }
        }
        .sheet(isPresented: $showSearch) { MessageSearchSheet(vk: vk, peerId: peerId) }
        .sheet(isPresented: $showAttach) {
            AttachSheet(
                onImageData: { data in showAttach = false; Task { await sendPhoto(data) } },
                onGallery: { showAttach = false; showPhotoPicker = true },
                onFile: { showAttach = false; showFileImporter = true })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStickers) {
            StickerSheet(vk: vk) { sid in Task { await sendSticker(sid) } }
                .presentationDetents([.medium, .large])
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await sendPhoto(data) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await sendFile(url) } }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(timeline, id: \.cm.id) { pair in
                        if let day = pair.day { dayChip(day) }
                        MessageRow(cm: pair.cm, mine: pair.cm.msg.from_id == ownId, isChat: isChat)
                            .id(pair.cm.id)
                            .contextMenu { menu(pair.cm) }
                    }
                    if live.isTyping(peerId) {
                        HStack { TypingDots(); Spacer() }.padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func dayChip(_ day: String) -> some View {
        Text(day)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.vertical, 6)
    }

    @ViewBuilder private func menu(_ cm: ChatMessage) -> some View {
        Section {
            ForEach(reactionSet, id: \.id) { r in
                Button(r.emoji) { Task { await react(cm, r.id) } }
            }
        }
        Button { replyingTo = cm } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
        if !cm.msg.text.isEmpty {
            Button { UIPasteboard.general.string = cm.msg.text } label: {
                Label("Копировать", systemImage: "doc.on.doc")
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button { showAttach = true } label: {
                Image(systemName: "paperclip").font(.title3).foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
            }
            .glassEffect(in: Circle())

            HStack(spacing: 6) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .onChange(of: draft) { _ in sendTyping() }
                Button { showStickers = true } label: {
                    Image(systemName: "face.smiling").font(.title3).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(in: RoundedRectangle(cornerRadius: 22))

            if uploading {
                ProgressView().frame(width: 42, height: 42)
            } else {
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func replyBanner(_ reply: ChatMessage) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.senderName).font(.caption.bold()).foregroundStyle(Color.accentColor)
                Text(reply.msg.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { replyingTo = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(8).background(.ultraThinMaterial)
    }

    // MARK: actions

    private func load() async {
        do { messages = try await vk.history(peerId: peerId); error = nil }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func sendTyping() {
        guard Date().timeIntervalSince(lastTyping) > 4 else { return }
        lastTyping = Date()
        Task { await vk.setActivity(peerId: peerId) }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let reply = replyingTo?.msg.id
        replyingTo = nil
        do { try await vk.send(peerId: peerId, text: text, replyTo: reply); await load() }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func react(_ cm: ChatMessage, _ reactionId: Int) async {
        guard let cmid = cm.msg.conversation_message_id else { return }
        do { try await vk.sendReaction(peerId: peerId, cmid: cmid, reactionId: reactionId); await load() }
        catch let e as VKError { error = e.error_msg }
        catch {}
    }

    private func sendSticker(_ stickerId: Int) async {
        showStickers = false
        do { try await vk.sendSticker(peerId: peerId, stickerId: stickerId); await load() }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func sendPhoto(_ data: Data) async {
        uploading = true
        do {
            let att = try await vk.uploadPhoto(peerId: peerId, data: data)
            try await vk.send(peerId: peerId, text: "", attachment: att)
            await load()
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
        uploading = false
    }

    private func sendFile(_ url: URL) async {
        uploading = true
        defer { uploading = false }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let att = try await vk.uploadDoc(peerId: peerId, data: data, name: url.lastPathComponent)
            try await vk.send(peerId: peerId, text: "", attachment: att)
            await load()
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Message row (TG-style bubble)

struct MessageRow: View {
    let cm: ChatMessage
    let mine: Bool
    let isChat: Bool
    private var msg: Msg { cm.msg }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 18,
            bottomLeading: mine ? 18 : 5,
            bottomTrailing: mine ? 5 : 18,
            topTrailing: 18))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if mine {
                Spacer(minLength: 48)
            } else if isChat {
                AvatarView(url: cm.senderAvatar, name: cm.senderName, id: msg.from_id, size: 28)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                content
                if let rs = msg.reactions, !rs.isEmpty { reactionsRow(rs) }
            }
            if !mine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var content: some View {
        if let sticker = msg.stickerURL {
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                CachedImage(url: sticker, fill: false, placeholder: .clear)
                    .frame(width: 140, height: 140)
                Text(hhmm(msg.date)).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isChat && !mine {
                Text(cm.senderName).font(.caption.bold()).foregroundStyle(avatarTint(for: msg.from_id))
            }
            if let r = msg.reply_message {
                HStack(spacing: 6) {
                    Rectangle().fill(mine ? Color.white : Color.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cm.replyAuthor ?? "").font(.caption.bold())
                        Text(r.text.isEmpty ? "Вложение" : r.text).font(.caption).lineLimit(1)
                    }
                }
                .opacity(0.85)
                .frame(maxHeight: 34)
            }
            if let photo = msg.photoURL {
                CachedImage(url: photo)
                    .frame(width: 220, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let d = msg.doc { docRow(d) }
            HStack(alignment: .bottom, spacing: 6) {
                if !msg.text.isEmpty { Text(msg.text) }
                Text(hhmm(msg.date))
                    .font(.caption2)
                    .foregroundStyle(mine ? Color.white.opacity(0.75) : Color.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background {
            if mine {
                bubbleShape.fill(Color.accentColor.gradient)
            } else {
                bubbleShape.fill(.ultraThinMaterial)
            }
        }
        .foregroundStyle(mine ? .white : .primary)
    }

    private func reactionsRow(_ rs: [Msg.Reaction]) -> some View {
        HStack(spacing: 4) {
            ForEach(rs, id: \.reaction_id) { r in
                Text("\(reactionEmoji(r.reaction_id)) \(r.count)")
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder private func docRow(_ d: Attachment.Doc) -> some View {
        let row = HStack(spacing: 8) {
            Image(systemName: "doc.fill").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.title ?? "Файл").font(.subheadline).lineLimit(1)
                Text((d.ext ?? "").uppercased()).font(.caption2).opacity(0.7)
            }
        }
        if let u = d.url.flatMap({ URL(string: $0) }) {
            Link(destination: u) { row }.foregroundStyle(mine ? .white : .primary)
        } else {
            row
        }
    }
}

struct TypingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().frame(width: 7, height: 7)
                    .opacity(on ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .onAppear { on = true }
    }
}

// MARK: - Sticker picker

struct StickerSheet: View {
    let vk: VK
    let onPick: (Int) -> Void
    @State private var items: [StickerItem] = []
    @State private var status = "Загрузка…"

    var body: some View {
        ScrollView {
            if items.isEmpty {
                Text(status).foregroundStyle(.secondary).padding(.top, 60)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(items) { s in
                        Button { onPick(s.sticker_id) } label: {
                            CachedImage(url: s.url, fill: false, placeholder: .clear)
                                .frame(height: 80)
                        }
                    }
                }
                .padding()
            }
        }
        .task {
            do {
                items = try await vk.stickers()
                if items.isEmpty { status = "Нет доступных стикеров" }
            } catch let e as VKError { status = e.error_msg }
            catch { status = "Не удалось загрузить" }
        }
    }
}

// MARK: - In-chat search (word + date)

struct MessageSearchSheet: View {
    let vk: VK
    let peerId: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var useDate = false
    @State private var date = Date()
    @State private var results: [ChatMessage] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Toggle("Искать до даты", isOn: $useDate)
                    if useDate {
                        DatePicker("Дата", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.compact)
                    }
                }
                .padding(.horizontal)
                List(results) { cm in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cm.msg.text.isEmpty ? cm.msg.preview : cm.msg.text).lineLimit(2)
                        Text(cm.senderName + " · " + fullDate(cm.msg.date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if loading { ProgressView() }
                    else if results.isEmpty {
                        Text("Введи слово и нажми Найти").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Слово или фраза")
            .onSubmit(of: .search) { Task { await run() } }
            .onChange(of: useDate) { _ in Task { await run() } }
            .onChange(of: date) { _ in Task { await run() } }
            .navigationTitle("Поиск в чате")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }

    private func run() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true
        results = (try? await vk.search(peerId: peerId, query: query, before: useDate ? date : nil)) ?? []
        loading = false
    }
}
