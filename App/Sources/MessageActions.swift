import SwiftUI

// TG-style long-press overlay: horizontal reaction pill + a glass action menu.
struct MessageActionsOverlay: View {
    let cm: ChatMessage
    let mine: Bool
    let isChat: Bool
    let onReact: (Int) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDeleteForMe: () -> Void
    let onDeleteForAll: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { onDismiss() }
            VStack(spacing: 12) {
                reactionPill
                MessageRow(cm: cm, mine: mine, isChat: isChat)
                    .allowsHitTesting(false)
                menu
            }
            .padding(.horizontal, 20)
        }
    }

    private var reactionPill: some View {
        HStack(spacing: 10) {
            ForEach(reactionSet, id: \.id) { r in
                Button { onReact(r.id); onDismiss() } label: {
                    Text(r.emoji).font(.system(size: 30))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(in: Capsule())
    }

    private var menu: some View {
        VStack(spacing: 0) {
            row("Ответить", "arrowshape.turn.up.left", action: onReply)
            Divider()
            row("Копировать", "doc.on.doc", action: onCopy)
            Divider()
            row("Закрепить", "pin", action: onPin)
            Divider()
            row("Удалить у себя", "trash", destructive: true, action: onDeleteForMe)
            if mine {
                Divider()
                row("Удалить у всех", "trash.fill", destructive: true, action: onDeleteForAll)
            }
        }
        .glassEffect(in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 260)
    }

    private func row(_ title: String, _ icon: String, destructive: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button { action(); onDismiss() } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: icon)
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }
}
