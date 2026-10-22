#if os(macOS)
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import YuyueCore

/// 生词本 in the shelf window (prototype 生词本): the words kept while reading books in other
/// languages, by the day they were kept or by book. Each has its sound, the short meaning, the
/// sentence it was met in and where, and how often it turns up across the library. 掌握了 stops
/// it being marked in books; 导出 makes Anki cards or a CSV.
struct MacWordsView: View {
    @Environment(\.shelfHeaderInset) private var headerInset
    let library: Library
    @Environment(\.openWindow) private var openWindow
    @AppStorage("words.byBook") private var byBook = false
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    @State private var words: [VocabWord] = []
    @State private var counts: [String: WordCount] = [:]
    @State private var chapters: [String: BookDetail] = [:]
    @State private var showKnown = false
    @State private var export: ExportFile?
    @State private var speaker = AVSpeechSynthesizer()
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    private var learning: [VocabWord] { words.filter { !$0.known } }
    private var known: [VocabWord] { words.filter(\.known) }
    private var shown: [VocabWord] { showKnown ? known : learning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `.v-mac-hd.v-ms-hd`: 64 high, the title in the middle; `.v-ms-mn` 22 in, 28 on the right.
            header
                // The title and the line beside it share a baseline, which lifts the title: down 4.
                .frame(height: 56)
                .padding(.top, 8)
                .padding(.leading, 22)
                .padding(.trailing, 28)
            if words.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        chips.padding(.bottom, 4)
                        if shown.isEmpty {
                            Text(showKnown ? String(localized: "还没有掌握的词。在学的词点“掌握了”，就挪到这里") : String(localized: "都掌握了。新查的词加进生词本，会出现在这里"))
                                .font(.system(size: 12)).foregroundStyle(YYColor.t3)
                                .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(groups, id: \.id) { group in
                                HStack(alignment: .top, spacing: 24) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1)
                                            .lineLimit(3)
                                        if let sub = group.subtitle {
                                            Text(sub).font(.system(size: 11.5)).foregroundStyle(YYColor.t3)
                                        }
                                        Text("\(group.words.count) 个").font(.system(size: 11.5)).foregroundStyle(YYColor.t3)
                                    }
                                    .frame(width: 90, alignment: .leading)
                                    .padding(.top, 18)
                                    NoteCard {
                                        ForEach(group.words, id: \.word) { row($0) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, 22)
                    .padding(.trailing, 28)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        .background(YYColor.bg)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task(id: library.books.map(\.id)) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .vocabChanged)) { _ in Task { await load() } }
        .fileExporter(isPresented: Binding { export != nil } set: { if !$0 { export = nil } },
                      document: export, contentType: export?.type ?? .plainText, defaultFilename: export?.name) { result in
            if case .success = result { library.note(icon: "square.and.arrow.up", String(localized: "导出好了"), export?.done ?? "") }
            export = nil
        }
    }

    private func load() async {
        words = (try? library.core.words()) ?? []
        for book in Set(words.map(\.book)) where chapters[book] == nil {
            chapters[book] = try? library.core.book(id: book)
        }
        // Counting reads every book's sentences: off the main thread.
        let core = library.core, list = words.map(\.word)
        let found = await Task.detached(priority: .utility) { (try? core.wordCounts(words: list)) ?? [] }.value
        counts = Dictionary(found.map { ($0.word.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugExportWords") {
            let dir = FileManager.default.temporaryDirectory
            try? Vocab.anki(words, title: source).write(to: dir.appending(path: "words-anki.txt"), atomically: true, encoding: .utf8)
            try? Vocab.csv(words, title: source).write(to: dir.appending(path: "words.csv"), atomically: true, encoding: .utf8)
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("生词本").font(.system(size: 22, weight: .bold)).foregroundStyle(YYColor.t1)
                .padding(.leading, headerInset)
            if !words.isEmpty {
                (Text("\(learning.count)").fontWeight(.semibold).foregroundStyle(YYColor.t1) + Text(" 个在学 · 掌握了 \(known.count) 个"))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(YYColor.t2)
            }
            Spacer()
            Segments(items: [(false, String(localized: "按时间")), (true, String(localized: "按书"))], selection: $byBook, small: true) { Text($1) }
                .frame(width: 156)
            Menu {
                Button("Anki 卡片…") { export = .anki(shown, title: source) }
                Button("CSV 表格…") { export = .csv(shown, title: source) }
            } label: {
                Label("导出 Anki · CSV", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(YYColor.card, in: .capsule)
                    .overlay(Capsule().strokeBorder(YYColor.line))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(shown.isEmpty)
            .help(showKnown ? String(localized: "导出掌握了的词") : String(localized: "导出在学的词"))
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            chip(false, String(localized: "在学 \(learning.count)"))
            chip(true, String(localized: "掌握了 \(known.count)"))
        }
    }

    private func chip(_ value: Bool, _ text: String) -> some View {
        let on = showKnown == value
        return Button { showKnown = value } label: {
            Text(text).monospacedDigit()
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? tint.onBlack : YYColor.t2)
                .padding(.horizontal, 13).frame(height: 28)
                .background(on ? AnyShapeStyle(tint.black) : AnyShapeStyle(YYColor.card), in: .capsule)
                .overlay(Capsule().strokeBorder(on ? .clear : YYColor.line))
        }
        .buttonStyle(.plain)
    }

    // MARK: Groups

    private struct WordGroup {
        let id: String
        let title: String
        let subtitle: String?
        var words: [VocabWord]
    }

    /// By the day they were kept, newest first; or by book, the book with the newest word first.
    private var groups: [WordGroup] {
        var out: [WordGroup] = []
        if byBook {
            for w in shown {
                if let i = out.firstIndex(where: { $0.id == w.book }) {
                    out[i].words.append(w)
                } else {
                    out.append(WordGroup(id: w.book, title: title(of: w.book), subtitle: nil, words: [w]))
                }
            }
        } else {
            let cal = Calendar.current
            for w in shown {
                let day = cal.startOfDay(for: Notes.date(w.at))
                let id = day.ISO8601Format()
                if out.last?.id == id {
                    out[out.count - 1].words.append(w)
                } else {
                    out.append(WordGroup(id: id, title: Notes.dayName(day), subtitle: Notes.monthDay(day), words: [w]))
                }
            }
        }
        return out
    }

    private func title(of book: String) -> String {
        library.books.first { $0.id == book }?.title ?? chapters[book]?.summary.title ?? String(localized: "已删除的书")
    }

    /// Pride and Prejudice · Chapter I.
    private func source(_ w: VocabWord) -> String {
        let title = title(of: w.book)
        guard let chapter = chapters[w.book]?.chapterTitle(for: w.section), chapter != title else { return title }
        return "\(title) · \(chapter)"
    }

    // MARK: One word

    private func row(_ w: VocabWord) -> some View {
        let meaning = Vocab.split(meaning: w.meaning)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(w.word).font(.custom("Georgia", size: 19).weight(.bold)).foregroundStyle(YYColor.t1)
                if let p = w.phonetic {
                    Text(p).font(.system(size: 12)).foregroundStyle(YYColor.t2)
                }
                Spacer(minLength: 8)
                Button { say(w) } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12, weight: .medium)).foregroundStyle(YYColor.t1)
                        .frame(width: 28, height: 28).background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                .help("读一遍")
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
            if let meaning {
                (Text(meaning.pos.map { $0 + " " } ?? "").font(.custom("Georgia", size: 13)).italic().foregroundStyle(YYColor.t3)
                    + Text(meaning.text).font(.system(size: 13)).foregroundStyle(YYColor.t1))
                    .padding(.top, 4)
            }
            if !w.context.isEmpty {
                Text(Vocab.attributed(w.context, word: w.word, accent: tint.accent, limit: 220))
                    .font(.custom("Georgia", size: 13.5)).foregroundStyle(YYColor.t2)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    // 按书 has the title beside the group already.
                    Text(byBook ? chapters[w.book]?.chapterTitle(for: w.section) ?? "" : source(w))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(YYColor.t2).lineLimit(1)
                    if let spread = Vocab.spread(counts[w.word.lowercased()]) {
                        Text(spread).font(.system(size: 11)).monospacedDigit().foregroundStyle(YYColor.t3)
                    }
                }
                Spacer()
                Button { setKnown(w, !w.known) } label: {
                    Label(w.known ? String(localized: "再学一遍") : String(localized: "掌握了"), systemImage: w.known ? "arrow.uturn.backward" : "checkmark")
                }
                .buttonStyle(CardButton(filled: false))
                .help(w.known ? String(localized: "放回在学，书里重新标出来") : String(localized: "书里不再标它"))
            }
            .padding(.top, 11)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture(count: 2) { open(w) }
        .contextMenu {
            Button("回到书里这一句") { open(w) }
                .disabled(!library.books.contains { $0.id == w.book && $0.available })
            Button("读一遍") { say(w) }
            Button("拷贝") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString([w.word, w.phonetic, w.meaning].compactMap { $0 }.joined(separator: " "), forType: .string)
            }
            Divider()
            Button("删除", role: .destructive) { library.deleteWord(w.word) }
        }
    }

    private func setKnown(_ w: VocabWord, _ on: Bool) {
        try? library.core.setWordKnown(word: w.word, known: on)
        NotificationCenter.default.post(name: .vocabChanged, object: nil)
    }

    private func open(_ w: VocabWord) {
        guard library.books.contains(where: { $0.id == w.book && $0.available }) else { return }
        library.open(w.book, at: Position(section: w.section, sentence: w.sentence))
        openWindow(id: "reader", value: w.book)
    }

    private func say(_ w: VocabWord) {
        speaker.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: w.word)
        u.voice = ForeignPrefs.voice(for: chapters[w.book]?.summary.language)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        speaker.speak(u)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed").font(.system(size: 28, weight: .light)).foregroundStyle(YYColor.t3)
            Text("还没有生词").font(.system(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
            Text("读外文书时点一个词，在释义卡片里点“加入生词本”，就记在这里，带着原句")
                .font(.system(size: 12)).foregroundStyle(YYColor.t2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What 导出 writes: Anki's text import, or a CSV table.
private struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
    let text: String
    let type: UTType
    let name: String
    let done: String

    @MainActor static func anki(_ words: [VocabWord], title: (VocabWord) -> String) -> ExportFile {
        ExportFile(text: Vocab.anki(words, title: title), type: .plainText, name: String(localized: "语阅生词 Anki.txt"),
                   done: String(localized: "\(words.count) 个词。在 Anki 里选“文件 › 导入”打开它"))
    }

    @MainActor static func csv(_ words: [VocabWord], title: (VocabWord) -> String) -> ExportFile {
        ExportFile(text: Vocab.csv(words, title: title), type: .commaSeparatedText, name: String(localized: "语阅生词.csv"), done: String(localized: "\(words.count) 个词"))
    }

    init(text: String, type: UTType, name: String, done: String) {
        self.text = text
        self.type = type
        self.name = name
        self.done = done
    }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
#endif
