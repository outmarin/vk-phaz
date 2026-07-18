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

struct PendingAttachment: Identifiable {
    let id = UUID()
    let attachment: String   // "photo123_456"
    let thumb: UIImage?
    let label: String
}

struct ChatView: View {
    let vk: VK
    let peerId: Int
    let title: String
    let ownId: Int
    @EnvironmentObject var live: LiveUpdates
    @StateObject private var recorder = VoiceRecorder()

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var replyingTo: ChatMessage?
    @State private var selected: ChatMessage?
    @State private var pending: [PendingAttachment] = []
    @State private var error: String?
    @State private var peerProfile: Profile?
    @State private var showProfile = false
    @State private var showAI = false
    @State private var showAttach = false
    @State private var searchMode = false
    @State private var searchText = ""
    @State private var matchIds: [Int] = []
    @State private var matchIdx = 0
    @State private var highlightId: Int?
    @State private var searching = false
    @State private var viewerURL: IdURL?
    @State private var showStickers = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var uploading = false
    @State private var lastTyping = Date.distantPast
    @State private var outRead = 0
    @State private var wpRefresh = 0
    @State private var showWallpaperPicker = false
    @State private var wallpaperItem: PhotosPickerItem?

    private var isChat: Bool { peerId >= 2_000_000_000 }
    private var isUser: Bool { peerId > 0 && peerId < 2_000_000_000 }

    private var subtitle: String {
        if live.isTyping(peerId) { return "печатает…" }
        if peerId == ownId { return "заметки для себя" }
        guard let p = peerProfile else { return "" }
        return lastSeenText(online: p.online == 1, ts: p.last_seen?.time)
    }

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
            WallpaperBackground(peerId: peerId, refresh: wpRefresh)
            messageList
                .safeAreaInset(edge: .top) { if searchMode { searchBar } }
                .safeAreaInset(edge: .bottom) { if searchMode { searchNavBar } else { bottomBar } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button { withAnimation { searchMode = true } } label: {
                        Label("Поиск в чате", systemImage: "magnifyingglass")
                    }
                    Button { showWallpaperPicker = true } label: { Label("Обои чата", systemImage: "photo") }
                    if Wallpaper.hasImage(peer: peerId) {
                        Button(role: .destructive) {
                            Wallpaper.removeImage(peer: peerId); wpRefresh += 1
                        } label: { Label("Сбросить обои", systemImage: "trash") }
                    }
                    if isUser && peerId != ownId {
                        Button { showProfile = true } label: { Label("Профиль", systemImage: "person.crop.circle") }
                    }
                } label: {
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
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { if isUser && peerId != ownId { showProfile = true } } label: {
                    AvatarView(url: peerProfile?.avatar, name: title, id: peerId, size: 32)
                }
            }
        }
        .onAppear { live.setActive(peer: peerId) }
        .onDisappear { live.setActive(peer: nil) }
        .task {
            await load()
            if isUser && peerId != ownId { peerProfile = try? await vk.user(id: peerId) }
        }
        .onChange(of: live.bump) { _ in Task { await load() } }
        .fullScreenCover(item: $selected) { cm in
            MessageActionsOverlay(
                cm: cm, mine: cm.msg.from_id == ownId, isChat: isChat,
                statusText: cm.msg.from_id == ownId ? (cm.msg.id <= outRead ? "Прочитано" : "Отправлено") : nil,
                hasReactions: !(cm.msg.reactions ?? []).isEmpty,
                onReact: { rid in Task { await react(cm, rid) } },
                onRemoveReaction: { Task { await removeReaction(cm) } },
                onReply: { replyingTo = cm },
                onCopy: { UIPasteboard.general.string = cm.msg.text },
                onPin: { Task { await pin(cm) } },
                onDeleteForMe: { Task { await delete(cm, forAll: false) } },
                onDeleteForAll: { Task { await delete(cm, forAll: true) } },
                onDismiss: { selected = nil })
            .presentationBackground(.clear)
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack { ProfileView(vk: vk, userId: peerId, ownId: ownId) }
        }
        .sheet(isPresented: $showAI) { AISheet(vk: vk, peerId: peerId) }
        .fullScreenCover(item: $viewerURL) { PhotoViewer(url: $0.url) }
        .sheet(isPresented: $showAttach) {
            AttachSheet(
                onImageData: { data in showAttach = false; Task { await addPhoto(data) } },
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
                if let data = try? await item.loadTransferable(type: Data.self) { await addPhoto(data) }
                photoItem = nil
            }
        }
        .photosPicker(isPresented: $showWallpaperPicker, selection: $wallpaperItem, matching: .images)
        .onChange(of: wallpaperItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    Wallpaper.setImage(peer: peerId, data: data); wpRefresh += 1
                }
                wallpaperItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await addFile(url) } }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(timeline, id: \.cm.id) { pair in
                        if let day = pair.day { dayChip(day) }
                        MessageRow(cm: pair.cm, mine: pair.cm.msg.from_id == ownId,
                                   isChat: isChat, readUpTo: outRead,
                                   highlighted: highlightId == pair.cm.id,
                                   onOpenImage: { viewerURL = IdURL(url: $0) })
                            .id(pair.cm.id)
                            .onLongPressGesture { selected = pair.cm }
                    }
                    if live.isTyping(peerId) {
                        HStack { TypingDots(); Spacer() }.padding(.horizontal, 12).id("typing")
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in
                if highlightId == nil, let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: highlightId) { id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск в чате", text: $searchText)
                .autocorrectionDisabled()
                .onSubmit { Task { await runSearch() } }
            if searching { ProgressView() }
            Button { showAI = true } label: { Image(systemName: "sparkles") }
            Button("Отмена") { closeSearch() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var searchNavBar: some View {
        HStack {
            Text(matchIds.isEmpty ? "Нет совпадений" : "\(matchIdx + 1)/\(matchIds.count)")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(matchIdx <= 0)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(matchIdx >= matchIds.count - 1)
        }
        .font(.title3)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        matchIds = (try? await vk.searchIds(peerId: peerId, query: q)) ?? []
        searching = false
        if !matchIds.isEmpty { matchIdx = matchIds.count - 1; await goto() }  // start at newest match
    }

    private func step(_ d: Int) {
        let n = matchIdx + d
        guard n >= 0 && n < matchIds.count else { return }
        matchIdx = n
        Task { await goto() }
    }

    private func goto() async {
        guard matchIds.indices.contains(matchIdx) else { return }
        let id = matchIds[matchIdx]
        if !messages.contains(where: { $0.msg.id == id }) {
            if let window = try? await vk.historyAround(peerId: peerId, messageId: id) { messages = window }
        }
        highlightId = id
    }

    private func closeSearch() {
        withAnimation { searchMode = false }
        searchText = ""; matchIds = []; highlightId = nil
        Task { await load() }
    }

    private func dayChip(_ day: String) -> some View {
        Text(day)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.vertical, 6)
    }

    // Bottom: floating glass controls over a soft progressive blur that fades up into the messages.
    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let reply = replyingTo { replyBanner(reply) }
            if !pending.isEmpty { attachmentTray }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            inputBar
        }
        .padding(.top, 10)
        .background(alignment: .bottom) {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(colors: [.clear, .black.opacity(0.6), .black],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pending) { a in
                    ZStack(alignment: .topTrailing) {
                        if let t = a.thumb {
                            Image(uiImage: t).resizable().scaledToFill()
                                .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(.gray.opacity(0.25))
                                .frame(width: 60, height: 60)
                                .overlay(Image(systemName: "doc.fill").foregroundStyle(.secondary))
                        }
                        Button { pending.removeAll { $0.id == a.id } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .padding(2)
                    }
                }
            }
            .padding(.horizontal, 12)
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
            } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty {
                Image(systemName: recorder.recording ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(recorder.recording ? .red : .secondary)
                    .frame(width: 42, height: 42)
                    .glassEffect(in: Circle())
                    .onLongPressGesture(minimumDuration: 0.2, pressing: { pressing in
                        if pressing { recorder.start() } else { Task { await finishVoice() } }
                    }, perform: {})
            } else {
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor, in: Circle())
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
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
        .padding(.horizontal, 12)
    }

    // MARK: actions

    private func load() async {
        do {
            messages = try await vk.history(peerId: peerId)
            outRead = (try? await vk.outRead(peerId: peerId)) ?? outRead
            error = nil
        }
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
        guard !text.isEmpty || !pending.isEmpty else { return }
        draft = ""
        let reply = replyingTo?.msg.id
        replyingTo = nil
        let atts = pending.map { $0.attachment }.joined(separator: ",")
        pending = []
        do {
            try await vk.send(peerId: peerId, text: text, replyTo: reply,
                              attachment: atts.isEmpty ? nil : atts)
            await load()
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func addPhoto(_ data: Data) async {
        uploading = true
        // VK upload rejects HEIC → re-encode to JPEG. Fixes "photo is undefined".
        let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) ?? data
        do {
            let att = try await vk.uploadPhoto(peerId: peerId, data: jpeg)
            pending.append(.init(attachment: att, thumb: UIImage(data: jpeg), label: "Фото"))
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
        uploading = false
    }

    private func addFile(_ url: URL) async {
        uploading = true
        defer { uploading = false }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let att = try await vk.uploadDoc(peerId: peerId, data: data, name: url.lastPathComponent)
            pending.append(.init(attachment: att, thumb: nil, label: url.lastPathComponent))
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func finishVoice() async {
        guard let url = recorder.stop() else { return }
        uploading = true
        defer { uploading = false }
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 1000 else { return }   // ignore accidental taps
            let att = try await vk.uploadVoice(peerId: peerId, data: data)
            pending.append(.init(attachment: att, thumb: nil, label: "Голос"))
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func react(_ cm: ChatMessage, _ reactionId: Int) async {
        guard let cmid = cm.msg.conversation_message_id else { return }
        do { try await vk.sendReaction(peerId: peerId, cmid: cmid, reactionId: reactionId); await load() }
        catch let e as VKError { error = e.error_msg }
        catch {}
    }

    private func pin(_ cm: ChatMessage) async {
        guard let cmid = cm.msg.conversation_message_id else { return }
        try? await vk.pinMessage(peerId: peerId, cmid: cmid)
    }

    private func delete(_ cm: ChatMessage, forAll: Bool) async {
        guard let cmid = cm.msg.conversation_message_id else { error = "Нельзя удалить это сообщение"; return }
        do { try await vk.deleteMessages(peerId: peerId, cmids: [cmid], forAll: forAll); await load() }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func removeReaction(_ cm: ChatMessage) async {
        guard let cmid = cm.msg.conversation_message_id else { return }
        do { try await vk.deleteReaction(peerId: peerId, cmid: cmid); await load() }
        catch let e as VKError { error = e.error_msg }
        catch {}
    }

    private func sendSticker(_ stickerId: Int) async {
        showStickers = false
        do { try await vk.sendSticker(peerId: peerId, stickerId: stickerId); await load() }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Message row (TG-style bubble)

struct MessageRow: View {
    let cm: ChatMessage
    let mine: Bool
    let isChat: Bool
    var readUpTo: Int = 0
    var highlighted: Bool = false
    var onOpenImage: (URL) -> Void = { _ in }
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
        .background(highlighted ? Color.yellow.opacity(0.25) : .clear)
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
                        Text(r.text.isEmpty ? "Вложение" : r.text).font(.caption).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if let photo = msg.photoURL {
                CachedImage(url: photo)
                    .frame(width: 230, height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { onOpenImage(photo) }
            }
            if let v = msg.voice { voiceRow(v) }
            if let d = msg.doc { docRow(d) }
            HStack(alignment: .bottom, spacing: 6) {
                if !msg.text.isEmpty { Text(msg.text) }
                Text(hhmm(msg.date))
                    .font(.caption2)
                    .foregroundStyle(mine ? Color.white.opacity(0.75) : Color.secondary)
                if mine { ReadTicks(read: msg.id <= readUpTo) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background {
            if mine { bubbleShape.fill(Color.accentColor.gradient) }
            else { bubbleShape.fill(.ultraThinMaterial) }
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

    @ViewBuilder private func voiceRow(_ v: Attachment.AudioMessage) -> some View {
        let dur = v.duration ?? 0
        let row = HStack(spacing: 8) {
            Image(systemName: "play.circle.fill").font(.title2)
            Text("Голосовое \(dur > 0 ? "· \(dur)с" : "")").font(.subheadline)
        }
        if let u = (v.link_mp3 ?? v.link_ogg).flatMap({ URL(string: $0) }) {
            Link(destination: u) { row }.foregroundStyle(mine ? .white : .primary)
        } else { row }
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
        } else { row }
    }
}

struct ReadTicks: View {
    let read: Bool
    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            if read {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).offset(x: 4)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: read ? 15 : 11, alignment: .leading)
    }
}

struct IdURL: Identifiable { let id = UUID(); let url: URL }

struct PhotoViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CachedImage(url: url, fill: false, placeholder: .clear)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(MagnificationGesture()
                    .onChanged { scale = max(1, $0) }
                    .onEnded { _ in if scale < 1 { withAnimation { scale = 1 } } })
                .simultaneousGesture(DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { _ in if scale <= 1 { withAnimation { offset = .zero } } })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white)
                    }
                }
                Spacer()
            }
            .padding()
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

// MARK: - Sticker picker with packs

struct StickerSheet: View {
    let vk: VK
    let onPick: (Int) -> Void
    @State private var packs: [StickerPack] = []
    @State private var sel = 0
    @State private var status = "Загрузка…"

    private let cols = Array(repeating: GridItem(.flexible()), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            if packs.isEmpty {
                Spacer(); Text(status).foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(packs.enumerated()), id: \.element.id) { i, pack in
                            Button { sel = i } label: {
                                CachedImage(url: pack.stickers.first?.url, fill: false, placeholder: .clear)
                                    .frame(width: 40, height: 40)
                                    .opacity(sel == i ? 1 : 0.45)
                            }
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }
                Divider()
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(packs[min(sel, packs.count - 1)].stickers) { s in
                            Button { onPick(s.sticker_id) } label: {
                                CachedImage(url: s.url, fill: false, placeholder: .clear).frame(height: 78)
                            }
                        }
                    }.padding()
                }
            }
        }
        .task {
            do {
                packs = try await vk.stickerPacks()
                if packs.isEmpty { status = "Нет доступных стикеров" }
            } catch let e as VKError { status = e.error_msg }
            catch { status = "Не удалось загрузить" }
        }
    }
}

