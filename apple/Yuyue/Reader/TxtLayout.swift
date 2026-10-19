import SwiftUI
import YuyueCore

/// 编码和目录 (prototype R12), for a TXT: which encoding it is read in, with the first lines to
/// see whether they read, and the rule that finds its chapters, with what it found. A chapter far
/// longer than the others is pointed out. 完成 builds the book again the chosen way.
struct TxtLayoutView: View {
    let library: Library
    let bookID: String
    let bookTitle: String
    /// Opens the reader at a section; none outside the reader.
    var go: ((UInt32) -> Void)?
    let done: () -> Void

    @State private var applied = TxtChoice(encoding: nil, rule: nil)
    @State private var choice = TxtChoice(encoding: nil, rule: nil)
    @State private var rule = ""
    @State private var layout: TxtLayout?
    @State private var working = false
    @State private var failure: String?
    @State private var loaded = false

    private static let encodings: [(String?, String)] = [(nil, String(localized: "自动")), ("UTF-8", "UTF-8"), ("GB18030", "GB18030"), ("Big5", "Big5")]
    /// Chapters listed before the rest are folded away.
    private static let shownChapters = 3

    private var core: YuyueCore { library.core }
    private var changed: Bool { choice != applied }

    var body: some View {
        YYPage {
            encodingPart
            chapterPart
            if let layout, let long = layout.long.map(Int.init), layout.chapters.indices.contains(long) {
                warning(layout, long)
            } else if let doubt = layout?.doubt, layout?.unreadable == 0 {
                Label(doubt, systemImage: "exclamationmark.triangle.fill")
                    .font(YYUI.font(11)).foregroundStyle(YYColor.warn)
                    .padding(.top, YYUI.s(10))
            }
        }
        .navigationTitle("编码和目录")
        #if os(macOS)
        .navigationSubtitle(fileLine)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("编码和目录").font(.headline)
                    Text(fileLine).font(.caption2).foregroundStyle(YYColor.t3)
                }
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: done).disabled(working) }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", action: finish)
                    .fontWeight(.semibold)
                    .disabled(working || layout?.error != nil)
            }
        }
        .overlay {
            if working {
                ProgressView(String(localized: "正在按新的方式整理这本书…"))
                    .padding(20)
                    .background(.regularMaterial, in: .rect(cornerRadius: 14))
            }
        }
        .task(id: choice) { await refresh() }
        .onAppear(perform: load)
        .alert("没能改好", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var fileLine: String {
        let size = layout.map { ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) }
        return ["\(bookTitle).txt", size].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 编码

    @ViewBuilder private var encodingPart: some View {
        YYLabel(String(localized: "编码"), layout.map { String(localized: "自动识别为 \($0.detected)") })
        YYSegments(
            items: Self.encodings.map { value, name in
                (value, value == nil ? [String(localized: "自动"), layout?.detected].compactMap { $0 }.joined(separator: " · ") : name)
            },
            selection: $choice.encoding
        )
        previewCard
        if let n = layout?.unreadable, n > 0 {
            Label("有 \(n) 处字认不出来，换一种编码试试", systemImage: "exclamationmark.triangle.fill")
                .font(YYUI.font(10.5)).foregroundStyle(YYColor.danger)
                .padding(.top, YYUI.s(8))
                .padding(.horizontal, YYUI.s(4))
        }
    }

    /// `.v-rd-txt`: the first chapter's title and lines, in the encoding chosen.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: YYUI.s(4)) {
            if let layout, !layout.preview.isEmpty {
                if let title = layout.previewTitle {
                    Text(title).font(YYUI.font(12, .bold, design: .serif))
                }
                ForEach(Array(layout.preview.enumerated()), id: \.offset) { _, p in
                    Text("\u{3000}\u{3000}" + p)
                        .font(YYUI.font(11.5, design: .serif))
                        .lineSpacing(YYUI.s(11.5) * 0.8)
                        .lineLimit(3)
                }
            } else {
                Text(layout?.error == nil ? String(localized: "正在读…") : String(localized: "这种编码读不出字")).font(YYUI.font(11.5)).foregroundStyle(YYColor.t3)
            }
        }
        .foregroundStyle(YYColor.t1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, YYUI.s(12))
        .padding(.horizontal, YYUI.s(14))
        .yyCard()
        .padding(.top, YYUI.s(10))
    }

    // MARK: 目录

    @ViewBuilder private var chapterPart: some View {
        YYLabel(String(localized: "目录"), layout.flatMap { $0.error == nil ? String(localized: "识别出 \($0.chapters.count.formatted()) 章") : nil })
        YYGroup {
            YYField(label: String(localized: "目录规则"), labelWidth: 52) { ruleField }
            if let error = layout?.error {
                Text(error).font(YYUI.font(10.5)).foregroundStyle(YYColor.danger).frame(minHeight: YYUI.s(34))
            } else if let layout {
                let chapters = layout.chapters
                let long = layout.long.map(Int.init)
                ForEach(Array(chapters.prefix(Self.shownChapters).enumerated()), id: \.offset) { i, c in
                    chapterRow(c, long: i == long)
                }
                if chapters.count > Self.shownChapters {
                    if let long, long >= Self.shownChapters {
                        NavigationLink { allChapters(layout) } label: {
                            Text("⋯").font(YYUI.font(11)).kerning(YYUI.s(2)).foregroundStyle(YYColor.t3)
                                .frame(maxWidth: .infinity).frame(height: YYUI.s(22)).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("全部 \(chapters.count) 章")
                        chapterRow(chapters[long], long: true)
                    } else {
                        NavigationLink { allChapters(layout) } label: {
                            YYRow(String(localized: "全部 \(chapters.count.formatted()) 章"), chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if choice.rule != nil {
            Button("用回自动识别") {
                rule = ""
                choice.rule = nil
            }
            .font(YYUI.font(10.5, .medium))
            .buttonStyle(.plain)
            .foregroundStyle(YYTint.standard.accent)
            .padding(.top, YYUI.s(6))
            .padding(.horizontal, YYUI.s(4))
        } else {
            YYNote(String(localized: "每一行从头比对规则，对上的就是一章的标题。自动识别还认得序章、楔子、Chapter 1 这些。"))
        }
    }

    private var ruleField: some View {
        TextField("目录规则", text: $rule, prompt: Text(layout?.defaultRule ?? ""))
            .textFieldStyle(.plain)
            .font(YYUI.font(10.5, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { choice.rule = rule.isEmpty ? nil : rule }
            .onChange(of: rule) { _, new in
                // Typed rules are tried once the typing pauses; see `refresh`.
                choice.rule = new.trimmingCharacters(in: .whitespaces).isEmpty ? nil : new
            }
    }

    /// `.v-rd-cl`: a chapter and how long it is, the one too long in the warning colour.
    private func chapterRow(_ c: TxtChapter, long: Bool) -> some View {
        HStack(spacing: YYUI.s(8)) {
            Text(c.title).font(YYUI.font(11)).lineLimit(1).foregroundStyle(YYColor.t1)
            Spacer()
            Text("\(c.chars.formatted()) 字")
                .font(YYUI.font(10, long ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(long ? YYColor.warn : YYColor.t3)
        }
        .frame(height: YYUI.s(34))
    }

    private func allChapters(_ layout: TxtLayout) -> some View {
        YYPage {
            YYGroup {
                ForEach(Array(layout.chapters.enumerated()), id: \.offset) { i, c in
                    chapterRow(c, long: layout.long.map(Int.init) == i)
                }
            }
            .padding(.top, YYUI.s(12))
        }
        .navigationTitle("\(layout.chapters.count.formatted()) 章")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: 长得不正常的一章

    /// `.v-rd-warn`: which two chapters a long stretch lies between, how long the others are, and
    /// the way there.
    private func warning(_ layout: TxtLayout, _ long: Int) -> some View {
        let c = layout.chapters[long]
        // Chapter numbers as the reader counts them: the untitled start isn't one.
        let n = long + (layout.chapters.first?.title == String(localized: "开头") ? 0 : 1)
        let hasNext = layout.chapters.indices.contains(long + 1)
        let sizes = layout.chapters.map(\.chars).sorted()
        let usual = sizes[sizes.count / 2]
        return HStack(alignment: .top, spacing: YYUI.s(9)) {
            Image(systemName: "exclamationmark.triangle.fill").font(YYUI.font(13)).foregroundStyle(YYColor.warn)
            VStack(alignment: .leading, spacing: YYUI.s(2)) {
                Text(hasNext ? String(localized: "第 \(n) 和 \(n + 1) 章之间有 \(wan(c.chars))字，可能漏了一章") : String(localized: "第 \(n) 章之后有 \(wan(c.chars))字，可能漏了几章"))
                    .font(YYUI.font(11, .semibold)).foregroundStyle(YYColor.t1)
                Text("别的章都在 \(roughly(usual))字上下，多半是这里有一章的标题写法不一样，没认出来。")
                    .font(YYUI.font(10)).foregroundStyle(YYColor.t2)
                    .fixedSize(horizontal: false, vertical: true)
                if let go, !changed {
                    Button("去第 \(n) 章看看") { go(c.section) }
                        .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                        .padding(.top, YYUI.s(7))
                } else if go != nil {
                    Text("点完成后可以去这一章看看").font(YYUI.font(10)).foregroundStyle(YYColor.t3).padding(.top, YYUI.s(4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, YYUI.s(11))
        .padding(.bottom, YYUI.s(12))
        .padding(.horizontal, YYUI.s(12))
        .background(YYColor.warn.opacity(0.11), in: .rect(cornerRadius: YYUI.s(14)))
        .padding(.top, YYUI.s(10))
    }

    /// 31,240 → "3 万", 15,600 → "1.6 万", 9,794 → "1 万".
    private func wan(_ n: UInt32) -> String {
        let w = Double(n) / 10_000
        let tenths = Int((w * 10).rounded())
        return w >= 2 || tenths % 10 == 0 ? String(localized: "\(Int(w.rounded())) 万") : String(localized: "\(tenths / 10).\(tenths % 10) 万")
    }

    /// 3,105 → "3 千", 820 → "800 ".
    private func roughly(_ n: UInt32) -> String {
        if n >= 10_000 { return wan(n) }
        if n >= 1_000 { return String(localized: "\(Int((Double(n) / 1_000).rounded())) 千") }
        return "\(Int((Double(n) / 100).rounded()) * 100) "
    }

    // MARK: Work

    private func load() {
        guard !loaded else { return }
        loaded = true
        let now = (try? core.txtChoice(bookId: bookID)) ?? TxtChoice(encoding: nil, rule: nil)
        applied = now
        choice = now
        rule = now.rule ?? ""
    }

    private func refresh() async {
        // A rule being typed is tried once the typing pauses; a tapped encoding at once.
        if layout != nil { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        let core = core, book = bookID, choice = choice
        let found = await Task.detached { try? core.txtLayout(bookId: book, choice: choice) }.value
        guard !Task.isCancelled else { return }
        layout = found
    }

    private func finish() {
        guard changed else { return done() }
        working = true
        let core = core, book = bookID, choice = choice
        // Open readers write where they are, in the old chapters, before the core moves it.
        NotificationCenter.default.post(name: .bookWillRebuild, object: book)
        Task {
            let result = await Task.detached { Result { try core.setTxtChoice(bookId: book, choice: choice) } }.value
            working = false
            library.reload()
            NotificationCenter.default.post(name: .bookRebuilt, object: book)
            switch result {
            case .success: done()
            case .failure(let error): failure = Library.message(for: error)
            }
        }
    }
}
