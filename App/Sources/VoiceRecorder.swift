import Foundation
import AVFoundation

// ponytail: AVAudioRecorder → m4a. VK may show it as a file (native voice wants ogg/opus).
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published var recording = false
    private var recorder: AVAudioRecorder?
    private var url: URL?

    func start() {
        AVAudioApplication.requestRecordPermission { _ in }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        recorder = try? AVAudioRecorder(url: u, settings: settings)
        if recorder?.record() == true { url = u; recording = true }
    }

    func stop() -> URL? {
        recorder?.stop()
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        let u = url
        url = nil
        return u
    }
}
