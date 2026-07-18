import Foundation
import LLM

// Downloadable on-device LLM (llama.cpp via LLM.swift). Works on any iPhone — no Apple Intelligence needed.
// ponytail: tiny Qwen2.5-0.5B Q4 (~400MB) so it fits/runs on regular devices. Slow but private & unlimited.
@MainActor
final class LocalLLM: NSObject, ObservableObject {
    static let shared = LocalLLM()

    @Published var downloading = false
    @Published var progress: Double = 0
    @Published var status = ""

    private var llm: LLM?

    private static let remote = URL(string:
        "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true")!

    nonisolated static var modelPath: String {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("model.gguf").path
    }
    nonisolated var isDownloaded: Bool { FileManager.default.fileExists(atPath: LocalLLM.modelPath) }

    func delete() {
        try? FileManager.default.removeItem(atPath: LocalLLM.modelPath)
        llm = nil
    }

    func startDownload() {
        guard !downloading, !isDownloaded else { return }
        downloading = true; progress = 0; status = "Скачивание модели (~400 МБ)…"
        let session = URLSession(configuration: .default, delegate: Downloader(owner: self), delegateQueue: nil)
        session.downloadTask(with: LocalLLM.remote).resume()
    }

    func complete(_ prompt: String) async throws -> String {
        if llm == nil {
            llm = LLM(from: URL(fileURLWithPath: LocalLLM.modelPath), template: .chatML())
        }
        guard let llm else { throw VKError(error_code: -1, error_msg: "Не удалось загрузить модель") }
        return await llm.getCompletion(from: prompt)
    }

    fileprivate func report(progress p: Double) { progress = p; status = "Скачивание… \(Int(p * 100))%" }
    fileprivate func finished(error: String?) {
        downloading = false
        if let error { status = "Ошибка: \(error)" } else { progress = 1; status = "Модель готова" }
    }
}

// Separate delegate object so the URLSession retain cycle doesn't pin the @MainActor model.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    let owner: LocalLLM
    init(owner: LocalLLM) { self.owner = owner }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in owner.report(progress: p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = URL(fileURLWithPath: LocalLLM.modelPath)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in owner.finished(error: error?.localizedDescription) }
    }
}
