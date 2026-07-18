import SwiftUI

struct ChatView: View {
    let vk: VK
    let peerId: Int
    let title: String
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages, id: \.uiId) { m in
                            // ponytail: "mine = not the peer" is correct for 1:1; store own id if group chats matter.
                            Bubble(text: m.text, mine: m.from_id > 0 && m.from_id != peerId)
                                .id(m.uiId)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.uiId, anchor: .bottom) } }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 8) {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do { messages = try await vk.history(peerId: peerId); error = nil }
        catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        do {
            try await vk.send(peerId: peerId, text: text)
            await load()
        } catch let e as VKError { error = e.error_msg }
        catch { self.error = error.localizedDescription }
    }
}

// ponytail: plain Text only — no HTML rendering, so a malicious message can't inject anything.
struct Bubble: View {
    let text: String
    let mine: Bool
    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Color.blue : Color.gray.opacity(0.2))
                .foregroundStyle(mine ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if !mine { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 10)
    }
}
