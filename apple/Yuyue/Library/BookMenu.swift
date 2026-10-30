import SwiftUI
import YuyueCore
#if os(macOS)
import AppKit
#endif

/// What right-clicking a book offers. Not the system menu: the app's own white card, the same
/// as the one over selected text, with the book's progress on top.
enum BookAction: CaseIterable {
    case resume, listenFromStart, audiobook, toggleFinished
    case editInfo, addToCollection, revealInFinder, delete

    static let groups: [[BookAction]] = [
        [.resume, .listenFromStart, .audiobook, .toggleFinished],
        [.editInfo, .addToCollection, .revealInFinder, .delete],
    ]

    /// 有声书… only with a recording laid against it.
    static func groups(for book: BookSummary) -> [[BookAction]] {
        let recorded = Audiobooks.shared?.audiobook(for: book.id) != nil
        return groups.map { $0.filter { $0 != .audiobook || recorded } }
    }

    func title(for book: BookSummary) -> String {
        return switch self {
        case .resume: book.progress > 0 ? String(localized: "接着读") : String(localized: "开始读")
        case .listenFromStart: String(localized: "从头听")
        case .audiobook: String(localized: "有声书…")
        case .toggleFinished: book.status == .finished ? String(localized: "标为没读完") : String(localized: "标为读完")
        case .editInfo: String(localized: "编辑信息…")
        case .addToCollection: String(localized: "加入合集…")
        case .revealInFinder: String(localized: "在访达中显示")
        case .delete: String(localized: "删除")
        }
    }

    func symbol(for book: BookSummary) -> String {
        switch self {
        case .resume: "book"
        case .listenFromStart: "headphones"
        case .audiobook: "waveform"
        case .toggleFinished: book.status == .finished ? "arrow.uturn.backward" : "checkmark"
        case .editInfo: "pencil"
        case .addToCollection: "rectangle.stack"
        case .revealInFinder: "folder"
        case .delete: "trash"
        }
    }
}

#if os(macOS)
struct BookMenuCard: View {
    let book: BookSummary
    let perform: (BookAction) -> Void
    let close: () -> Void

    @State private var cursor: BookAction?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A line only between groups, at the top of each.
            ForEach(Array(BookAction.groups(for: book).enumerated()), id: \.offset) { _, group in
                VStack(spacing: 0) {
                    ForEach(group, id: \.self) { action in row(action) }
                }
                .padding(.vertical, 4)
                .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.horizontal, 14) }
            }
        }
        .frame(width: 214)
        .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
        .yyShadow(scheme == .dark ? YYShadow.floatDark : YYShadow.floatLight)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            let all = BookAction.groups(for: book).flatMap { $0 }
            switch press.key {
            case .escape:
                close()
            case .downArrow, .upArrow:
                let i = cursor.flatMap { all.firstIndex(of: $0) } ?? (press.key == .downArrow ? -1 : all.count)
                cursor = all[(i + (press.key == .downArrow ? 1 : -1) + all.count) % all.count]
            case .return, .space:
                if let cursor { perform(cursor) }
            default:
                return .ignored
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("《\(book.title)》")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(book.title)
                    .font(.yy(size: 13, weight: .bold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let author = book.author {
                    Text(author)
                        .font(.yy(size: 10.5))
                        .foregroundStyle(YYColor.t3)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                // Not started: no line, only 还没读.
                if book.progress > 0 { ProgressLine(value: book.progress, height: 2.5) }
                Text(book.remaining)
                    .font(.yy(size: 10.5))
                    .foregroundStyle(YYColor.t2)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private func row(_ action: BookAction) -> some View {
        let color: Color = switch action {
        case .resume: tint.accent
        case .delete: YYColor.danger
        default: YYColor.t1
        }
        return Button { perform(action) } label: {
            HStack {
                Text(action.title(for: book))
                    .font(.yy(size: 12.5, weight: action == .resume ? .semibold : .regular))
                Spacer()
                Image(systemName: action.symbol(for: book))
                    .font(.yy(size: 13))
                    .frame(width: 15)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(cursor == action ? YYColor.inset : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { if $0 { cursor = action } else if cursor == action { cursor = nil } }
    }
}

/// Catches right-clicks (and control-clicks) on the view under it, leaving every other click
/// to SwiftUI. Says where, in the window's coordinates (top left at zero, as SwiftUI's global).
struct RightClickCatcher: NSViewRepresentable {
    let action: (CGPoint) -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.action = action
    }

    final class Catcher: NSView {
        var action: ((CGPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { report(event) }
        override func mouseDown(with event: NSEvent) { report(event) }

        private func report(_ event: NSEvent) {
            guard let content = window?.contentView else { return }
            var p = content.convert(event.locationInWindow, from: nil)
            if !content.isFlipped { p.y = content.bounds.height - p.y }
            action?(p)
        }
    }
}
#endif
