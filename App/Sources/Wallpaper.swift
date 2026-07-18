import SwiftUI
import UIKit

struct WPPreset: Identifiable {
    let id: Int
    let name: String
    let colors: [Color]   // empty = system background
}

enum Wallpaper {
    static let presets: [WPPreset] = [
        WPPreset(id: 0, name: "Стандарт", colors: [Color(hex: "#3A8DFF")!.opacity(0.16),
                                                   Color.purple.opacity(0.10),
                                                   Color(hex: "#3A8DFF")!.opacity(0.05)]),
        WPPreset(id: 1, name: "Небо", colors: [Color(hex: "#2AABEE")!.opacity(0.30), Color(hex: "#0077FF")!.opacity(0.15)]),
        WPPreset(id: 2, name: "Закат", colors: [Color(hex: "#FF9500")!.opacity(0.25), Color(hex: "#FF2D55")!.opacity(0.18)]),
        WPPreset(id: 3, name: "Лес", colors: [Color(hex: "#34C759")!.opacity(0.22), Color(hex: "#00C7BE")!.opacity(0.15)]),
        WPPreset(id: 4, name: "Ночь", colors: [Color(hex: "#5E5CE6")!.opacity(0.35), Color.black.opacity(0.20)]),
        WPPreset(id: 5, name: "Нет", colors: []),
    ]

    private static func dir() -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func imagePath(peer: Int) -> String { dir().appendingPathComponent("\(peer).jpg").path }
    static func hasImage(peer: Int) -> Bool { FileManager.default.fileExists(atPath: imagePath(peer: peer)) }
    static func setImage(peer: Int, data: Data) {
        let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
        try? jpeg.write(to: URL(fileURLWithPath: imagePath(peer: peer)))
    }
    static func removeImage(peer: Int) { try? FileManager.default.removeItem(atPath: imagePath(peer: peer)) }
}

// Background for a chat: per-chat image if set, else the global preset gradient.
struct WallpaperBackground: View {
    let peerId: Int
    var refresh: Int = 0
    @AppStorage("wallpaper") private var presetIndex = 0

    var body: some View {
        Group {
            if Wallpaper.hasImage(peer: peerId), let ui = UIImage(contentsOfFile: Wallpaper.imagePath(peer: peerId)) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                let preset = Wallpaper.presets[min(presetIndex, Wallpaper.presets.count - 1)]
                if preset.colors.isEmpty {
                    Color(.systemBackground)
                } else {
                    LinearGradient(colors: preset.colors, startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .id(refresh)
        .ignoresSafeArea()
    }
}
