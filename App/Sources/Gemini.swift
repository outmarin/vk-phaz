import SwiftUI

// Gemini REST client (uses the user's own key from Keychain). Text of the chat is sent to Google.
enum GeminiClient {
    static let model = "gemini-2.5-flash"

    static func ask(_ prompt: String) async throws -> String {
        guard let key = Keychain.get("gemini_key"), !key.isEmpty else {
            throw VKError(error_code: -1, error_msg: "Добавь Gemini API-ключ в настройках")
        }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct GResp: Decodable {
            let candidates: [Cand]?
            let error: Err?
            struct Cand: Decodable { let content: Content?; struct Content: Decodable {
                let parts: [Part]?; struct Part: Decodable { let text: String? } } }
            struct Err: Decodable { let message: String? }
        }
        let r = try JSONDecoder().decode(GResp.self, from: data)
        if let msg = r.error?.message { throw VKError(error_code: -1, error_msg: msg) }
        let text = r.candidates?.first?.content?.parts?.first?.text
        guard let text, !text.isEmpty else { throw VKError(error_code: -1, error_msg: "Пустой ответ ИИ") }
        return text
    }
}

// Progressive map-reduce summary of an entire chat, cached on disk. Shows progress while building.
@MainActor
final class ChatSummarizer: ObservableObject {
    @Published var summary = ""
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var building = false

    let peerId: Int
    init(peerId: Int) { self.peerId = peerId; summary = loadCache() }

    private var cachePath: String {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(peerId).txt").path
    }
    private func loadCache() -> String { (try? String(contentsOfFile: cachePath, encoding: .utf8)) ?? "" }
    private func saveCache() { try? summary.write(toFile: cachePath, atomically: true, encoding: .utf8) }

    var hasSummary: Bool { !summary.isEmpty }

    func build(vk: VK) async {
        building = true
        progress = 0
        summary = ""
        status = "Считаю сообщения…"
        defer { building = false }
        do {
            let total = max(1, try await vk.historyTotal(peerId: peerId))
            let pageSize = 200
            var processed = 0
            var offset = 0
            while offset < total {
                status = "Читаю \(processed)/\(total)…"
                let page = try await vk.historyPage(peerId: peerId, offset: offset, count: pageSize)
                if page.isEmpty { break }
                let chunk = page.map { "\($0.senderName): \($0.msg.text.isEmpty ? $0.msg.preview : $0.msg.text)" }
                    .joined(separator: "\n")
                status = "Осмысляю \(processed)/\(total)…"
                summary = try await fold(existing: summary, chunk: chunk)
                saveCache()
                processed += page.count
                offset += pageSize
                progress = min(0.99, Double(processed) / Double(total))
            }
            progress = 1
            status = "Готово"
        } catch let e as VKError { status = "Ошибка: \(e.error_msg)" }
        catch { status = "Ошибка: \(error.localizedDescription)" }
    }

    private func fold(existing: String, chunk: String) async throws -> String {
        let prompt = """
        Ты ведёшь компактный свод переписки VK. Обнови свод, добавив факты из новой порции сообщений:
        имена, договорённости, темы, важные детали, даты. Пиши по-русски, кратко, без воды, тезисами.

        Текущий свод:
        \(existing.isEmpty ? "(пусто)" : existing)

        Новые сообщения:
        \(chunk)

        Верни только обновлённый свод.
        """
        return try await GeminiClient.ask(prompt)
    }

    func answer(_ question: String) async throws -> String {
        let prompt = """
        Ниже свод всей переписки VK. Ответь на вопрос пользователя, опираясь на него. По-русски.

        Свод:
        \(summary)

        Вопрос: \(question)
        """
        return try await GeminiClient.ask(prompt)
    }
}

struct AISheet: View {
    let vk: VK
    let peerId: Int
    @StateObject private var sum: ChatSummarizer
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false

    init(vk: VK, peerId: Int) {
        self.vk = vk
        self.peerId = peerId
        _sum = StateObject(wrappedValue: ChatSummarizer(peerId: peerId))
    }

    private var hasKey: Bool { !(Keychain.get("gemini_key") ?? "").isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !hasKey {
                        Label("Добавь Gemini API-ключ в Настройках → Нейросеть", systemImage: "key")
                            .foregroundStyle(.secondary)
                    }
                    if sum.building {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: sum.progress)
                            Text(sum.status).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            Task { await sum.build(vk: vk) }
                        } label: {
                            Label(sum.hasSummary ? "Пересобрать свод чата" : "Прочитать весь чат",
                                  systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasKey)
                    }

                    if sum.hasSummary {
                        Text("Свод собран — можно спрашивать про что угодно из чата.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("Спроси по чату…", text: $question, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                Task { await ask() }
                            } label: {
                                if asking { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            }
                            .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if !answer.isEmpty {
                            Text(answer)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("ИИ по чату")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }

    private func ask() async {
        asking = true
        defer { asking = false }
        do { answer = try await sum.answer(question) }
        catch let e as VKError { answer = e.error_msg }
        catch { answer = error.localizedDescription }
    }
}
