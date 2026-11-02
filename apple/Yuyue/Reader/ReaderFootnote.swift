import SwiftUI
import YuyueCore

/// A note marker tapped: what it points to, shown in place (prototype R7).
struct OpenNote: Equatable {
    let note: Footnote
    /// The marker's own text, "1".
    let label: String
    /// The words just before the marker.
    let before: String
    /// Where the notes page is, for 到注释页.
    let target: String
}

/// 脚注: 注 1 and the words it is on, the note, and the way to the notes page with "回到原处"
/// left behind.
struct FootnoteCard: View {
    let open: OpenNote
    let bookTitle: String
    let tint: YYTint
    let toNotes: () -> Void
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(open.label.isEmpty ? String(localized: "注") : String(localized: "注 \(open.label)")).font(.yy(size: 13, weight: .semibold)).foregroundStyle(tint.accent)
                if !open.before.isEmpty {
                    Text(open.before).font(.yy(size: 12)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer()
                Button(action: done) {
                    Image(systemName: "xmark").font(.yy(size: 10, weight: .bold)).foregroundStyle(YYColor.t3)
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关上注释")
            }
            ScrollView {
                Text(open.note.text)
                    .font(YYUI.serif(15))
                    .lineSpacing(6)
                    .foregroundStyle(YYColor.t1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .padding(.bottom, 10)
            HStack {
                Text(footer).font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1)
                Spacer()
                Button(action: toNotes) {
                    HStack(spacing: 2) {
                        Text("到注释页")
                        Image(systemName: "chevron.right").font(.yy(size: 9, weight: .semibold))
                    }
                    .font(.yy(size: 12, weight: .medium))
                    .foregroundStyle(YYColor.t2)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 9)
            .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .yyFloatCard(.rect(cornerRadius: 16), shadow: scheme == .dark ? YYShadow.floatDark : YYShadow.floatLight)
    }

    /// "呐喊 · 注释 1 / 8".
    private var footer: String {
        let place = open.note.index.map { String(localized: "注释 \($0) / \(open.note.count)") } ?? open.note.title
        return [bookTitle, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
