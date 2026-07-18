import SwiftUI

// VK sometimes answers with error 14 (captcha needed). We don't bypass it — we show it and retry.
@MainActor
final class CaptchaCenter: ObservableObject {
    static let shared = CaptchaCenter()

    struct Challenge: Identifiable {
        let id = UUID()
        let sid: String
        let imageURL: URL?
    }

    @Published var challenge: Challenge?
    private var cont: CheckedContinuation<String?, Never>?

    // Suspends until the user solves the captcha (returns key) or cancels (nil).
    func request(sid: String, imageURL: String) async -> String? {
        // if one is already showing, don't stack — just fail this one
        if challenge != nil { return nil }
        return await withCheckedContinuation { c in
            self.cont = c
            self.challenge = Challenge(sid: sid, imageURL: URL(string: imageURL))
        }
    }

    func submit(_ key: String?) {
        challenge = nil
        cont?.resume(returning: key)
        cont = nil
    }
}

struct CaptchaView: View {
    let challenge: CaptchaCenter.Challenge
    @State private var answer = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Введите капчу").font(.headline)
                Text("VK просит подтвердить, что вы не бот.")
                    .font(.caption).foregroundStyle(.secondary)
                CachedImage(url: challenge.imageURL, fill: false, placeholder: .gray.opacity(0.2))
                    .frame(height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                TextField("код с картинки", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Button("Отмена") { CaptchaCenter.shared.submit(nil) }
                    Spacer()
                    Button("Ок") { CaptchaCenter.shared.submit(answer) }
                        .buttonStyle(.borderedProminent)
                        .disabled(answer.isEmpty)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(40)
        }
    }
}
