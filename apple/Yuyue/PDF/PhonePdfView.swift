#if os(iOS)
import PDFKit
import SwiftUI
import YuyueCore

/// A PDF on the phone: the pages edge to edge, scrolled down or turned like a book; a tap brings
/// the bars — 关闭, the title, 目录, 显示, and 听 — and the page under them. Selected words get
/// a bar to mark them up; a tap on a highlight offers what can be done with it.
struct PhonePdfView: View {
    @Bindable var model: PdfModel
    @Environment(\.dismiss) private var dismiss
    @State private var chrome = true
    @State private var tocShown = false
    @State private var selection: PDFSelection?
    @State private var tappedMark: Mark?
    @State private var clear = 0

    var body: some View {
        PdfPhonePages(model: model, clear: clear, selected: { selection = $0 }, tappedMark: { tappedMark = $0 }) { chrome.toggle() }
            .ignoresSafeArea()
            .background((model.night ? Color(white: 0.12) : PdfDesk.color).ignoresSafeArea())
            .overlay {
                if chrome { bars.transition(.opacity) }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if let selection { selectionBar(selection) }
                }
                .padding(.bottom, chrome ? 64 : 24)
            }
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    UndoToast(toast: toast) { model.undoToast() }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .transition(UndoToast.transition)
                        .id(toast.id)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.3), value: model.toast?.id)
            .confirmationDialog(tappedMark.map { "“\($0.text.prefix(24))”" } ?? "", isPresented: Binding(get: { tappedMark != nil }, set: { if !$0 { tappedMark = nil } }), titleVisibility: .visible) {
                if let mark = tappedMark {
                    Button(mark.note == nil ? String(localized: "写想法") : String(localized: "改想法")) { model.writing = mark }
                    ForEach(MarkStyle.colours + MarkStyle.lines, id: \.self) { style in
                        if style != mark.style { Button("换成\(style.name)") { model.setStyle(style, of: mark) } }
                    }
                    Button("复制") { model.copy(mark.text) }
                    Button("删除划线", role: .destructive) { model.deleteMark(mark) }
                }
            }
            .sheet(item: $model.writing) { mark in
                PhoneThoughtSheet(mark: mark) { text in
                    model.setNote(text, of: mark)
                    model.writing = nil
                } cancel: {
                    model.writing = nil
                }
            }
            .animation(.easeOut(duration: 0.2), value: chrome)
            .statusBarHidden(!chrome)
            .persistentSystemOverlays(chrome ? .automatic : .hidden)
            .preferredColorScheme(model.night ? .dark : nil)
            .sheet(isPresented: $tocShown) {
                PhonePdfToc(model: model) { tocShown = false }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .bookFailure($model.failure, opened: model.opened)
    }

    private var bars: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .frame(width: 44, height: 44)
                Text(model.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                Button("目录", systemImage: "list.bullet") { tocShown = true }
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)
            .background(.bar)

            Spacer(minLength: 0)

            HStack {
                Text(model.chapter?.title ?? "").lineLimit(1)
                Spacer(minLength: 12)
                Text(pageText).monospacedDigit()
                if model.player != nil {
                    Button(model.isPlaying ? String(localized: "暂停") : String(localized: "朗读"), systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                        .frame(width: 44, height: 44)
                    Menu {
                        Picker("速度", selection: $model.rate) {
                            ForEach([0.8, 1.0, 1.2, 1.5, 2.0] as [Float], id: \.self) { r in
                                Text(r.formatted(.number.precision(.fractionLength(1))) + "×").tag(r)
                            }
                        }
                        if model.player?.spot != nil {
                            Button("下一句", systemImage: "forward.fill") { model.player?.skip(forward: true) }
                            Button("上一句", systemImage: "backward.fill") { model.player?.skip(forward: false) }
                            Button("停止", systemImage: "stop.fill") { model.player?.stop() }
                        }
                    } label: {
                        Image(systemName: "headphones").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("朗读"))
                }
                Menu {
                    Picker("显示", selection: $model.layout) {
                        ForEach(PdfModel.Layout.allCases, id: \.self) { l in
                            Label(l.name, systemImage: l.symbol).tag(l)
                        }
                    }
                    Toggle("夜间", systemImage: "moon", isOn: $model.night)
                } label: {
                    Image(systemName: "textformat.size").frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("版式和夜间"))
            }
            .font(.caption)
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .background(.bar)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
    }

    private var pageText: String {
        if let r = model.reading { return String(localized: "第 \(model.label(of: r.page)) 页 · \(r.sentence + 1)/\(r.count) 句") }
        return String(localized: "第 \(model.label(of: model.page)) / \(model.pageCount) 页")
    }

    /// What can be done with the selected words.
    private func selectionBar(_ selection: PDFSelection) -> some View {
        HStack(spacing: 0) {
            barButton(String(localized: "划线"), "highlighter") { model.mark(selection) }
            barButton(String(localized: "写想法"), "pencil") { model.writeNote(on: selection) }
            barButton(String(localized: "从这读"), "play") {
                if let at = model.sentence(at: selection) { model.read(from: at.page, sentence: at.sentence) }
            }
            barButton(String(localized: "复制"), "doc.on.doc") {
                if let span = model.span(of: selection) { model.copy(span.text) }
            }
        }
        .padding(.horizontal, 6)
        .modifier(CapsuleGlass())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func barButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            selection = nil
            clear += 1
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.yy(size: 16))
                Text(title).font(.caption2)
            }
            .frame(width: 66, height: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct PdfPhonePages: UIViewRepresentable {
    let model: PdfModel
    let clear: Int
    let selected: (PDFSelection?) -> Void
    let tappedMark: (Mark) -> Void
    let tapped: () -> Void

    final class Coordinator: NSObject {
        let painter = MarkPainter()
        var placed = false
        var layout: PdfModel.Layout?
        var night: Bool?
        var clear = 0
        var reading: PdfModel.Reading?
        var model: PdfModel?
        var tapped: () -> Void = {}
        var tappedMark: (Mark) -> Void = { _ in }
        var selected: (PDFSelection?) -> Void = { _ in }
        nonisolated(unsafe) var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// The words selected, or nil once nothing is.
        @objc func selectionChanged(_ note: Notification) {
            let s = (note.object as? PDFView)?.currentSelection
            let words = s?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            selected(words.isEmpty ? nil : s)
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            // On a highlight: what to do with it. Elsewhere: the bars.
            if let view = gesture.view as? PDFView, let model {
                let point = gesture.location(in: view)
                if let page = view.page(for: point, nearest: false),
                   let id = painter.mark(at: view.convert(point, to: page), on: page),
                   let mark = model.marks.first(where: { $0.id == id }) {
                    return tappedMark(mark)
                }
            }
            tapped()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        MarkedPage.night = model.night
        let view = PDFView()
        view.document = model.document
        view.autoScales = true
        view.displayDirection = .vertical
        // The pages draw their own rounded edge; a square shadow behind would show at the corners.
        view.pageShadowsEnabled = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let model = model
        context.coordinator.observers = [
            NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { note in
                guard let view = note.object as? PDFView, let page = view.currentPage, let doc = view.document else { return }
                let index = doc.index(for: page)
                MainActor.assumeIsolated { model.shown(index) }
            },
        ]
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: .PDFViewSelectionChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let c = context.coordinator
        c.tapped = tapped
        c.tappedMark = tappedMark
        c.selected = selected
        c.model = model
        c.painter.paint(model.marks, in: model, view: view)
        if c.clear != clear {
            c.clear = clear
            view.clearSelection()
        }
        if c.reading != model.reading {
            c.reading = model.reading
            if let r = model.reading, let page = model.document?.page(at: r.page), let line = page.selection(for: r.range) {
                line.color = UIColor.tintColor.withAlphaComponent(0.22)
                view.highlightedSelections = [line]
            } else {
                view.highlightedSelections = nil
            }
        }
        if c.layout != model.layout {
            c.layout = model.layout
            switch model.layout {
            case .scroll:
                view.displayMode = .singlePageContinuous
                view.usePageViewController(false)
            case .single:
                view.displayMode = .singlePage
                view.displayDirection = .horizontal
                view.usePageViewController(true)
            case .double:
                view.usePageViewController(false)
                view.displayMode = .twoUp
                view.displaysAsBook = true
            }
            if model.layout != .single { view.displayDirection = .vertical }
            view.autoScales = true
        }
        if c.night != model.night {
            let redraw = c.night != nil
            c.night = model.night
            MarkedPage.night = model.night
            view.backgroundColor = model.night ? UIColor(white: 0.08, alpha: 1) : UIColor(PdfDesk.color)
            if redraw, let doc = view.document, let page = view.currentPage {
                // The pages are drawn again only when the document is put back.
                view.document = nil
                view.document = doc
                view.go(to: page)
            }
        }
        if !c.placed, let page = model.document?.page(at: model.page) {
            c.placed = true
            DispatchQueue.main.async { view.go(to: page) }
        }
        if let target = model.target, let page = model.document?.page(at: target.page) {
            DispatchQueue.main.async {
                model.target = nil
                view.go(to: page)
            }
        }
    }
}
/// 目录 for a PDF, as the book's: the title and where you are on top, then the outline in one
/// white card with the page each starts on; the one you're in is in the accent, the ones before faded.
private struct PhonePdfToc: View {
    let model: PdfModel
    let close: () -> Void
    private let tint = YYTint.standard

    var body: some View {
        let current = model.chapter?.id
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            HStack(spacing: YYUI.s(11)) {
                VStack(alignment: .leading, spacing: YYUI.s(3)) {
                    Text(model.title).font(YYUI.font(14, .bold)).foregroundStyle(YYColor.t1)
                    Text([model.author, String(localized: "第 \(model.label(of: model.page)) 页 · 共 \(model.pageCount) 页")].compactMap { $0 }.joined(separator: " · "))
                        .font(YYUI.font(10)).monospacedDigit().foregroundStyle(YYColor.t3)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(YYUI.font(10, .semibold)).foregroundStyle(YYColor.t1)
                        .frame(width: YYUI.s(26), height: YYUI.s(26))
                        .background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, YYUI.s(16))
            if model.chapters.isEmpty {
                VStack(spacing: YYUI.s(5)) {
                    Text("这个 PDF 没有目录").font(YYUI.font(12.5, .semibold)).foregroundStyle(YYColor.t2)
                    Text("用底下的滑杆翻到想看的页").font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.chapters) { c in
                                if c.id != model.chapters.first?.id { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                                row(c, now: c.id == current, done: (current ?? -1) > c.id).id(c.id)
                            }
                        }
                        .padding(.horizontal, YYUI.s(12))
                        .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(14)))
                        .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(YYColor.line, lineWidth: 0.5))
                        .padding(.horizontal, YYUI.s(14))
                        .padding(.bottom, YYUI.s(20))
                    }
                    .scrollIndicators(.never)
                    .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                }
            }
        }
        .padding(.top, YYUI.s(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(YYColor.bg)
    }

    private func row(_ c: PdfModel.Chapter, now: Bool, done: Bool) -> some View {
        Button {
            model.go(to: c.page)
            close()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(6)) {
                Text(c.title)
                    .font(YYUI.font(11.5, now ? .semibold : .regular))
                    .foregroundStyle(now ? tint.accent : done ? YYColor.t3 : YYColor.t1)
                    .lineLimit(now ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, CGFloat(c.depth) * YYUI.s(12))
                Spacer(minLength: YYUI.s(6))
                Text(model.label(of: c.page))
                    .font(YYUI.font(10, now ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(now ? tint.accent : YYColor.t3)
            }
            .padding(.vertical, YYUI.s(11))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
