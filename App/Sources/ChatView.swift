import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private func hhmm(_ ts: Int) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

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
    @State private var showProfile = false
    @State private var showSearch = false
    @State private var showAttach = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var uploading = false
    @State private var lastTyping = Date.distantPast

    private var isChat: Bool { peerId >= 2_000_000_000 }
    private var isUser: Bool { peerId > 0 && peerId < 2_000_000_000 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { cm in
                            MessageRow(cm: cm, mine: cm.msg.from_id == ownId, isChat: isChat)
                                .id(cm.id)
                                .contextMenu {
                                    Button { replyingTo = cm } label: {
                                        Label("Ответить", systemImage: "arrowshape.turn.up.left")
                                    }
                                    if !cm.msg.text.isEmpty {
                                        Button { UIPasteboard.general.string = cm.msg.text } label: {
                                            Label("Копировать", systemImage: "doc.on.doc")
                                        }
                                    }
                                }
                        }
                        if live.isTyping(peerId) {
                            HStack { TypingDots(); Spacer() }.padding(.horizontal, 10)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if let reply = replyingTo { replyBanner(reply) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            inputBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { if isUser { showProfile = true } } label: {
                    VStack(spacing: 1) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        if live.isTyping(peerId) {
                            Text("печатает…").font(.caption2).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .disabled(!isUser)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .onAppear { live.setActive(peer: peerId) }
        .onDisappear { live.setActive(peer: nil) }
        .task { await load() }
        .onChange(of: live.bump) { _ in Task { await load() } }
        .sheet(isPresented: $showProfile) {
            NavigationStack { ProfileView(vk: vk, userId: peerId, ownId: ownId) }
        }
        .sheet(isPresented: $showSearch) { MessageSearchSheet(vk: vk, peerId: peerId) }
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

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button { showAttach = true } label: { Image(systemName: "paperclip").font(.title3) }
                .confirmationDialog("Вложение", isPresented: $showAttach, titleVisibility: .visible) {
                    Button("Фото") { showPhotoPicker = true }
                    Button("Файл") { showFileImporter = true }
                    Button("Отмена", role: .cancel) {}
                }
            TextField("Сообщение", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft) { _ in sendTyping() }
            if uploading {
                ProgressView().frame(width: 32)
            } else {
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
    }

    private func replyBanner(_ reply: ChatMessage) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.senderName).font(.caption.bold()).foregroundStyle(Color.accentColor)
                Text(reply.msg.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { replyingTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(8).background(.thinMaterial)
    }

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

struct MessageRow: View {
    let cm: ChatMessage
    let mine: Bool
    let isChat: Bool
    private var msg: Msg { cm.msg }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if mine {
                Spacer(minLength: 40)
            } else if isChat {
                AvatarView(url: cm.senderAvatar, name: cm.senderName, id: msg.from_id, size: 30)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if isChat && !mine {
                    Text(cm.senderName).font(.caption).foregroundStyle(tint(for: msg.from_id))
                }
                content
            }
            if !mine { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var content: some View {
        if let sticker = msg.stickerURL {
            AsyncImage(url: sticker) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(width: 128, height: 128)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = msg.reply_message {
                HStack(spacing: 6) {
                    Rectangle().fill(mine ? Color.white : Color.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cm.replyAuthor ?? "").font(.caption.bold())
                        Text(r.text.isEmpty ? "Вложение" : r.text).font(.caption).lineLimit(1)
                    }
                }
                .opacity(0.9)
            }
            if let photo = msg.photoURL {
                AsyncImage(url: photo) { $0.resizable().scaledToFit() } placeholder: {
                    Color.gray.opacity(0.2).frame(height: 160)
                }
                .frame(maxWidth: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let d = msg.doc {
                docRow(d)
            }
            if !msg.text.isEmpty {
                Text(msg.text)
            }
            Text(hhmm(msg.date))
                .font(.caption2)
                .foregroundStyle(mine ? Color.white.opacity(0.7) : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 60, alignment: .leading)
        .background(mine ? Color.accentColor : Color.gray.opacity(0.18))
        .foregroundStyle(mine ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func docRow(_ d: Attachment.Doc) -> some View {
        let row = HStack(spacing: 8) {
            Image(systemName: "doc.fill").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.title ?? "Файл").font(.subheadline).lineLimit(1)
                Text((d.ext ?? "").uppercased()).font(.caption2).opacity(0.7)
            }
        }
        if let u = d.url.flatMap(URL.init(string:)) {
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
        .background(Color.gray.opacity(0.18), in: Capsule())
        .onAppear { on = true }
    }
}

struct MessageSearchSheet: View {
    let vk: VK
    let peerId: Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ChatMessage] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List(results) { cm in
                VStack(alignment: .leading, spacing: 3) {
                    Text(cm.msg.text.isEmpty ? cm.msg.preview : cm.msg.text).lineLimit(2)
                    Text(cm.senderName + " · " + fullDate(cm.msg.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .overlay { if loading { ProgressView() } else if results.isEmpty { Text("Введите слово для поиска").foregroundStyle(.secondary) } }
            .searchable(text: $query, prompt: "Слово или фраза")
            .onSubmit(of: .search) { Task { await run() } }
            .navigationTitle("Поиск в чате")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }

    private func run() async {
        loading = true
        results = (try? await vk.search(peerId: peerId, query: query)) ?? []
        loading = false
    }
}
