import SwiftUI
import Photos
import UIKit

// Recent photos from the library. Requests access on load (like TG's attach panel).
@MainActor
final class GalleryModel: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var status: PHAuthorizationStatus = .notDetermined

    func load() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
            Task { @MainActor in
                self.status = st
                guard st == .authorized || st == .limited else { return }
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                opts.fetchLimit = 90
                let res = PHAsset.fetchAssets(with: .image, options: opts)
                var a: [PHAsset] = []
                res.enumerateObjects { obj, _, _ in a.append(obj) }
                self.assets = a
            }
        }
    }
}

func fullImageData(_ asset: PHAsset) async -> Data? {
    await withCheckedContinuation { cont in
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = true
        o.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in
            cont.resume(returning: data)
        }
    }
}

struct PhotoThumb: View {
    let asset: PHAsset
    @State private var img: UIImage?
    var body: some View {
        Group {
            if let img { Image(uiImage: img).resizable().scaledToFill() }
            else { Color.gray.opacity(0.15) }
        }
        .task(id: asset.localIdentifier) { load() }
    }
    private func load() {
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = true
        o.deliveryMode = .opportunistic
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: 240, height: 240),
            contentMode: .aspectFill, options: o) { image, _ in
            if let image { self.img = image }
        }
    }
}

// TG-style attach sheet: gallery grid + a glass row of options.
struct AttachSheet: View {
    let onImageData: (Data) -> Void
    let onGallery: () -> Void
    let onFile: () -> Void
    @StateObject private var gallery = GalleryModel()
    @Environment(\.dismiss) private var dismiss

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if gallery.status == .denied || gallery.status == .restricted {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Нет доступа к фото").foregroundStyle(.secondary)
                        Button("Открыть настройки") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }.padding(.top, 60)
                } else {
                    LazyVGrid(columns: cols, spacing: 3) {
                        ForEach(gallery.assets, id: \.localIdentifier) { asset in
                            Button {
                                Task {
                                    if let d = await fullImageData(asset) { onImageData(d); dismiss() }
                                }
                            } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)   // square cell
                                    .overlay { PhotoThumb(asset: asset) }
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                }
            }
            optionsRow
        }
        .task { gallery.load() }
    }

    private var optionsRow: some View {
        VStack(spacing: 8) {
            option("photo.on.rectangle.angled", "Открыть галерею", .blue, onGallery)
            option("folder.fill", "Файл", .indigo, onFile)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
        .background(.regularMaterial)
    }

    private func option(_ icon: String, _ label: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 10))
                Text(label).font(.body).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
