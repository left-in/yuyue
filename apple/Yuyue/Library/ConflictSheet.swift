import SwiftUI
import YuyueCore

/// 同步冲突 (prototype 28): a thought changed on two devices apart. Both are laid side by side —
/// which device, when, the words that differ tinted — and nothing is overwritten until one is
/// chosen: 留这份, 两份都留, or 用较新的.
struct NoteConflictsSheet: View {
    let library: Library
    @State private var conflicts: [NoteConflict]
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss
    private let tint = YYTint.standard

    init(library: Library, conflicts: [NoteConflict]) {
        self.library = library
        _conflicts = State(initialValue: conflicts)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let c = conflicts[safe: index] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("两台设备上的这条笔记不一样").font(YYUI.font(17, .bold)).foregroundStyle(YYColor.t1)
                        HStack(spacing: YYUI.s(6)) {
                            if let book = library.books.first(where: { $0.id == c.book }) {
                                BookCover(book: book).frame(width: YYUI.s(12), height: YYUI.s(17))
                            }
                            Text("\(c.bookTitle) · 划线的想法").font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                        }
                        .padding(.top, YYUI.s(6))
                        Text(highlighted(c.text))
                            .font(YYUI.font(14, design: .serif))
                            .lineSpacing(YYUI.s(14) * 0.75)
                            .foregroundStyle(YYColor.t1)
                            .padding(.top, YYUI.s(14))
                        let (older, newer) = Self.diff(c.older.note ?? "", c.newer.note ?? "")
                        VStack(spacing: YYUI.s(10)) {
                            side(c.newer.thisDevice ? c.newer : c.older, c.newer.thisDevice ? newer : older, newer: c.newer.thisDevice, choice: c.newer.thisDevice ? .newer : .older)
                            side(c.newer.thisDevice ? c.older : c.newer, c.newer.thisDevice ? older : newer, newer: !c.newer.thisDevice, choice: c.newer.thisDevice ? .older : .newer)
                        }
                        .padding(.top, YYUI.s(18))
                        YYNote(String(localized: "标了底色的是两份不一样的字。"))
                    }
                    .padding(.horizontal, YYUI.s(18))
                    .padding(.bottom, YYUI.s(16))
                }
                .scrollBounceBehavior(.basedOnSize)
                VStack(spacing: YYUI.s(10)) {
                    Text("你选之前，两份都留着，不会偷偷覆盖").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                    HStack(spacing: YYUI.s(10)) {
                        Button("两份都留") { choose(.both) }.buttonStyle(YYButtonStyle(kind: .raised, size: .large, wide: true))
                        Button("用较新的") { choose(.newer) }.buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
                    }
                }
                .padding(.horizontal, YYUI.s(16))
                .padding(.bottom, YYUI.s(14))
            }
        }
        .background(YYColor.bg)
        #if os(macOS)
        .frame(width: 440, height: 600)
        #endif
    }

    private var header: some View {
        ZStack {
            VStack(spacing: YYUI.s(1)) {
                Text("同步冲突").font(YYUI.font(13, .semibold)).foregroundStyle(YYColor.t1)
                if conflicts.count > 1 {
                    Text("第 \(index + 1) 处，共 \(conflicts.count) 处").font(YYUI.font(9.5)).foregroundStyle(YYColor.t3)
                }
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
                        .frame(width: YYUI.s(32), height: YYUI.s(32))
                        .background(YYColor.card, in: .circle)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关上")
                Spacer()
            }
        }
        .padding(.horizontal, YYUI.s(16))
        .padding(.top, YYUI.s(14))
        .padding(.bottom, YYUI.s(16))
    }

    private func highlighted(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        s.backgroundColor = MarkStyle.yellow.fill
        return s
    }

    /// `.v-cf-side`: the device, when it was written, 较新 on the newer, 留这份, and the thought.
    private func side(_ s: ConflictSide, _ text: AttributedString, newer: Bool, choice: ConflictChoice) -> some View {
        VStack(alignment: .leading, spacing: YYUI.s(10)) {
            HStack(spacing: YYUI.s(8)) {
                Image(systemName: Self.symbol(s.platform)).font(YYUI.font(12)).foregroundStyle(YYColor.t2)
                VStack(alignment: .leading, spacing: YYUI.s(1)) {
                    HStack(spacing: YYUI.s(5)) {
                        Text(s.thisDevice ? String(localized: "这台 \(Library.platformWord)") : s.deviceName).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                        if newer { YYTag(text: String(localized: "较新")) }
                    }
                    Text("\(Self.when(s.at)) 改的").font(YYUI.font(9.5).monospacedDigit()).foregroundStyle(YYColor.t3)
                }
                Spacer(minLength: 0)
                Button("留这份") { choose(choice) }.buttonStyle(YYButtonStyle(kind: .plain, size: .small))
            }
            Text(s.note == nil ? AttributedString(String(localized: "（没写想法）")) : text)
                .font(.custom("Kaiti SC", size: YYUI.s(12.5)))
                .lineSpacing(YYUI.s(12.5) * 0.7)
                .foregroundStyle(s.note == nil ? YYColor.t3 : tint.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, YYUI.s(10))
                .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
        }
        .padding(YYUI.s(13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .yyCard()
    }

    private func choose(_ choice: ConflictChoice) {
        guard let c = conflicts[safe: index] else { return }
        do {
            try library.core.resolveNoteConflict(book: c.book, mark: c.mark, choice: choice)
        } catch {
            library.alert = Library.message(for: error)
            return
        }
        NotificationCenter.default.post(name: .notesChanged, object: nil)
        conflicts.remove(at: index)
        if conflicts.isEmpty {
            dismiss()
        } else {
            index = min(index, conflicts.count - 1)
        }
    }

    /// The two thoughts with what differs between them tinted: whatever lies between the
    /// part they start with alike and the part they end with alike.
    static func diff(_ a: String, _ b: String) -> (AttributedString, AttributedString) {
        let (x, y) = (Array(a), Array(b))
        var start = 0
        while start < min(x.count, y.count), x[start] == y[start] { start += 1 }
        var end = 0
        while end < min(x.count, y.count) - start, x[x.count - 1 - end] == y[y.count - 1 - end] { end += 1 }
        func mark(_ chars: [Character]) -> AttributedString {
            var out = AttributedString(String(chars[..<start]))
            var middle = AttributedString(String(chars[start..<(chars.count - end)]))
            middle.backgroundColor = YYTint.standard.accentSoft
            out += middle
            out += AttributedString(String(chars[(chars.count - end)...]))
            return out
        }
        return (mark(x), mark(y))
    }

    static func symbol(_ platform: String) -> String {
        switch platform {
        case "macos": "laptopcomputer"
        case "ipados": "ipad"
        case "android": "smartphone"
        default: "iphone"
        }
    }

    /// `今天 8:12`, `昨天 22:14`, `10 月 2 日 21:40`.
    static func when(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let cal = Calendar.current
        let time = String(format: "%d:%02d", cal.component(.hour, from: date), cal.component(.minute, from: date))
        if cal.isDateInToday(date) { return String(localized: "今天 \(time)") }
        if cal.isDateInYesterday(date) { return String(localized: "昨天 \(time)") }
        return String(localized: "\(cal.component(.month, from: date)) 月 \(cal.component(.day, from: date)) 日 \(time)")
    }
}

/// `.v-cf-bar`: N 处笔记两边不一样, under the sync status, until each is chosen.
struct ConflictsBanner: View {
    let library: Library
    /// Below it, when it shows.
    var spacing: CGFloat = 0
    /// Above it, when it shows.
    var above: CGFloat = 0
    @State private var conflicts: [NoteConflict] = []
    @State private var shown = false

    var body: some View {
        // A stack even when empty, so it's there to load and to hear syncs.
        VStack(spacing: 0) {
            if !conflicts.isEmpty {
                Button { shown = true } label: {
                    HStack(spacing: YYUI.s(10)) {
                        Image(systemName: "rectangle.on.rectangle").font(YYUI.font(12, .medium)).foregroundStyle(YYColor.warn)
                            .frame(width: YYUI.s(28), height: YYUI.s(28))
                            .background(YYColor.warn.opacity(0.13), in: .circle)
                        VStack(alignment: .leading, spacing: YYUI.s(1)) {
                            Text("\(conflicts.count) 处笔记两边不一样").font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                            Text("两份都留着，等你来选").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                        }
                        Spacer(minLength: 0)
                        Text("去选").font(YYUI.font(10.5, .semibold)).foregroundStyle(YYColor.t1)
                            .padding(.horizontal, YYUI.s(10)).frame(height: YYUI.s(26))
                            .background(YYColor.inset, in: .capsule)
                    }
                    .padding(YYUI.s(12))
                    .yyCard()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, above)
                .padding(.bottom, spacing)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: load)
        .onChange(of: library.sync.lastSynced) { load() }
        .sheet(isPresented: $shown, onDismiss: load) { NoteConflictsSheet(library: library, conflicts: conflicts) }
    }

    private func load() {
        conflicts = (try? library.core.noteConflicts()) ?? []
        #if DEBUG
        // `-debugConflict 1` makes one up from the first highlight, to look at the page.
        if conflicts.isEmpty, UserDefaults.standard.bool(forKey: "debugConflict"),
           let book = library.books.first(where: { (try? library.core.marks(book: $0.id))?.isEmpty == false }),
           let mark = try? library.core.marks(book: book.id).first {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let mine = ConflictSide(deviceName: "", platform: "ios", thisDevice: true, at: now - 3_600_000, note: String(localized: "这一段每次读都会停下来。"))
            let theirs = ConflictSide(deviceName: "MacBook Air", platform: "macos", thisDevice: false, at: now - 600_000,
                                      note: String(localized: "这一段每次读都会停下来。他探身下去的样子，和我父亲一模一样。"))
            conflicts = [NoteConflict(book: book.id, bookTitle: book.title, mark: mark.id, section: mark.section, text: mark.text, older: mine, newer: theirs),
                         NoteConflict(book: book.id, bookTitle: book.title, mark: mark.id, section: mark.section, text: mark.text, older: theirs, newer: mine)]
            shown = true
        }
        #endif
    }
}
