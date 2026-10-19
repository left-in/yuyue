import SwiftUI

/// The glass note at the bottom after deleting or importing, with 撤销 and a line running out
/// over the seconds it stays. A delete shows red.
struct UndoToast: View {
    let toast: Library.Toast
    let undo: () -> Void
    @State private var left: CGFloat = 1
    private let tint = YYTint.standard

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.danger ? YYColor.danger : tint.accent)
                .frame(width: 36, height: 36)
                .background((toast.danger ? YYColor.danger.opacity(0.14) : tint.accentSoft), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(YYColor.t2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if toast.undo != nil {
                Button(action: undo) {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                        .labelStyle(TightLabel())
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tint.onBlack)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(tint.black, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("z")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
        .yyGlass(Capsule(), fill: YYColor.glass.opacity(0.5), shadow: 0)
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule()
                    .fill(tint.accent.opacity(0.55))
                    .frame(width: g.size.width * left, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 24)
        }
        .clipShape(.capsule)
        .overlay(Capsule().strokeBorder(YYColor.line.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 15, y: 8)
        .onAppear {
            withAnimation(.linear(duration: Library.toastSeconds)) { left = 0 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "撤销", undo)
    }

    private var detail: String {
        #if os(macOS)
        toast.undo != nil ? String(localized: "\(toast.detail) · ⌘Z 也能撤销") : toast.detail
        #else
        toast.detail
        #endif
    }
}
