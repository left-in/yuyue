import SwiftUI
import YuyueCore

/// 替换规则 (prototype R10): this book's rules and the ones for every book, each saying what
/// becomes what, marked 正则 and 只改朗读, with a switch to turn one off. They run from the top
/// down and can be dragged into another order. A book open in a window follows at once.
struct ReplaceRulesView: View {
    let core: YuyueCore
    let bookID: String
    let bookTitle: String
    var done: (() -> Void)?

    enum Scope: Hashable { case book, all }

    @State private var scope = Scope.book
    @State private var mine: [ReplaceRule] = []
    @State private var shared: [ReplaceRule] = []
    @State private var editing: Editing?
    @State private var commonShown = false
    @State private var failure: String?
    /// U3: the rules just deleted, for 撤销 a few seconds.
    @State private var removed: [ReplaceRule] = []
    @State private var removedToken = UUID()

    struct Editing: Identifiable {
        var rule: ReplaceRule
        var id: String { rule.id.isEmpty ? "new" : rule.id }
    }

    private var rules: [ReplaceRule] { scope == .book ? mine : shared }

    var body: some View {
        YYPage {
            YYSegments(items: [(Scope.book, String(localized: "这本书")), (Scope.all, String(localized: "全部书"))], selection: $scope,
                       counts: [.book: mine.count, .all: shared.count])
                .padding(.top, YYUI.s(10))
                .padding(.bottom, YYUI.s(12))
            YYGroup {
                if rules.isEmpty {
                    Text(scope == .book ? String(localized: "这本书还没有自己的规则") : String(localized: "还没有用于全部书的规则"))
                        .font(YYUI.font(11.5)).foregroundStyle(YYColor.t3)
                        .frame(minHeight: YYUI.s(44))
                }
                ForEach(rules, id: \.id) { rule in
                    RuleRow(rule: rule) { on in setEnabled(rule, on) } edit: { editing = Editing(rule: rule) } remove: {
                        if let i = rules.firstIndex(where: { $0.id == rule.id }) { delete(IndexSet(integer: i)) }
                    }
                    .draggable(rule.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, let from = rules.firstIndex(where: { $0.id == id }),
                              let to = rules.firstIndex(where: { $0.id == rule.id }), from != to else { return false }
                        move(IndexSet(integer: from), to > from ? to + 1 : to)
                        return true
                    }
                }
                if !removed.isEmpty { undoRow.transition(.opacity) }
                #if os(macOS)
                // No bar over a sheet on the Mac to put + in.
                Button { editing = Editing(rule: blank) } label: {
                    HStack(spacing: YYUI.s(6)) {
                        Image(systemName: "plus")
                        Text("添加一条规则")
                    }
                    .font(YYUI.font(11.5, .medium))
                    .foregroundStyle(YYTint.standard.accent)
                    .frame(maxWidth: .infinity, minHeight: YYUI.s(38), alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                #endif
            }
            YYGroup {
                Button { commonShown = true } label: {
                    YYRow(String(localized: "从常用规则里挑"), icon: "slider.horizontal.3", value: String(localized: "网址水印、多余空行…"), chevron: true)
                }
                .buttonStyle(.plain)
                if scope == .book, !shared.isEmpty {
                    Button { scope = .all } label: {
                        YYRow(String(localized: "全部书的 \(shared.count) 条也在生效"), icon: "square.stack.3d.up", value: String(localized: "看看"), chevron: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, YYUI.s(12))
            YYNote(String(localized: "规则从上往下依次执行，按住一条可以拖动顺序。只改朗读的规则不动屏幕上的字，只改读出来的音。"))
        }
        .navigationTitle("替换规则")
        #if os(macOS)
        .navigationSubtitle(bookTitle)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("替换规则").font(.headline)
                    Text(bookTitle).font(.caption2).foregroundStyle(YYColor.t3)
                }
            }
        }
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button("添加规则", systemImage: "plus") { editing = Editing(rule: blank) }
            }
            #endif
            if let done {
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: done) }
            }
        }
        .sheet(item: $editing) { e in
            ReplaceRuleEditor(core: core, bookID: bookID, bookTitle: bookTitle, rule: e.rule) { saved in
                editing = nil
                if let saved {
                    changed(saved.book)
                    // 删掉这条规则 in the editor: gone from the lists now, so it can be brought back.
                    if !saved.id.isEmpty, !(mine + shared).contains(where: { $0.id == saved.id }) { justRemoved([saved]) }
                }
            }
        }
        .sheet(isPresented: $commonShown) { common }
        #if DEBUG
        .task {
            // `-debugRuleEdit 1`: 打开编辑器添一条新规则;`-debugRulesCommon 1`: 从常用规则里挑。
            let d = UserDefaults.standard
            if d.bool(forKey: "debugRuleEdit") { editing = Editing(rule: blank) }
            if d.bool(forKey: "debugRulesCommon") { commonShown = true }
        }
        #endif
        .alert("没能改好", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .onAppear(perform: load)
    }

    private var blank: ReplaceRule {
        ReplaceRule(id: "", book: scope == .book ? bookID : nil, find: "", replace: "", regex: false,
                    speechOnly: false, enabled: true, order: 0)
    }

    private func load() {
        mine = (try? core.replaceRules(book: bookID)) ?? []
        shared = (try? core.replaceRules(book: nil)) ?? []
    }

    private func changed(_ book: String?) {
        load()
        NotificationCenter.default.post(name: .replaceRulesChanged, object: book)
    }

    private func run(_ book: String?, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            failure = Library.message(for: error)
        }
        changed(book)
    }

    private func setEnabled(_ rule: ReplaceRule, _ on: Bool) {
        run(rule.book) { try core.setReplaceRuleEnabled(id: rule.id, enabled: on) }
    }

    private func delete(_ offsets: IndexSet) {
        let gone = offsets.map { rules[$0] }
        withAnimation(YYMotion.layout) {
            run(scope == .book ? bookID : nil) {
                for rule in gone { try core.deleteReplaceRule(id: rule.id) }
            }
        }
        justRemoved(gone)
    }

    private func justRemoved(_ gone: [ReplaceRule]) {
        withAnimation(YYMotion.standard) { removed = gone }
        let token = UUID()
        removedToken = token
        Task {
            try? await Task.sleep(for: .seconds(5))
            if removedToken == token { withAnimation(YYMotion.standard) { removed = [] } }
        }
    }

    /// 删掉了“A → B” · 撤销, for five seconds after a rule goes.
    private var undoRow: some View {
        HStack(spacing: YYUI.s(8)) {
            Image(systemName: "trash").foregroundStyle(YYColor.t3)
            Text(removed.count == 1
                 ? String(localized: "删掉了“\(removed[0].find) → \(removed[0].replace)”")
                 : String(localized: "删掉了 \(removed.count) 条规则"))
                .foregroundStyle(YYColor.t2)
                .lineLimit(1)
            Spacer(minLength: YYUI.s(8))
            Button("撤销") {
                let back = removed
                withAnimation(YYMotion.layout) {
                    run(back.first?.book) {
                        for rule in back { try core.restoreReplaceRule(id: rule.id) }
                    }
                    removed = []
                }
            }
            .font(YYUI.font(11.5, .semibold))
            .foregroundStyle(YYTint.standard.accent)
            .buttonStyle(.plain)
            #if os(macOS)
            .keyboardShortcut("z", modifiers: .command)
            #endif
        }
        .font(YYUI.font(11.5))
        .frame(minHeight: YYUI.s(38))
    }

    /// Gives the moved rule an order between its new neighbours.
    private func move(_ from: IndexSet, _ to: Int) {
        var list = rules
        list.move(fromOffsets: from, toOffset: to)
        guard let moved = from.first.map({ rules[$0] }), let i = list.firstIndex(where: { $0.id == moved.id }) else { return }
        let before = i > 0 ? list[i - 1].order : nil
        let after = i < list.count - 1 ? list[i + 1].order : nil
        let order = switch (before, after) {
        case let (b?, a?): (b + a) / 2
        case let (b?, nil): b + 1
        case let (nil, a?): a - 1
        case (nil, nil): moved.order
        }
        if scope == .book { mine = list } else { shared = list }
        run(moved.book) { try core.moveReplaceRule(id: moved.id, order: order) }
    }

    // MARK: 从常用规则里挑

    private var common: some View {
        NavigationStack {
            YYPage {
                YYGroup {
                    ForEach(core.commonReplaceRules(), id: \.title) { c in
                        let added = rules.contains { $0.find == c.rule.find && $0.regex == c.rule.regex }
                        HStack(spacing: YYUI.s(10)) {
                            VStack(alignment: .leading, spacing: YYUI.s(3)) {
                                Text(c.title).font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
                                Text(c.detail).font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
                            }
                            Spacer()
                            Button(added ? String(localized: "已添加") : String(localized: "添加")) {
                                var rule = c.rule
                                rule.book = scope == .book ? bookID : nil
                                run(rule.book) { _ = try core.saveReplaceRule(rule: rule) }
                            }
                            .buttonStyle(YYButtonStyle(kind: added ? .plain : .soft, size: .small))
                            .disabled(added)
                        }
                        .padding(.vertical, YYUI.s(10))
                    }
                }
                .padding(.top, YYUI.s(12))
                YYNote(String(localized: "挑中的规则会加到\(scope == .book ? String(localized: "这本书") : String(localized: "全部书"))，加完还能改、能关。"))
            }
            .navigationTitle(scope == .book ? String(localized: "加到这本书") : String(localized: "加到全部书"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { commonShown = false } } }
        }
        #if os(macOS)
        .frame(width: 420, height: 460)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}

/// `.v-rd-rule`: what is found, an arrow, what it becomes (or 删掉), its tags and its switch.
/// A rule turned off goes grey.
private struct RuleRow: View {
    let rule: ReplaceRule
    let toggle: (Bool) -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: YYUI.s(10)) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: YYUI.s(4)) {
                    Text(rule.find)
                        .font(rule.regex ? YYUI.font(11.5, .medium, design: .monospaced) : YYUI.font(12, .semibold))
                        .foregroundStyle(rule.enabled ? YYColor.t1 : YYColor.t3)
                        .lineLimit(1)
                    HStack(spacing: YYUI.s(5)) {
                        Image(systemName: "arrow.right").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
                        if rule.replace.isEmpty {
                            Text("删掉").foregroundStyle(rule.enabled ? YYColor.t2 : YYColor.t3)
                        } else {
                            Text(rule.replace).foregroundStyle(rule.enabled ? YYColor.t1 : YYColor.t3).lineLimit(1)
                        }
                        if rule.regex { YYTag(text: String(localized: "正则")) }
                        if rule.speechOnly { YYTag(text: String(localized: "只改朗读"), icon: "ear") }
                    }
                    .font(YYUI.font(10.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            YYSwitch(isOn: Binding(get: { rule.enabled }, set: toggle), label: rule.enabled ? String(localized: "关掉这条规则") : String(localized: "打开这条规则"))
        }
        .padding(.vertical, YYUI.s(10))
        .contextMenu {
            Button("编辑", systemImage: "pencil", action: edit)
            Button("删掉", systemImage: "trash", role: .destructive, action: remove)
        }
    }
}

/// 编辑一条规则 (prototype R11): 查找, 替换为, the 正则 switch, 改哪里 and 用于, and underneath a
/// preview that follows the typing: how many places in this book, the first one before and after.
struct ReplaceRuleEditor: View {
    let core: YuyueCore
    let bookID: String
    let bookTitle: String
    /// Nil when cancelled.
    let finish: (ReplaceRule?) -> Void
    @State private var rule: ReplaceRule
    private let originalBook: String?
    @State private var preview: RulePreview?
    @State private var detail: BookDetail?
    @State private var failure: String?
    @FocusState private var typing: Bool

    init(core: YuyueCore, bookID: String, bookTitle: String, rule: ReplaceRule, finish: @escaping (ReplaceRule?) -> Void) {
        self.core = core
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.finish = finish
        _rule = State(initialValue: rule)
        originalBook = rule.book
    }

    private var isNew: Bool { rule.id.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YYUI.s(12)) {
                YYSheetHeader(title: isNew ? String(localized: "添加规则") : String(localized: "编辑规则")) { finish(nil) }
                    .padding(.bottom, YYUI.s(2))
                YYGroup {
                    field(String(localized: "查找"), prompt: String(localized: "要换掉的字"), text: $rule.find, mono: rule.regex)
                        .focused($typing)
                    field(String(localized: "替换为"), prompt: String(localized: "留空就是删掉"), text: $rule.replace, mono: rule.regex)
                }
                YYGroup {
                    YYRow(title: String(localized: "正则表达式")) { YYSwitch(isOn: $rule.regex, label: String(localized: "正则表达式")) }
                    YYRow(title: String(localized: "改哪里")) {
                        YYSegments(items: [(false, String(localized: "显示和朗读")), (true, String(localized: "只改朗读"))], selection: $rule.speechOnly, small: true)
                            .frame(width: YYUI.s(150))
                    }
                    YYRow(title: String(localized: "用于")) {
                        YYSegments(items: [(true, String(localized: "这本书")), (false, String(localized: "全部书"))],
                                   selection: Binding(get: { rule.book != nil }, set: { rule.book = $0 ? bookID : nil }), small: true)
                            .frame(width: YYUI.s(150))
                    }
                }
                previewCard
                Button("保存", action: save)
                    .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.find.isEmpty || preview?.error != nil)
                if !isNew {
                    Button("删掉这条规则") {
                        do {
                            try core.deleteReplaceRule(id: rule.id)
                            finish(rule)
                        } catch {
                            failure = Library.message(for: error)
                        }
                    }
                    .font(YYUI.font(11.5, .medium))
                    .foregroundStyle(YYColor.danger)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(YYUI.s(16))
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(YYColor.bg)
        .task(id: PreviewKey(rule: rule)) { await refresh() }
        .task { detail = try? core.book(id: bookID) }
        .alert("没能保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .onAppear { if isNew { typing = true } }
        #if os(macOS)
        .frame(width: 440, height: 560)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func field(_ label: String, prompt: String, text: Binding<String>, mono: Bool) -> some View {
        YYField(label: label) {
            TextField(label, text: text, prompt: Text(prompt).foregroundStyle(YYColor.t3))
                .textFieldStyle(.plain)
                .font(mono ? YYUI.font(11.5, design: .monospaced) : YYUI.font(11.5))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    // MARK: Preview

    /// `.v-rd-pv`: how many places in this book, and the first one before and after.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let error = preview?.error {
                    Text(error).foregroundStyle(YYColor.danger)
                } else if let p = preview, !rule.find.isEmpty {
                    Text(p.count == 0 ? String(localized: "这本书里没有找到") : String(localized: "这本书里有 \(p.count)\(p.more ? "+" : "") 处"))
                } else {
                    Text("预览")
                }
                Spacer()
                if let first = preview?.first {
                    Text([String(localized: "第 1 处"), detail?.chapterTitle(for: first.section)].compactMap { $0 }.joined(separator: " · "))
                        .font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
            }
            .font(YYUI.font(10.5, .semibold))
            .foregroundStyle(YYColor.t1)
            if let first = preview?.first {
                line(String(localized: "改前"), before(first)).padding(.top, YYUI.s(7))
                line(String(localized: "改后"), after(first)).padding(.top, YYUI.s(7))
                if rule.speechOnly {
                    Text("屏幕上还是改前的样子，只有朗读按改后的读")
                        .font(YYUI.font(10)).foregroundStyle(YYColor.t3).padding(.top, YYUI.s(7))
                }
            } else {
                Text(rule.find.isEmpty ? String(localized: "写好要查找的字，这里马上显示改前改后") : String(localized: "没有可以预览的地方"))
                    .font(YYUI.font(10.5)).foregroundStyle(YYColor.t3).padding(.top, YYUI.s(7))
            }
        }
        .padding(.top, YYUI.s(10))
        .padding(.bottom, YYUI.s(11))
        .padding(.horizontal, YYUI.s(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(14)))
        .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(YYColor.line, lineWidth: 0.5))
    }

    private func line(_ label: String, _ text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: YYUI.s(8)) {
            Text(label).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            Text(text).font(YYUI.font(11.5, design: .serif)).foregroundStyle(YYColor.t1).lineSpacing(YYUI.s(11.5) * 0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func before(_ s: RuleSample) -> AttributedString {
        var matched = AttributedString(s.matched)
        matched.strikethroughStyle = Text.LineStyle(pattern: .solid, color: YYColor.danger)
        matched.foregroundColor = YYColor.danger
        matched.backgroundColor = YYColor.danger.opacity(0.09)
        return AttributedString(s.lead) + matched + AttributedString(s.tail)
    }

    private func after(_ s: RuleSample) -> AttributedString {
        var replaced = AttributedString(s.replaced)
        replaced.backgroundColor = YYTint.standard.accentSoft
        return AttributedString(s.lead) + replaced + AttributedString(s.tail)
    }

    /// What the preview depends on.
    private struct PreviewKey: Equatable {
        let find: String, replace: String, regex: Bool

        init(rule: ReplaceRule) {
            find = rule.find
            replace = rule.replace
            regex = rule.regex
        }
    }

    private func refresh() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let core = core, book = bookID, rule = rule
        let found = await Task.detached { try? core.previewReplaceRule(book: book, rule: rule) }.value
        guard !Task.isCancelled else { return }
        preview = found
    }

    private func save() {
        do {
            let saved = try core.saveReplaceRule(rule: rule)
            // Moved between this book and every book: the old list changes too.
            if !isNew, originalBook != saved.book { NotificationCenter.default.post(name: .replaceRulesChanged, object: originalBook) }
            finish(saved)
        } catch let CoreError.Invalid(message) {
            failure = message
        } catch {
            failure = Library.message(for: error)
        }
    }
}
