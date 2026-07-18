import Foundation

// Talks to the companion notifier server: the app hands it the token + TG config (with consent),
// the server holds the VK long-poll while the app is closed. Tokens are encrypted at rest server-side.
enum NotifierServer {
    static var base: String {
        (UserDefaults.standard.string(forKey: "notifyServer") ?? "http://178.105.123.75")
            .trimmingCharacters(in: .whitespaces)
    }

    static func register(vkToken: String, tgBot: String, tgChat: String) async throws {
        try await post("/register", ["vk_token": vkToken, "tg_bot_token": tgBot, "tg_chat_id": tgChat])
    }

    static func unregister(vkToken: String) async throws {
        try await post("/unregister", ["vk_token": vkToken])
    }

    private static func post(_ path: String, _ body: [String: String]) async throws {
        guard let url = URL(string: base + path) else { throw VKError(error_code: -1, error_msg: "Неверный адрес сервера") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw VKError(error_code: -1, error_msg: "Сервер недоступен или отклонил запрос")
        }
    }
}
