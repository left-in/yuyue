import SwiftUI

/// The note after deleting or importing, as 即刻's toast (its “已设置”, measured off a screenshot):
/// a pale grey capsule at the top, as wide as its one line, the same room either side, a small
/// filled round icon before the words. When the thing can be undone, 撤销 follows the words.
struct UndoToast: View {
    let toast: Library.Toast
    let undo: () -> Void
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @Environment(\.colorScheme) private var scheme

    /// 即刻's green tick; a deletion is red.
    static let done = Color(red: 0x2D / 255, green: 0xBE / 255, blue: 0x60 / 255)

    /// Every screen puts it centred at the top, coming down from above.
    static var transition: AnyTransition {
        .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .top))
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(toast.danger ? YYColor.danger : Self.done)
                Image(systemName: toast.danger ? "xmark" : "checkmark")
                    .font(.yy(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            Text(toast.title)
                .font(.yy(size: 15))
                .foregroundStyle(scheme == .dark ? Color(white: 0.92) : Color(white: 0.2))
                .lineLimit(1)
            if toast.undo != nil {
                Button(action: undo) {
                    Text("撤销")
                        .font(.yy(size: 15, weight: .medium))
                        .foregroundStyle(tint.accent)
                        .padding(.horizontal, 4)
                        .frame(height: 36)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("z")
            }
        }
        .padding(.horizontal, 25)
        .frame(height: 45)
        .background(scheme == .dark ? Color(white: 0.2).opacity(0.96) : Color(white: 0.915).opacity(0.97), in: .capsule)
        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 10, y: 3)
        .frame(maxWidth: 420)
        .help(toast.detail)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "撤销", undo)
    }
}
