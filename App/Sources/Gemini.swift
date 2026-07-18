import SwiftUI
import FoundationModels

enum AIProvider: String, CaseIterable, Identifiable {
    case local, apple, gemini, openrouter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "Локальная модель"
        case .apple: return "Apple (на устройстве)"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        }
    }
}

// Cloud clients (user's own keys, from Keychain).
enum GeminiClient {
    static let model = "gemini-2.5-flash"
    static func key() -> String? { Keychain.get("gemini_key") }

    static func request(_ prompt: String, stream: Bool) throws -> URLRequest {
        guard let key = key(), !key.isEmpty else { throw VKError(error_code: -1, error_msg: "Нет Gemini-ключа") }
        let verb = stream ? "streamGenerateContent?alt=sse&key=\(key)" : "generateContent?key=\(key)"
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(verb)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject:
            ["contents": [["parts": [["text": prompt]]]]])
        return req
    }

    static func ask(_ prompt: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(for: try request(prompt, stream: false))
        struct R: Decodable { let candidates: [C]?; let error: E?
            struct C: Decodable { let content: Ct?; struct Ct: Decodable { let parts: [P]?; struct P: Decodable { let text: String? } } }
            struct E: Decodable { let message: String? } }
        let r = try JSONDecoder().decode(R.self, from: data)
        if let m = r.error?.message { throw VKError(error_code: -1, error_msg: m) }
        guard let t = r.candidates?.first?.content?.parts?.first?.text, !t.isEmpty else {
            throw VKError(error_code: -1, error_msg: "Пустой ответ ИИ")
        }
        return t
    }
    // SSE chunk → delta text
    static func delta(_ payload: Data) -> String? {
        struct R: Decodable { let candidates: [C]?; struct C: Decodable { let content: Ct?; struct Ct: Decodable { let parts: [P]?; struct P: Decodable { let text: String? } } } }
        return (try? JSONDecoder().decode(R.self, from: payload))?.candidates?.first?.content?.parts?.first?.text
    }
}

enum OpenRouterClient {
    static func key() -> String? { Keychain.get("openrouter_key") }
    static var model: String { UserDefaults.standard.string(forKey: "openrouter_model") ?? "openai/gpt-4o-mini" }

    static func request(_ prompt: String, stream: Bool) throws -> URLRequest {
        guard let key = key(), !key.isEmpty else { throw VKError(error_code: -1, error_msg: "Нет OpenRouter-ключа") }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": stream,
            "messages": [["role": "user", "content": prompt]],
        ])
        return req
    }

    static func ask(_ prompt: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(for: try request(prompt, stream: false))
        struct R: Decodable { let choices: [C]?; let error: E?
            struct C: Decodable { let message: M?; struct M: Decodable { let content: String? } }
            struct E: Decodable { let message: String? } }
        let r = try JSONDecoder().decode(R.self, from: data)
        if let m = r.error?.message { throw VKError(error_code: -1, error_msg: m) }
        guard let t = r.choices?.first?.message?.content, !t.isEmpty else {
            throw VKError(error_code: -1, error_msg: "Пустой ответ ИИ")
        }
        return t
    }
    static func delta(_ payload: Data) -> String? {
        struct R: Decodable { let choices: [C]?; struct C: Decodable { let delta: D?; struct D: Decodable { let content: String? } } }
        return (try? JSONDecoder().decode(R.self, from: payload))?.choices?.first?.delta?.content
    }
}

// Routes to the selected provider. Priority default: local → apple → gemini → openrouter.
enum AIEngine {
    static var onDeviceReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    static func hasKey(_ p: AIProvider) -> Bool {
        switch p {
        case .gemini: return !(GeminiClient.key() ?? "").isEmpty
        case .openrouter: return !(OpenRouterClient.key() ?? "").isEmpty
        default: return false
        }
    }
    static var autoDefault: AIProvider {
        if LocalLLM.shared.ready { return .local }
        if onDeviceReady { return .apple }
        if hasKey(.gemini) { return .gemini }
        if hasKey(.openrouter) { return .openrouter }
        return .local
    }
    static var provider: AIProvider {
        if let raw = UserDefaults.standard.string(forKey: "aiProvider"), let p = AIProvider(rawValue: raw) { return p }
        return autoDefault
    }
    static var engineName: String { provider.title }
    static var available: Bool { LocalLLM.shared.ready || onDeviceReady || hasKey(.gemini) || hasKey(.openrouter) }

    static func complete(_ prompt: String) async throws -> String {
        switch provider {
        case .local: return try await LocalLLM.shared.complete(prompt)
        case .apple:
            let r = try await LanguageModelSession().respond(to: prompt); return r.content
        case .gemini: return try await GeminiClient.ask(prompt)
        case .openrouter: return try await OpenRouterClient.ask(prompt)
        }
    }

    // Streams server providers token-by-token; local/apple return the full text at once.
    static func stream(_ prompt: String, onToken: @escaping (String) -> Void) async throws -> String {
        switch provider {
        case .local, .apple:
            let full = try await complete(prompt); onToken(full); return full
        case .gemini:
            return try await sse(GeminiClient.request(prompt, stream: true), delta: GeminiClient.delta, onToken: onToken)
        case .openrouter:
            return try await sse(OpenRouterClient.request(prompt, stream: true), delta: OpenRouterClient.delta, onToken: onToken)
        }
    }

    private static func sse(_ req: URLRequest, delta: (Data) -> String?, onToken: (String) -> Void) async throws -> String {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VKError(error_code: http.statusCode, error_msg: "HTTP \(http.statusCode)")
        }
        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let d = payload.data(using: .utf8), let t = delta(d), !t.isEmpty { full += t; onToken(t) }
        }
        if full.isEmpty { throw VKError(error_code: -1, error_msg: "Пустой ответ ИИ") }
        return full
    }
}

// Whole-chat digest via map-reduce; survives sheet close. Uses whichever provider is selected.
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
        complete = !summary.isEmpty
    }

    private var cachePath: String {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(peerId).txt").path
    }
    private func loadCache() -> String { (try? String(contentsOfFile: cachePath, encoding: .utf8)) ?? "" }
    private func saveCache() { try? summary.write(toFile: cachePath, atomically: true, encoding: .utf8) }

    func start(vk: VK) { guard !building else { return }; task = Task { await build(vk: vk) } }

    func reset() {
        task?.cancel(); building = false; complete = false
        summary = ""; progress = 0; status = ""
        try? FileManager.default.removeItem(atPath: cachePath)
    }

    private func build(vk: VK) async {
        building = true; complete = false; progress = 0; summary = ""; status = "Считаю сообщения…"
        defer { building = false }
        do {
            let total = max(1, try await vk.historyTotal(peerId: peerId))
            let pageSize = 60
            var processed = 0, offset = 0, acc = ""
            while offset < total {
                if Task.isCancelled { return }
                let page = try await vk.historyPage(peerId: peerId, offset: offset, count: pageSize)
                if page.isEmpty { break }
                let chunk = page.map { "\($0.senderName): \($0.msg.text.isEmpty ? $0.msg.preview : $0.msg.text)" }
                    .joined(separator: "\n")
                status = "Осмысляю \(processed)/\(total)…"
                let piece = try await AIEngine.complete("Суммируй эти сообщения VK короткими тезисами по-русски (кто, что, договорённости, важное), без вступлений:\n\n\(chunk)")
                acc += "\n=== \(dateRange(page)) ===\n\(piece)\n"
                summary = acc
                processed += page.count; offset += pageSize
                progress = min(0.99, Double(processed) / Double(total))
            }
            progress = 1; complete = true; status = "Готово"; saveCache()
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

    func answerPrompt(_ question: String) -> String {
        "Ниже конспект всей переписки VK (по периодам). Ответь на вопрос по-русски, опираясь на него.\n\nКонспект:\n\(summary)\n\nВопрос: \(question)"
    }
}

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
        self.vk = vk; self.peerId = peerId
        _sum = ObservedObject(wrappedValue: Summarizers.shared.get(peerId))
    }

    var body: some View {
        NavigationStack {
            Group { if !sum.complete { buildView } else { chatView } }
                .navigationTitle("ИИ по чату")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if sum.complete {
                            Menu {
                                Button { showSummary = true } label: { Label("Открыть свод", systemImage: "doc.text") }
                                Button { sum.reset() } label: { Label("Пересоздать свод", systemImage: "arrow.clockwise") }
                            } label: { Text("Свод") }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
                }
                .sheet(isPresented: $showSummary) { SummaryView(text: sum.summary) }
        }
    }

    @AppStorage("aiProvider") private var providerRaw = ""

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
                Text("Выбери модель в Настройки → Нейросеть\n(локальная, Apple или ключ Gemini/OpenRouter).")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Text("Собрать свод всей переписки — по датам. Через что:")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                Picker("Провайдер", selection: $providerRaw) {
                    Text("Авто (\(AIEngine.autoDefault.title))").tag("")
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.menu)
                Button { sum.start(vk: vk) } label: { Label("Прочитать весь чат", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }.padding()
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
                            .textSelection(.enabled)
                    }
                }.padding()
            }
            HStack(spacing: 8) {
                TextField("Спроси по чату…", text: $question, axis: .vertical).textFieldStyle(.roundedBorder)
                Button { Task { await ask() } } label: {
                    if asking { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }.disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(10).background(.ultraThinMaterial)
        }
    }

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        question = ""; asking = true
        let id = UUID()
        qas.append(QA(q: q, a: ""))
        let idx = qas.count - 1
        defer { asking = false }
        do {
            _ = try await AIEngine.stream(sum.answerPrompt(q)) { delta in
                Task { @MainActor in if qas.indices.contains(idx) { qas[idx].a += delta } }
            }
        } catch let e as VKError { if qas.indices.contains(idx) { qas[idx].a = e.error_msg } }
        catch { if qas.indices.contains(idx) { qas[idx].a = error.localizedDescription } }
        _ = id
    }
}

struct SummaryView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { Text(text.isEmpty ? "Пусто" : text).padding().textSelection(.enabled) }
                .navigationTitle("Свод чата").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}
