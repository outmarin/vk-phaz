import Foundation
import UserNotifications

// Foreground live updates via VK Long Poll. Works while the app is running (like the VK website tab).
// ponytail: heterogeneous LP arrays parsed with JSONSerialization, not Codable gymnastics.
@MainActor
final class LiveUpdates: ObservableObject {
    @Published var typing: [Int: Date] = [:]   // peerId -> typing-until
    @Published var bump = 0                     // increments on any new message → lists reload

    private var task: Task<Void, Never>?
    private var currentPeer: Int?               // muted for notifications while chat is open

    func setActive(peer: Int?) { currentPeer = peer }

    func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func isTyping(_ peer: Int) -> Bool {
        if let t = typing[peer], t > Date() { return true }
        return false
    }

    func start(vk: VK) {
        stop()
        task = Task { await loop(vk) }
    }

    func stop() { task?.cancel(); task = nil }

    private func loop(_ vk: VK) async {
        while !Task.isCancelled {
            do {
                let s = try await vk.longPollServer()
                var ts = s.ts
                while !Task.isCancelled {
                    let host = s.server.hasPrefix("http") ? s.server : "https://" + s.server
                    var c = URLComponents(string: host)!
                    c.queryItems = [.init(name: "act", value: "a_check"), .init(name: "key", value: s.key),
                                    .init(name: "ts", value: String(ts)), .init(name: "wait", value: "25"),
                                    .init(name: "mode", value: "2"), .init(name: "version", value: "3")]
                    let (data, _) = try await URLSession.shared.data(from: c.url!)
                    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    if obj["failed"] != nil { break }          // re-request server
                    if let newTs = obj["ts"] as? Int { ts = newTs }
                    for u in (obj["updates"] as? [[Any]]) ?? [] { handle(u) }
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // backoff, then reconnect
            }
        }
    }

    private func handle(_ u: [Any]) {
        guard let code = u.first as? Int else { return }
        switch code {
        case 4:  // new message: [4, id, flags, peer_id, ts, text, ...]
            let flags = (u.count > 2 ? u[2] as? Int : 0) ?? 0
            let peer = (u.count > 3 ? u[3] as? Int : nil) ?? 0
            let text = (u.count > 5 ? u[5] as? String : "") ?? ""
            bump += 1
            let outgoing = flags & 2 != 0
            if !outgoing && peer != currentPeer { notify(text.isEmpty ? "Вложение" : text) }
        case 2, 5, 13:  // message deleted / edited / flags changed → reload so it reflects
            bump += 1
        case 61:  // typing in a dialog: [61, user_id, ...]
            if let peer = u[safe: 1] as? Int { typing[peer] = Date().addingTimeInterval(6) }
        case 63, 64:  // typing in a chat: [.., ..., peer_id]
            if let peer = u[safe: 2] as? Int { typing[peer] = Date().addingTimeInterval(6) }
        default:
            break
        }
    }

    private func notify(_ body: String) {
        TelegramNotifier.send(body)  // forwards to TG bot if configured
        guard UserDefaults.standard.object(forKey: "notifsEnabled") as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = "Новое сообщение"
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
