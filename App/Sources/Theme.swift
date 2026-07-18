import SwiftUI

// Accent presets shown in Settings.
let accentPresets: [(name: String, hex: String)] = [
    ("Синий", "#3A8DFF"), ("Индиго", "#5E5CE6"), ("Бирюза", "#00C7BE"),
    ("Зелёный", "#34C759"), ("Оранжевый", "#FF9500"), ("Розовый", "#FF2D55"),
]

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard let v = UInt64(s, radix: 16), s.count == 6 else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

// Local, client-side pinned chats (VK API has no reliable per-user pin). ponytail: UserDefaults set.
enum Pins {
    static let key = "pinned_peers"
    static func get() -> Set<Int> {
        Set((UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: ",").compactMap { Int($0) })
    }
    static func toggle(_ peer: Int) {
        var s = get()
        if s.contains(peer) { s.remove(peer) } else { s.insert(peer) }
        UserDefaults.standard.set(s.map(String.init).joined(separator: ","), forKey: key)
    }
    static func has(_ peer: Int) -> Bool { get().contains(peer) }
}

// Deterministic avatar tint for placeholder circles.
func avatarTint(for id: Int) -> Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
    return palette[abs(id) % palette.count]
}

func initials(_ name: String) -> String {
    let parts = name.split(separator: " ").prefix(2)
    return parts.map { String($0.prefix(1)) }.joined().uppercased()
}

// "в сети" / "был(а) в сети N минут назад"
func lastSeenText(online: Bool, ts: Int?) -> String {
    if online { return "в сети" }
    guard let ts, ts > 0 else { return "" }
    let d = Date(timeIntervalSince1970: TimeInterval(ts))
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.unitsStyle = .full
    return "был(а) в сети " + f.localizedString(for: d, relativeTo: Date())
}

// Short time for chat-list rows: HH:mm today, else dd.MM.
func shortTime(_ ts: Int) -> String {
    guard ts > 0 else { return "" }
    let d = Date(timeIntervalSince1970: TimeInterval(ts))
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd.MM"
    return f.string(from: d)
}

func fullDate(_ ts: Int) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(ts))
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMM yyyy, HH:mm"
    return f.string(from: d)
}
