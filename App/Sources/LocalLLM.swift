import Foundation
import LLM

struct LocalModel: Identifiable {
    let id: String
    let name: String
    let url: String
    let sizeMB: Int
    let ramMB: Int          // approx RAM to run (Q4)
    // Fits if device RAM comfortably exceeds the model's need.
    var fits: Bool { Double(ProcessInfo.processInfo.physicalMemory) >= Double(ramMB) * 1_000_000 * 1.7 }
    var fitLabel: String { fits ? "потянет" : "тяжело для этого устройства" }
}

// Downloadable on-device LLMs (llama.cpp via LLM.swift). Any iPhone, no Apple Intelligence needed.
@MainActor
final class LocalLLM: NSObject, ObservableObject {
    static let shared = LocalLLM()

    @Published var downloadingId: String?
    @Published var progress: Double = 0
    @Published var speed = ""
    @Published var status = ""
    @Published var activeId: String? = UserDefaults.standard.string(forKey: "activeModel")

    private var llm: LLM?
    private var loadedId: String?

    static let catalog: [LocalModel] = [
        .init(id: "qwen0_5b", name: "Qwen2.5 0.5B", url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true", sizeMB: 400, ramMB: 700),
        .init(id: "llama1b", name: "Llama 3.2 1B", url: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true", sizeMB: 800, ramMB: 1300),
        .init(id: "qwen1_5b", name: "Qwen2.5 1.5B", url: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true", sizeMB: 1100, ramMB: 1800),
        .init(id: "qwen3b", name: "Qwen2.5 3B", url: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf?download=true", sizeMB: 2000, ramMB: 3200),
    ]

    nonisolated static func path(_ id: String) -> String {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(id).gguf").path
    }
    nonisolated func isDownloaded(_ id: String) -> Bool { FileManager.default.fileExists(atPath: LocalLLM.path(id)) }

    nonisolated var ready: Bool {
        guard let id = UserDefaults.standard.string(forKey: "activeModel") else { return false }
        return FileManager.default.fileExists(atPath: LocalLLM.path(id))
    }

    func setActive(_ id: String) {
        activeId = id
        UserDefaults.standard.set(id, forKey: "activeModel")
        if loadedId != id { llm = nil; loadedId = nil }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(atPath: LocalLLM.path(id))
        if activeId == id { activeId = nil; UserDefaults.standard.removeObject(forKey: "activeModel") }
        if loadedId == id { llm = nil; loadedId = nil }
    }

    func download(_ model: LocalModel) {
        guard downloadingId == nil, !isDownloaded(model.id), let url = URL(string: model.url) else { return }
        downloadingId = model.id; progress = 0; speed = ""; status = "Скачивание…"
        let session = URLSession(configuration: .default, delegate: Dl(owner: self, id: model.id), delegateQueue: nil)
        session.downloadTask(with: url).resume()
    }

    func complete(_ prompt: String) async throws -> String {
        guard let id = activeId else { throw VKError(error_code: -1, error_msg: "Модель не выбрана") }
        if llm == nil || loadedId != id {
            llm = LLM(from: URL(fileURLWithPath: LocalLLM.path(id)), template: .chatML())
            loadedId = id
        }
        guard let llm else { throw VKError(error_code: -1, error_msg: "Не удалось загрузить модель") }
        return await llm.getCompletion(from: prompt)
    }

    fileprivate func onProgress(_ p: Double, _ spd: String) { progress = p; if !spd.isEmpty { speed = spd } }
    fileprivate func onDone(_ id: String, error: String?) {
        downloadingId = nil; speed = ""
        if let error { status = "Ошибка: \(error)" }
        else { progress = 1; status = "Готово"; if activeId == nil { setActive(id) } }
    }
}

private final class Dl: NSObject, URLSessionDownloadDelegate {
    let owner: LocalLLM
    let id: String
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    init(owner: LocalLLM, id: String) { self.owner = owner; self.id = id }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData b: Int64,
                    totalBytesWritten tw: Int64, totalBytesExpectedToWrite te: Int64) {
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        var spd = ""
        if dt > 0.6 {
            spd = String(format: "%.1f МБ/с", Double(tw - lastBytes) / dt / 1_000_000)
            lastBytes = tw; lastTime = now
        }
        let p = te > 0 ? Double(tw) / Double(te) : 0
        Task { @MainActor in owner.onProgress(p, spd) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        let dest = URL(fileURLWithPath: LocalLLM.path(id))
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: loc, to: dest)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        Task { @MainActor in owner.onDone(id, error: e?.localizedDescription) }
    }
}
