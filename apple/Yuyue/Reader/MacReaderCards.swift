import SwiftUI
import YuyueCore

// MARK: - 排版

/// The card under Aa: paper, typeface, size, line spacing and columns, whether this book keeps
/// its own, and the rest under 更多. The page changes as it is set.
struct TypesetCard: View {
    let model: ReaderModel
    @AppStorage("reader.twoColumns") private var twoColumns = true
    @State private var more = false
    /// 全部纸张, when 我的纸 are more than two rows.
    @State private var all = false
    @State private var hoverNew = false
    /// 调纸 open on this paper (a new one has no id yet).
    @State private var editing: CustomPaper?
    /// 重命名 asked for this paper.
    @State private var renaming: CustomPaper?
    @State private var newName = ""
    private let tint = YYTint.standard

    static let sizes = 12.0 ... 34.0
    /// 紧 · 适中 · 松; nil is the paper's own.
    private static let spacings: [Double?] = [1.6, nil, 2.2]

    var body: some View {
        Group {
            if let editing {
                PaperEditor(model: model, draft: editing) { saved in
                    self.editing = nil
                    if let saved { choose(saved) }
                }
                .id(editing.id)
            } else if more { moreSettings } else if all { allPapers } else { main }
        }
        // `.v-mr-aa`: 304 wide in all.
        #if os(macOS)
        .frame(width: 272)
        #endif
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, more || all || editing != nil ? 16 : 6)
        .animation(.snappy(duration: 0.2), value: more)
        .animation(.snappy(duration: 0.2), value: all)
        .animation(.snappy(duration: 0.2), value: editing == nil)
        .alert(String(localized: "重命名"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "名字"), text: $newName)
            Button(String(localized: "取消"), role: .cancel) { renaming = nil }
            Button(String(localized: "好")) {
                if let renaming { Papers.shared.rename(renaming, to: String(newName.prefix(20))) }
                renaming = nil
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            papers
            Segments(items: [(ReaderFont?.none, String(localized: "系统")), (.serif, String(localized: "宋体")), (.kai, String(localized: "楷体")), (.wenKai, String(localized: "霞鹜文楷"))],
                     selection: binding(\.font)) { font, title in
                Text(title).font(face(font)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .onChange(of: model.settings.font) { if model.settings.font == .wenKai { WenKai.shared.ensure() } }
            WenKaiStatus(chosen: model.settings.font == .wenKai)
            // `.v-mr-fs`
            HStack(spacing: 12) {
                Text("A").font(YYUI.serif(12)).foregroundStyle(YYColor.t1)
                Slider(value: binding(\.fontSize), in: Self.sizes, step: 1)
                    .controlSize(.small)
                    .accessibilityLabel(Text("字号"))
                    .accessibilityValue(Text("\(Int(model.settings.fontSize))"))
                    // A popover doesn't take the window's tint: without it the slider is system blue.
                    .tint(YYTint.standard.fill)
                Text("A").font(YYUI.serif(18)).foregroundStyle(YYColor.t1)
                Text("\(Int(model.settings.fontSize))")
                    .font(.yy(size: 12, weight: .bold))
                    .monospacedDigit()
                    .frame(minWidth: 26).frame(height: 26)
                    .background(YYColor.card, in: .rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            }
            .padding(.leading, 6).padding(.trailing, 4)
            .frame(height: 34)
            .background(YYColor.inset, in: .rect(cornerRadius: 12))
            // `.v-mr-two-seg`: 1 : 1.25.
            HStack(spacing: 8) {
                Segments(items: Self.spacings.enumerated().map { ($0.offset, [String(localized: "行距紧"), String(localized: "行距适中"), String(localized: "行距松")][$0.offset]) },
                         selection: Binding(get: { Self.spacings.firstIndex(of: model.settings.lineHeight) ?? 1 },
                                            set: { i in model.update { $0.lineHeight = Self.spacings[i] } }), small: true) { i, symbol in
                    Image(systemName: i == 1 ? "text.justify" : "line.3.horizontal")
                        .font(.yy(size: 12, weight: .medium))
                        .scaleEffect(y: i == 0 ? 0.75 : i == 2 ? 1.25 : 1)
                        .help([String(localized: "行距紧"), String(localized: "行距适中"), String(localized: "行距松")][i])
                }
                #if os(macOS)
                .frame(width: (272 - 8) / 2.25)
                #endif
                Segments(items: [(false, String(localized: "单栏")), (true, String(localized: "双栏"))], selection: Binding(get: { twoColumns }, set: {
                    twoColumns = $0
                    model.pager.prefersTwoColumns = $0
                }), small: true) { two, title in
                    Label(title, systemImage: two ? "book.pages" : "doc.plaintext").labelStyle(TightLabel())
                }
                .disabled(model.settings.mode == .scrolled)
            }
            // `.v-mr-rows`
            VStack(spacing: 0) {
                switchRow(String(localized: "只用于这本书"), Binding(get: { model.ownSettings }, set: { model.setOwnSettings($0) }))
                    .frame(height: 38)
                    .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                Button { more = true } label: {
                    HStack(spacing: 8) {
                        Text("更多").font(.yy(size: 12)).foregroundStyle(YYColor.t1)
                        Spacer()
                        HStack(spacing: 3) {
                            Text("段距、页边、翻页方式")
                            Image(systemName: "chevron.right").font(.yy(size: 9, weight: .semibold))
                        }
                        .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                    }
                    .frame(height: 38)
                    .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, -2)
        }
    }

    private var moreSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { more = false } label: {
                Label("排版", systemImage: "chevron.left")
                    .font(.yy(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint.accent)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            row(String(localized: "翻页方式")) {
                Segments(items: [(LayoutMode.paginated, String(localized: "左右翻页")), (.scrolled, String(localized: "上下滚动"))], selection: binding(\.mode)) { _, t in Text(t) }
                    .frame(width: 170)
            }
            row(String(localized: "段距")) {
                Segments(items: [(Double?.some(0), String(localized: "无")), (nil, String(localized: "适中")), (.some(1), String(localized: "宽"))], selection: binding(\.paragraphSpacing)) { _, t in Text(t) }
                    .frame(width: 170)
            }
            row(String(localized: "首行缩进")) {
                Segments(items: [(Bool?.none, String(localized: "跟书")), (.some(true), String(localized: "缩进")), (.some(false), String(localized: "不缩"))], selection: binding(\.indent)) { _, t in Text(t) }
                    .frame(width: 170)
            }
            row(String(localized: "两端对齐")) {
                Segments(items: [(Bool?.none, String(localized: "跟书")), (.some(true), String(localized: "对齐")), (.some(false), String(localized: "靠左"))], selection: binding(\.justify)) { _, t in Text(t) }
                    .frame(width: 170)
            }
            switchRow(String(localized: "中文标点挤压"), binding(\.compress))
            if model.isChinese {
                row(String(localized: "简繁")) {
                    Segments(items: [(Script?.none, String(localized: "原样")), (.some(.simplified), String(localized: "简体")), (.some(.traditional), String(localized: "繁體"))],
                             selection: Binding(get: { model.script }, set: { model.script = $0 })) { _, t in Text(t) }
                        .frame(width: 170)
                }
            }
            if model.detail?.summary.format != .pdf {
                Button {
                    model.settingsShown = false
                    model.rulesShown = true
                } label: {
                    HStack {
                        Text("替换规则").font(.yy(size: 12.5)).foregroundStyle(YYColor.t1)
                        Spacer()
                        Text("去广告、改读音").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
                        Image(systemName: "chevron.right").font(.yy(size: 10, weight: .semibold)).foregroundStyle(YYColor.t3)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if model.detail?.summary.format == .txt {
                Button {
                    model.settingsShown = false
                    model.txtShown = true
                } label: {
                    HStack {
                        Text("编码和目录").font(.yy(size: 12.5)).foregroundStyle(YYColor.t1)
                        Spacer()
                        Text("乱码、章节不对").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
                        Image(systemName: "chevron.right").font(.yy(size: 10, weight: .semibold)).foregroundStyle(YYColor.t3)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Text("页边随窗口宽窄自动留，一行不超过三十来个字。")
                .font(.yy(size: 11))
                .foregroundStyle(YYColor.t3)
        }
    }

    private func switchRow(_ title: String, _ on: Binding<Bool>) -> some View {
        row(title) {
            Toggle(title, isOn: on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(YYTint.standard.fill)
        }
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Text(title).font(.yy(size: 12.5)).foregroundStyle(YYColor.t1)
            Spacer()
            content()
        }
    }

    private func face(_ font: ReaderFont?) -> SwiftUI.Font {
        switch font {
        case .serif: .custom("Songti SC", size: 12)
        case .kai: .custom("Kaiti SC", size: 12.5)
        case .wenKai: WenKai.shared.installed ? .custom("LXGW WenKai Lite", size: 12.5) : .custom("Kaiti SC", size: 12.5)
        case .sans: .yy(size: 12, weight: .medium)
        default: .yy(size: 12)
        }
    }

    #if os(iOS)
    /// The phone keeps the strip: the presets, then 我的纸, a finger swipes along them; ＋ stays
    /// pinned at the right so making one is always in sight.
    private var papers: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(YYPaper.all) { paper in
                            PaperTile(paper: paper, texture: paper.hasNoiseTexture ? .grain : .none, name: paper.name, selected: model.settings.paperChoice == paper.id) {
                                if let id = Paper(id: paper.id) { model.update { $0.paper = id; $0.customPaper = nil } }
                            }
                            .id(paper.id)
                        }
                        ForEach(Papers.shared.list, id: \.id) { mine in
                            PaperTile(paper: YYPaper(custom: mine), texture: mine.texture, name: mine.name, selected: model.settings.paperChoice == mine.id) { choose(mine) }
                                .id(mine.id)
                                // 长按 / 右键: the prototype's menu card, 删除 in red in a group of its own.
                                .contextMenu {
                                    Button(String(localized: "调整颜色"), systemImage: "paintpalette") { editing = mine }
                                    Button(String(localized: "重命名"), systemImage: "pencil") { newName = mine.name; renaming = mine }
                                    Button(String(localized: "复制一张"), systemImage: "plus.square.on.square") { duplicate(mine) }
                                    Divider()
                                    Button(String(localized: "删除"), systemImage: "trash", role: .destructive) { delete(mine) }
                                }
                        }
                    }
                    .padding(.leading, 16).padding(.trailing, 12)
                }
                .scrollIndicators(.never)
                // The paper the page is on stays in sight, a new one too.
                .onAppear { proxy.scrollTo(model.settings.paperChoice, anchor: .center) }
                .onChange(of: model.settings.paperChoice) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                }
            }
            Button { editing = newPaper() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.yy(size: 15, weight: .medium))
                        .foregroundStyle(YYColor.t2)
                        .frame(width: 46, height: 38)
                        .background(YYColor.inset, in: .rect(cornerRadius: 10))
                        .padding(2)
                    Text("新建").font(.yy(size: 10.5)).foregroundStyle(YYColor.t2).lineLimit(1)
                }
                .padding(.leading, 6)
                .overlay(alignment: .leading) { Rectangle().fill(YYColor.line).frame(width: 0.5).padding(.vertical, 4) }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text("自己调一张纸"))
            .accessibilityLabel(Text("自己调一张纸"))
        }
        .padding(.leading, -16)
    }
    #else
    /// 方案二 (docs/design/纸张选择.html): the five presets fill a row; 我的纸 go under them five to
    /// a row, ＋ after the last. Two rows at most, so the card keeps its height: past that the last
    /// cell is 全部, a page of every paper. The one on the page always shows, standing in for the
    /// last of the two rows if it's further on.
    private var papers: some View {
        let mine = Papers.shared.list
        return VStack(alignment: .leading, spacing: 10) {
            paperGrid { ForEach(YYPaper.all) { presetTile($0) } }
            if mine.isEmpty {
                // The whole row is the button: the words alone were 13 high and easy to miss.
                Button { editing = newPaper() } label: {
                    HStack {
                        Text("我的纸").font(.yy(size: 10.5, weight: .semibold)).foregroundStyle(YYColor.t2)
                        Spacer()
                        Label("自己调一张", systemImage: "plus").labelStyle(TightLabel())
                            .font(.yy(size: 10.5)).foregroundStyle(YYColor.t2)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(hoverNew ? YYColor.inset : .clear, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hoverNew = $0 }
                .help(Text("自己调一张纸"))
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("我的纸").font(.yy(size: 10.5, weight: .semibold)).foregroundStyle(YYColor.t2)
                    Text("\(mine.count) 张").font(.yy(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3)
                    Spacer()
                    if mine.count > Self.shown {
                        Button { all = true } label: {
                            HStack(spacing: 2) {
                                Text("全部")
                                Image(systemName: "chevron.right").font(.yy(size: 8.5, weight: .semibold))
                            }
                            .font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, -4)
                paperGrid {
                    ForEach(shownMine(mine), id: \.id) { mineTile($0) }
                    addTile
                    if mine.count > Self.shown { allTile(mine.count) }
                }
            }
        }
    }

    #endif

    /// Two rows of five: eight papers, ＋ and 全部. Nine papers and ＋ fit without 全部.
    private static let shown = 9

    private func shownMine(_ mine: [CustomPaper]) -> [CustomPaper] {
        guard mine.count > Self.shown else { return mine }
        var head = Array(mine.prefix(Self.shown - 1))
        if let on = mine.firstIndex(where: { $0.id == model.settings.paperChoice }), on >= head.count { head[head.count - 1] = mine[on] }
        return head
    }

    /// 全部纸张: the same kind of page as 更多, every paper, scrolling when they're many.
    private var allPapers: some View {
        let mine = Papers.shared.list
        return VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Text("全部纸张").font(.yy(size: 12.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                HStack {
                    Button { all = false } label: {
                        Label("排版", systemImage: "chevron.left")
                            .font(.yy(size: 12.5, weight: .semibold))
                            .foregroundStyle(tint.accent)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        groupTitle(String(localized: "自带"), nil)
                        paperGrid { ForEach(YYPaper.all) { presetTile($0) } }
                        groupTitle(String(localized: "我的纸"), String(localized: "\(mine.count) 张"))
                        paperGrid {
                            ForEach(mine, id: \.id) { mineTile($0) }
                            addTile
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { proxy.scrollTo(model.settings.paperChoice, anchor: .center) }
            }
            Text("右键一张自己调的纸：调整颜色、重命名、复制、删除。")
                .font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
        }
    }

    private func groupTitle(_ title: String, _ count: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.yy(size: 10.5, weight: .semibold)).foregroundStyle(YYColor.t2)
            if let count { Text(count).font(.yy(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3) }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, -4)
    }

    /// `.v-mr-papers`: five columns.
    private func paperGrid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), alignment: .center, spacing: 10, content: content)
    }

    private func presetTile(_ paper: YYPaper) -> some View {
        PaperTile(paper: paper, texture: paper.hasNoiseTexture ? .grain : .none, name: paper.name, selected: model.settings.paperChoice == paper.id) {
            if let id = Paper(id: paper.id) { model.update { $0.paper = id; $0.customPaper = nil } }
        }
        .id(paper.id)
    }

    private func mineTile(_ mine: CustomPaper) -> some View {
        PaperTile(paper: YYPaper(custom: mine), texture: mine.texture, name: mine.name, selected: model.settings.paperChoice == mine.id) { choose(mine) }
            .id(mine.id)
            // 长按 / 右键: the prototype's menu card, 删除 in red in a group of its own.
            .contextMenu {
                Button(String(localized: "调整颜色"), systemImage: "paintpalette") { editing = mine }
                Button(String(localized: "重命名"), systemImage: "pencil") { newName = mine.name; renaming = mine }
                Button(String(localized: "复制一张"), systemImage: "plus.square.on.square") { duplicate(mine) }
                Divider()
                Button(String(localized: "删除"), systemImage: "trash", role: .destructive) { delete(mine) }
            }
    }

    private var addTile: some View {
        cellButton(String(localized: "新建"), help: String(localized: "自己调一张纸")) { editing = newPaper() } face: {
            Image(systemName: "plus").font(.yy(size: 15, weight: .medium)).foregroundStyle(YYColor.t2)
        }
    }

    private func allTile(_ count: Int) -> some View {
        cellButton(String(localized: "全部"), help: String(localized: "全部纸张")) { all = true } face: {
            Text("\(count)").font(.yy(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(YYColor.t1)
        }
    }

    /// A cell the size of a paper, on the inset grey: ＋ 新建 and 全部.
    private func cellButton(_ title: String, help: String, action: @escaping () -> Void, @ViewBuilder face: () -> some View) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                face()
                    .frame(width: 46, height: 38)
                    .background(YYColor.inset, in: .rect(cornerRadius: 10))
                    .padding(2)
                Text(title).font(.yy(size: 10.5)).foregroundStyle(YYColor.t2).lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }

    private func choose(_ mine: CustomPaper) {
        let preset = paperColors(paper: mine).preset
        model.update { $0.customPaper = mine.id; $0.paper = preset }
    }

    /// ＋ starts from the paper the page is on: a copy of 我的纸, or the made colour closest to the
    /// preset. No name: the core gives it one on 完成.
    private func newPaper() -> CustomPaper {
        if let mine = Papers.shared.paper(model.settings.customPaper) {
            return CustomPaper(id: "", name: "", bg: mine.bg, ink: mine.ink, layout: mine.layout, texture: mine.texture)
        }
        let preset = model.settings.paper
        let night = preset == .dark || preset == .kamiNight
        let made = paperPalette(night: night).swatches
        let start = night ? made[0] : made[preset == .kami ? 1 : preset == .eink ? 5 : 0]
        return CustomPaper(id: "", name: "", bg: start.color, ink: nil,
                           layout: preset == .plain || preset == .dark ? .plain : .kami, texture: preset == .eink ? .grain : .none)
    }

    /// 复制一张: straight onto the shelf of papers, named 豆沙绿 2 and so on, and on the page.
    private func duplicate(_ mine: CustomPaper) {
        var copy = mine
        copy.id = ""
        let base = mine.name.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
        let taken = Set(Papers.shared.list.map(\.name))
        copy.name = (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
        if let saved = try? Papers.shared.save(copy) { choose(saved) }
    }

    /// 删除, with 撤销 for a few seconds.
    private func delete(_ mine: CustomPaper) {
        let wasOn = model.settings.customPaper == mine.id
        if wasOn { model.update { $0.customPaper = nil } }
        Papers.shared.delete(mine.id)
        model.show(Library.Toast(icon: "trash", danger: true, title: String(localized: "已删除“\(mine.name)”"), detail: "", undo: { [model] in
            Papers.shared.restore(mine.id)
            if wasOn {
                let preset = paperColors(paper: mine).preset
                model.update { $0.customPaper = mine.id; $0.paper = preset }
            }
        }))
    }

    private func binding<T>(_ key: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }
}

/// A row of choices on an inset track, the chosen one lifted on a white chip. `small` is
/// `.v-ms-ha .v-seg.sm`, the one beside 导出 in a shelf header.
struct Segments<T: Hashable, Label: View>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var small = false
    @ViewBuilder let label: (T, String) -> Label

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title in
                let on = selection == value
                Button { selection = value } label: {
                    label(value, title)
                        .font(.yy(size: small ? 11 : 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
                        .frame(maxWidth: .infinity)
                        .frame(height: small ? 24 : 30)
                        .background(on ? YYColor.card : .clear, in: .rect(cornerRadius: small ? 7 : 9))
                        .shadow(color: .black.opacity(on ? 0.07 : 0), radius: 1.5, y: 0.5)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(YYColor.inset, in: .rect(cornerRadius: small ? 10 : 12))
    }
}

// MARK: - 听书

/// The card over the reading capsule: the voice and 试听, speed (the pitch stays), the sleep
/// timer, and 逐句翻译 · 单句循环 · 只听.
struct ListenCard: View {
    let player: Player?
    @Binding var rate: Float
    /// Minutes of listening left in the chapter (or the PDF's page) at this speed.
    let minutesLeft: Int
    /// 只听, for a book; a PDF has no text of its own to hide.
    var listenOnly: Binding<Bool>?
    /// What a section is here: 章, or 页 in a PDF.
    var unit = String(localized: "章")
    private let tint = YYTint.standard

    init(model: ReaderModel) {
        player = model.player
        _rate = Binding(get: { model.rate }, set: { model.rate = $0 })
        minutesLeft = Self.minutesLeft(model)
        listenOnly = Binding(get: { model.listenOnly }, set: { model.listenOnly = $0 })
    }

    init(player: Player?, rate: Binding<Float>, minutesLeft: Int, unit: String) {
        self.player = player
        _rate = rate
        self.minutesLeft = minutesLeft
        self.unit = unit
    }

    /// The speed track's marks.
    private static let rates: [Float] = [0.8, 1.0, 1.2, 1.5, 2.0]

    var body: some View {
        // `.v-mr-lp`
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            HStack(spacing: 4) {
                Text("听书").font(.yy(size: 13.5, weight: .bold)).foregroundStyle(YYColor.t1)
                Spacer()
                Key(String(localized: "空格"))
                Text("暂停").padding(.trailing, 6)
                Key("⌘[")
                Key("⌘]")
                Text("上一句 / 下一句")
            }
            .font(.yy(size: 10.5))
            .foregroundStyle(YYColor.t3)
            #endif
            if let player {
                if player.recording != nil { narrator(player) }
                voice(player)
                speed(player)
                sleep(player)
                HStack(spacing: 6) {
                    Tile(icon: "translate", title: String(localized: "逐句翻译"), detail: String(localized: "以后"), on: false) {}
                        .disabled(true)
                        .help("读一句外文，接着读一句译文（还没做好）")
                    Tile(icon: "repeat.1", title: String(localized: "单句循环"), detail: player.loop ? String(localized: "开") : String(localized: "关"), on: player.loop) {
                        player.loop.toggle()
                    }
                    if let listenOnly {
                        Tile(icon: "eye.slash", title: String(localized: "只听"), detail: String(localized: "隐藏原文"), on: listenOnly.wrappedValue) {
                            listenOnly.wrappedValue.toggle()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        #if os(macOS)
        .frame(width: 460)
        #endif
    }

    private func voice(_ player: Player) -> some View {
        let language = player.language
        let current = player.currentVoice(for: language)
        // `.v-mr-lv`
        return HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.yy(size: 14, weight: .medium))
                .foregroundStyle(YYColor.t1)
                .frame(width: 32, height: 32)
                .background(YYColor.card, in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(YYColor.line, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(current.map(Voices.title) ?? String(localized: "没有能读的声音"))
                    .font(.yy(size: 12.5, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                Text([languageName(language), current?.isOffline == false ? String(localized: "云端 · 读过的存在本机") : String(localized: "离线"), Self.here].joined(separator: " · "))
                    .font(.yy(size: 10.5))
                    .foregroundStyle(YYColor.t2)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let current {
                Button { player.preview(current, text: sample(language)) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.yy(size: 8.5))
                        Text("试听")
                    }
                        .font(.yy(size: 11, weight: .semibold))
                        .foregroundStyle(YYColor.t1)
                        .padding(.leading, 8).padding(.trailing, 10)
                        .frame(height: 26)
                        .background(YYColor.card, in: .capsule)
                        .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
            Menu {
                ForEach(Voices.all(for: language), id: \.id) { voice in
                    Button {
                        player.choose(voice, for: language)
                    } label: {
                        if voice.id == current?.id {
                            Label(Voices.title(voice), systemImage: "checkmark")
                        } else {
                            Text(Voices.title(voice))
                        }
                    }
                }
                #if os(macOS)
                Divider()
                Button("下载更好的声音…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                }
                #else
                Divider()
                Text("更好的声音：设置 › 辅助功能 › 朗读内容 › 声音")
                #endif
            } label: {
                HStack(spacing: 1) {
                    Text("换声音")
                    Image(systemName: "chevron.right").font(.yy(size: 9, weight: .semibold))
                }
                .font(.yy(size: 11))
                .foregroundStyle(YYColor.t2)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .padding(.trailing, 2)
        }
        .padding(.leading, 9).padding(.trailing, 8).padding(.vertical, 9)
        .background(YYColor.inset, in: .rect(cornerRadius: 14))
    }

    /// 原声: a recording is laid against this book; off reads it in the voice below instead.
    private func narrator(_ player: Player) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2")
                .font(.yy(size: 15, weight: .medium))
                .foregroundStyle(player.usesRecording ? tint.accent : YYColor.t1)
                .frame(width: 36, height: 36)
                .background(player.usesRecording ? tint.accentSoft : YYColor.card, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("原声").font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(player.usesRecording ? String(localized: "读录音；录音里没有的句子，用下面的声音补上") : String(localized: "关着，用下面的声音读"))
                    .font(.yy(size: 10.5))
                    .foregroundStyle(YYColor.t2)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            YYSwitch(isOn: Binding(get: { player.usesRecording }, set: { player.usesRecording = $0 }), label: String(localized: "原声"))
        }
        .padding(10)
        .background(YYColor.inset, in: .rect(cornerRadius: 14))
    }

    private func speed(_ player: Player) -> some View {
        // `.v-mr-ls`
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("速度").font(.yy(size: 11.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(rateText(rate) + "×").font(.yy(size: 17, weight: .bold)).foregroundStyle(YYColor.t1)
                Text("不变调")
                    .font(.yy(size: 10, weight: .medium))
                    .foregroundStyle(YYColor.t2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(YYColor.inset, in: .rect(cornerRadius: 5))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Spacer()
                Text("这一\(unit)按这个速度还要 \(minutesLeft) 分钟")
                    .font(.yy(size: 10.5))
                    .foregroundStyle(YYColor.t3)
            }
            .monospacedDigit()
            .padding(.horizontal, 2)
            VStack(spacing: 2) {
            Slider(value: Binding(get: { Double(rate) }, set: { rate = Float(($0 * 10).rounded() / 10) }), in: 0.8 ... 2.0)
                .controlSize(.small)
                .accessibilityLabel(Text("速度"))
                .accessibilityValue(Text(String(format: "%.1f×", rate)))
                .tint(YYTint.standard.fill)
            GeometryReader { g in
                ForEach(Self.rates, id: \.self) { mark in
                    Text(rateText(mark))
                        .font(.yy(size: 10, weight: abs(rate - mark) < 0.05 ? .bold : .regular))
                        .foregroundStyle(abs(rate - mark) < 0.05 ? YYColor.t1 : YYColor.t3)
                        .fixedSize()
                        .position(x: 8 + (g.size.width - 16) * CGFloat((mark - 0.8) / 1.2), y: 7)
                }
            }
            .frame(height: 14)
            }
            .padding(.horizontal, 9).padding(.top, 2)
        }
    }

    private func sleep(_ player: Player) -> some View {
        // `.v-mr-lz` / `.v-mr-pseg`
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("睡眠定时").font(.yy(size: 11.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Spacer()
                Text("停的时候自动加一个书签").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            .padding(.horizontal, 2)
            HStack(spacing: 2) {
                sleepChoice(player, String(localized: "关"), nil, .off)
                sleepChoice(player, String(localized: "本句读完"), nil, .sentence)
                sleepChoice(player, unit == String(localized: "章") ? String(localized: "本章结束") : String(localized: "本\(unit)读完"), String(localized: "约 \(minutesLeft) 分钟"), .chapter)
                ForEach([15, 30, 60], id: \.self) { m in
                    let left = minutesLeft(player, of: m)
                    sleepChoice(player, String(localized: "\(m) 分钟"), left.map { String(localized: "还剩 \($0) 分") }, .until(Date().addingTimeInterval(Double(m) * 60), minutes: m))
                }
            }
            .padding(3)
            .background(YYColor.inset, in: .rect(cornerRadius: 12))
        }
    }

    private func minutesLeft(_ player: Player, of minutes: Int) -> Int? {
        guard case .until(let date, let m) = player.sleep, m == minutes else { return nil }
        return max(1, Int((date.timeIntervalSinceNow / 60).rounded(.up)))
    }

    private func sleepChoice(_ player: Player, _ title: String, _ detail: String?, _ value: Player.Sleep) -> some View {
        let on: Bool = switch (player.sleep, value) {
        case (.until(_, let a), .until(_, let b)): a == b
        default: player.sleep == value
        }
        return Button { player.sleep = on ? .off : value } label: {
            VStack(spacing: 1) {
                Text(title).font(.yy(size: 11, weight: on ? .bold : .regular))
                if on, let detail { Text(detail).font(.yy(size: 10)).foregroundStyle(YYColor.t2) }
            }
            .foregroundStyle(YYColor.t1)
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(on ? YYColor.card : .clear, in: .rect(cornerRadius: 9))
            .shadow(color: .black.opacity(on ? 0.07 : 0), radius: 1.5, y: 0.5)
            .contentShape(.rect)
        }
        .accessibilityAddTraits(on ? .isSelected : [])
        .buttonStyle(.plain)
    }

    /// Minutes of listening left in the chapter at this speed (about 220 characters a minute at 1×).
    private static func minutesLeft(_ model: ReaderModel) -> Int {
        guard let section = model.section, let s = model.detail?.sections[safe: Int(section)] else { return 0 }
        let n = max(1, Int(s.sentences))
        let left = Double(s.units) * Double(n - model.sentence) / Double(n)
        return max(1, Int((left / 220 / Double(max(0.5, model.rate))).rounded()))
    }

    #if os(macOS)
    private static let here = String(localized: "在这台 Mac 上合成")
    #else
    private static let here = String(localized: "在这台设备上合成")
    #endif

    private func rateText(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(1)))
    }

    private func languageName(_ tag: String) -> String {
        let t = tag.lowercased()
        if t.hasPrefix("zh") { return t.contains("hant") || t.contains("tw") || t.contains("hk") ? String(localized: "繁体中文") : String(localized: "中文") }
        return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: tag) ?? tag
    }

    private func sample(_ tag: String) -> String {
        if tag.lowercased().hasPrefix("zh") { return "你好，我来给你读这本书。" }
        return "Hello, I'll read this book to you."
    }
}

/// A key cap: 空格 · ⌘[.
private struct Key: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.yy(size: 10, weight: .semibold))
            .foregroundStyle(YYColor.t1)
            .padding(.horizontal, 4)
            .frame(minWidth: 18).frame(height: 17)
            .background(YYColor.inset, in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(YYColor.line, lineWidth: 0.5))
    }
}

private struct Tile: View {
    let icon: String
    let title: String
    let detail: String
    let on: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    private let tint = YYTint.standard

    var body: some View {
        Button(action: action) {
            // `.v-mr-tiles`
            HStack(spacing: 9) {
                Image(systemName: icon).font(.yy(size: 14, weight: .medium)).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.yy(size: 11.5, weight: .semibold))
                    Text(detail).font(.yy(size: 10)).foregroundStyle(on ? tint.accent : YYColor.t2)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? tint.accent : YYColor.t1)
            .opacity(enabled ? 1 : 0.45)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(on ? tint.accentSoft : YYColor.inset, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#if os(macOS)
// MARK: - 书伴

/// ✦ 书伴 (prototype f94): ask about the book without leaving the page. Answers point back at the
/// sentences they lean on; a click on one turns the page there and marks it 出处.
struct CompanionPanel: View {
    @Bindable var model: ReaderModel
    @State private var draft = ""
    @FocusState private var typing: Bool
    @Environment(\.openSettings) private var openSettings
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    private var companion: BookCompanion { model.companion }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            mode.padding(.top, 12)
            Rectangle().fill(YYColor.line).frame(height: 1).padding(.top, 14)
            chat
            if let quote = model.companionQuote { quoted(quote) }
            suggestions
            input.padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .onDisappear { model.pager.setSource(nil) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.yy(size: 12, weight: .semibold))
                .foregroundStyle(tint.accent)
                .frame(width: 24, height: 24)
                .background(tint.accentSoft, in: .rect(cornerRadius: 7))
            Text("书伴").font(.yy(size: 14, weight: .bold)).foregroundStyle(YYColor.t1)
            Text(model.detail?.summary.title ?? "").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
            Spacer()
            Menu {
                Button("清空这次的对话") { companion.clear() }.disabled(companion.turns.isEmpty)
                Button("书伴设置…") { openCompanionSettings() }
            } label: {
                Image(systemName: "ellipsis").font(.yy(size: 12, weight: .semibold))
                    .foregroundStyle(YYColor.t2)
                    .frame(width: 26, height: 26)
                    .background(YYColor.inset, in: .circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var mode: some View {
        VStack(alignment: .leading, spacing: 6) {
            YYSegments(items: [(BookCompanion.Scope.read, String(localized: "只用读过的部分")), (.whole, String(localized: "问全书"))],
                       selection: Bindable(companion).scope, small: true)
            Text(companion.scope == .read ? readUpTo + String(localized: "，后面的事它不会说") : String(localized: "会用到整本书，可能提前知道结尾"))
                .font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).padding(.horizontal, 2)
        }
    }

    private var readUpTo: String {
        if let page = model.bookPage { return String(localized: "你读到第 \(page) 页") }
        return String(localized: "你读到这里")
    }

    // MARK: Turns

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if companion.turns.isEmpty { welcome }
                    ForEach(companion.turns) { turn in
                        VStack(alignment: .leading, spacing: 10) {
                            bubble(turn.question)
                            reply(turn)
                        }
                        .id(turn.id)
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: companion.turns.map(\.id)) {
                if let last = companion.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: companion.busy) {
                if let last = companion.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var welcome: some View {
        let config = CompanionConfig.current
        VStack(alignment: .leading, spacing: 8) {
            Text("读到哪儿问到哪儿").font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
            Text("可以问人物关系、这句是什么意思、前面发生了什么。回答标着出处，点一下就翻到那句。")
                .font(.yy(size: 12)).foregroundStyle(YYColor.t2).lineSpacing(3)
            if !config.isReady {
                Text(config.provider == .apple ? Companion.appleAvailability ?? "" : String(localized: "还没填好 \(config.provider.title) 的 Key"))
                    .font(.yy(size: 11.5)).foregroundStyle(YYColor.t3).lineSpacing(3)
                Button("去设置 · 书伴") { openCompanionSettings() }
                    .buttonStyle(YYButtonStyle(kind: .soft, size: .small)).padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.inset, in: .rect(cornerRadius: 14))
    }

    private func bubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.yy(size: 12))
                .lineSpacing(3)
                .foregroundStyle(tint.onBlack)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(tint.black, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func reply(_ turn: BookCompanion.Turn) -> some View {
        if let answer = turn.answer {
            VStack(alignment: .leading, spacing: 6) {
                if answer.notYet {
                    Text("\(readUpTo)，这件事可能要到后面才写。切到“问全书”就能回答，不过会提前知道后面的事。")
                        .font(.yy(size: 12.5)).lineSpacing(9).foregroundStyle(YYColor.t1)
                    Button { companion.ask(turn.question, quote: turn.quote, scope: .whole) } label: {
                        HStack(spacing: 8) {
                            Text("用全书回答").font(.yy(size: 11.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                            Label("可能剧透", systemImage: "exclamationmark.triangle")
                                .font(.yy(size: 10, weight: .semibold)).foregroundStyle(YYColor.warn)
                        }
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(YYColor.card, in: .capsule)
                        .overlay(Capsule().strokeBorder(YYColor.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(companion.busy)
                    .padding(.top, 3)
                } else {
                    Text(cited(answer))
                        .font(.yy(size: 12.5))
                        .lineSpacing(9)
                        .foregroundStyle(YYColor.t1)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if let n = Int(url.host() ?? ""), let source = answer.sources[n] { companion.show(source) }
                            return .handled
                        })
                    HStack(spacing: 4) {
                        Image(systemName: turn.scope == .whole ? "book" : "sparkle").font(.yy(size: 9))
                        Text(turn.scope == .whole ? answer.label + String(localized: " · 用了全书") : answer.label)
                    }
                    .font(.yy(size: 10)).foregroundStyle(YYColor.t3)
                }
            }
        } else if let failed = turn.failed {
            Label(failed, systemImage: "exclamationmark.circle")
                .font(.yy(size: 11.5)).foregroundStyle(YYColor.danger)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在翻书…").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
            }
        }
    }

    /// The answer with each [n] turned into a little 第 N 页 tag that goes there.
    private func cited(_ answer: BookCompanion.Answer) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(answer.text)
        while let m = rest.firstMatch(of: /\s?\[(\d+)\]/) {
            out += AttributedString(String(rest[..<m.range.lowerBound]))
            if let n = Int(m.1), let source = answer.sources[n] {
                let place = source.page.map { String(localized: "第 \($0) 页") } ?? String(localized: "出处")
                // Kept on one line.
                let label = " " + place + (source.later == true ? String(localized: " · 没读到") : "") + " "
                var tag = AttributedString(label.replacingOccurrences(of: " ", with: "\u{00A0}"))
                tag.font = .yy(size: 10, weight: .semibold)
                if source.later == true, companion.shown != source {
                    // 空心: from the part not read yet.
                    tag.foregroundColor = tint.accent
                    tag.underlineStyle = Text.LineStyle(pattern: .dash, color: tint.accent)
                } else {
                    tag.foregroundColor = companion.shown == source ? YYColor.card : tint.accent
                    tag.backgroundColor = companion.shown == source ? tint.accent : tint.accentSoft
                }
                tag.link = URL(string: "yuyue-cite://\(n)")
                out += AttributedString(" ") + tag
            }
            rest = rest[m.range.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }

    // MARK: Asking

    private func quoted(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(quote)
                .font(YYUI.serif(11.5))
                .foregroundStyle(YYColor.t2)
                .lineLimit(2)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
            Spacer(minLength: 0)
            Button { model.companionQuote = nil } label: {
                Image(systemName: "xmark").font(.yy(size: 9, weight: .bold)).foregroundStyle(YYColor.t3)
            }
            .buttonStyle(.plain)
            .help("不带这句")
        }
        .padding(.bottom, 8)
    }

    private var suggestions: some View {
        let list = model.companionQuote != nil ? [String(localized: "这句是什么意思？"), String(localized: "为什么这么写？")]
            : companion.turns.last?.answer?.next ?? [String(localized: "前面发生了什么？"), String(localized: "这一章讲了什么？")]
        return HStack(spacing: 6) {
            ForEach(list, id: \.self) { s in
                Button { send(s) } label: {
                    Text(s)
                        .font(.yy(size: 11)).foregroundStyle(YYColor.t2)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(YYColor.card, in: .capsule)
                        .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(companion.busy)
            }
        }
    }

    private var input: some View {
        HStack(spacing: 6) {
            TextField("", text: $draft, prompt: Text(companion.turns.isEmpty ? String(localized: "问这本书…") : String(localized: "继续问…")), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.yy(size: 12))
                .lineLimit(1 ... 4)
                .focused($typing)
                .onSubmit { send(draft) }
            Text("↩").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            Button { send(draft) } label: {
                Image(systemName: "arrow.up").font(.yy(size: 12, weight: .bold))
                    .foregroundStyle(tint.onBlack)
                    .frame(width: 30, height: 30)
                    .background(tint.black, in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || companion.busy)
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(model.paperTokens.bg, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(YYColor.line, lineWidth: 0.5))
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !companion.busy else { return }
        companion.ask(q, quote: model.companionQuote)
        draft = ""
        model.companionQuote = nil
    }

    private func openCompanionSettings() {
        UserDefaults.standard.set(SettingsPage.companion.rawValue, forKey: "settings.page")
        openSettings()
    }
}

#endif

// MARK: - 只听

/// The page covered while 只听 is on: just where the voice is.
struct ListenOnlyCover: View {
    let model: ReaderModel

    var body: some View {
        let paper = model.paperTokens
        VStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.yy(size: 34, weight: .light))
                .foregroundStyle(paper.ink2)
            Text(model.chapterTitle ?? model.detail?.summary.title ?? "")
                .font(YYUI.serif(17, .semibold))
                .foregroundStyle(paper.ink)
            Text("只听 · 原文藏起来了")
                .font(.yy(size: 12))
                .foregroundStyle(paper.ink2)
            Button("显示原文") { model.listenOnly = false }
                .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper.bg)
    }
}
