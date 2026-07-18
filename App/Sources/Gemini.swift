import SwiftUI
import FoundationModels

// Gemini REST fallback (uses the user's own key from Keychain).
enum GeminiClient {
    static let model = "gemini-2.5-flash"

    static func ask(_ prompt: String) async throws -> String {
        guard let key = Keychain.get("gemini_key"), !key.isEmpty else {
            throw VKError(error_code: -1, error_msg: "Нет локальной модели и не задан Gemini-ключ")
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

// Priority: downloaded local model (any device) → Apple on-device → Gemini.
enum AIEngine {
    static var localReady: Bool { LocalLLM.shared.isDownloaded }
    static var onDeviceReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    static var available: Bool { localReady || onDeviceReady || !(Keychain.get("gemini_key") ?? "").isEmpty }
    static var engineName: String {
        if localReady { return "локальная (скачанная)" }
        if onDeviceReady { return "на устройстве" }
        return "Gemini"
    }

    static func complete(_ prompt: String) async throws -> String {
        if localReady { return try await LocalLLM.shared.complete(prompt) }
        if onDeviceReady {
            let session = LanguageModelSession()
            let r = try await session.respond(to: prompt)
            return r.content
        }
        return try await GeminiClient.ask(prompt)
    }
}

// Whole-chat digest: summarize each page into date-headed sections and append. Survives sheet close.
@MainActor
final class ChatSummarizer: ObservableObject {
    @Published var summary = ""
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var building = false
    @Published var complete = false

    let peerId: Int
    private var task: Task<Void, Never>?

    init(peerId: Int) {
        self.peerId = peerId
        summary = loadCache()
        complete = !summary.isEmpty   // cache is written only when a full pass finished
    }

    private var cachePath: String {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(peerId).txt").path
    }
    private func loadCache() -> String { (try? String(contentsOfFile: cachePath, encoding: .utf8)) ?? "" }
    private func saveCache() { try? summary.write(toFile: cachePath, atomically: true, encoding: .utf8) }

    func start(vk: VK) {
        guard !building else { return }
        task = Task { await build(vk: vk) }
    }

    private func build(vk: VK) async {
        building = true
        complete = false
        progress = 0
        summary = ""
        status = "Считаю сообщения…"
        defer { building = false }
        do {
            let total = max(1, try await vk.historyTotal(peerId: peerId))
            let pageSize = 60                    // small chunks fit the on-device context window
            var processed = 0
            var offset = 0
            var acc = ""
            while offset < total {
                if Task.isCancelled { return }
                status = "Читаю \(processed)/\(total)…"
                let page = try await vk.historyPage(peerId: peerId, offset: offset, count: pageSize)
                if page.isEmpty { break }
                let period = dateRange(page)
                let chunk = page.map { "\($0.senderName): \($0.msg.text.isEmpty ? $0.msg.preview : $0.msg.text)" }
                    .joined(separator: "\n")
                status = "Осмысляю \(processed)/\(total)…"
                let piece = try await AIEngine.complete("""
                Суммируй эти сообщения VK короткими тезисами по-русски (кто, что, договорённости, важное). \
                Без вступлений, только тезисы:

                \(chunk)
                """)
                acc += "\n=== \(period) ===\n\(piece)\n"
                summary = acc
                processed += page.count
                offset += pageSize
                progress = min(0.99, Double(processed) / Double(total))
            }
            progress = 1
            complete = true
            status = "Готово"
            saveCache()
        } catch let e as VKError { status = "Ошибка: \(e.error_msg)" }
        catch { status = "Ошибка: \(error.localizedDescription)" }
    }

    private func dateRange(_ page: [ChatMessage]) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM yyyy"
        let dates = page.map { Date(timeIntervalSince1970: TimeInterval($0.msg.date)) }
        guard let lo = dates.min(), let hi = dates.max() else { return "период" }
        let a = f.string(from: lo), b = f.string(from: hi)
        return a == b ? a : "\(a) — \(b)"
    }

    func answer(_ question: String) async throws -> String {
        try await AIEngine.complete("""
        Ниже конспект всей переписки VK (по периодам). Ответь на вопрос по-русски, опираясь на него.

        Конспект:
        \(summary)

        Вопрос: \(question)
        """)
    }
}

// Keeps summarizers alive across sheet open/close so the build isn't interrupted.
@MainActor
final class Summarizers {
    static let shared = Summarizers()
    private var map: [Int: ChatSummarizer] = [:]
    func get(_ peerId: Int) -> ChatSummarizer {
        if let s = map[peerId] { return s }
        let s = ChatSummarizer(peerId: peerId); map[peerId] = s; return s
    }
}

private struct QA: Identifiable { let id = UUID(); let q: String; var a: String }

struct AISheet: View {
    let vk: VK
    let peerId: Int
    @ObservedObject private var sum: ChatSummarizer
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var qas: [QA] = []
    @State private var asking = false
    @State private var showSummary = false

    init(vk: VK, peerId: Int) {
        self.vk = vk
        self.peerId = peerId
        _sum = ObservedObject(wrappedValue: Summarizers.shared.get(peerId))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !sum.complete { buildView } else { chatView }
            }
            .navigationTitle("ИИ по чату")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Свод") { showSummary = true }.disabled(!sum.complete)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
            .sheet(isPresented: $showSummary) { SummaryView(text: sum.summary) }
        }
    }

    private var buildView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            if sum.building {
                ProgressView(value: sum.progress).padding(.horizontal, 40)
                Text(sum.status).font(.callout).foregroundStyle(.secondary)
                Text("Можно свернуть — свод продолжит собираться в фоне.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !AIEngine.available {
                Text("Нужна модель: включи Apple Intelligence на устройстве\nили добавь Gemini-ключ в настройках.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Text("ИИ (\(AIEngine.engineName)) прочитает всю переписку и соберёт структурированный свод по датам.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                Button { sum.start(vk: vk) } label: {
                    Label("Прочитать весь чат", systemImage: "sparkles")
                }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Свод собран (\(AIEngine.engineName)). Спрашивай что угодно по переписке.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(qas) { qa in
                        HStack { Spacer(minLength: 40)
                            Text(qa.q).padding(10)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(.white) }
                        Text(qa.a.isEmpty ? "…" : qa.a).padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }.padding()
            }
            HStack(spacing: 8) {
                TextField("Спроси по чату…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button { Task { await ask() } } label: {
                    if asking { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
                .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10).background(.ultraThinMaterial)
        }
    }

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        question = ""
        asking = true
        var item = QA(q: q, a: "")
        qas.append(item)
        defer { asking = false }
        do { item.a = try await sum.answer(q) }
        catch let e as VKError { item.a = e.error_msg }
        catch { item.a = error.localizedDescription }
        if let i = qas.firstIndex(where: { $0.id == item.id }) { qas[i] = item }
    }
}

struct SummaryView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { Text(text.isEmpty ? "Пусто" : text).padding().textSelection(.enabled) }
                .navigationTitle("Свод чата")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}
