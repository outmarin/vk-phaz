import SwiftUI
import UIKit

// ponytail: NSCache + URLSession with one retry. AsyncImage cancels/fails silently in lazy stacks.
enum ImageStore {
    static let cache = NSCache<NSURL, UIImage>()
}

struct CachedImage: View {
    let url: URL?
    var fill = true
    var placeholder = Color.gray.opacity(0.15)
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let hit = ImageStore.cache.object(forKey: url as NSURL) { image = hit; return }
        for attempt in 0..<2 {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = UIImage(data: data) {
                ImageStore.cache.setObject(img, forKey: url as NSURL)
                image = img
                return
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
    }
}
