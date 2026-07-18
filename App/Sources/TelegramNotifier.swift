import Foundation

// Forwards VK notifications to a Telegram bot (while the app is running — same limit as local pushes).
enum TelegramNotifier {
    static var token: String? { Keychain.get("tg_bot_token") }
    static var target: String { UserDefaults.standard.string(forKey: "tg_target") ?? "" }
    static var enabled: Bool { (token?.isEmpty == false) && !target.isEmpty }

    static func send(_ text: String) {
        guard let token, enabled else { return }
        var c = URLComponents(string: "https://api.telegram.org/bot\(token)/sendMessage")!
        c.queryItems = [.init(name: "chat_id", value: target),
                        .init(name: "text", value: "VK: " + text)]
        guard let url = c.url else { return }
        Task { _ = try? await URLSession.shared.data(from: url) }
    }
}
