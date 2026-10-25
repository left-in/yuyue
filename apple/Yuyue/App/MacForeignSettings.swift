#if os(macOS)
import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers
import YuyueCore

/// 设置 · 外文 (prototype 外文阅读设置): looking a word up, the 生词 marks, and the system's
/// offline translation, which can be downloaded from here before the first 译.
struct ForeignSettings: View {
    let library: Library
    @AppStorage(ForeignPrefs.speakKey) private var speak = true
    @AppStorage(ForeignPrefs.accentKey) private var accent = ForeignPrefs.Accent.british
    @AppStorage(ForeignPrefs.markKey) private var mark = true
    @AppStorage(ForeignPrefs.glossKey) private var gloss = true
    @AppStorage(ForeignPrefs.levelKey) private var level = 3
    @AppStorage(ForeignPrefs.glossVocabKey) private var glossVocab = false
    @State private var status: LanguageAvailability.Status?
    @State private var download: TranslationSession.Configuration?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeading(String(localized: "点词"))
            SettingsCard {
                SettingsRow(String(localized: "系统词典"), detail: String(localized: "导入的词典里查不到时用 Mac 自带的。哪几本打开、谁在前面，在“词典”App 的设置里选")) {
                    Button("打开词典") { openDictionary() }
                }
                SettingsRow(String(localized: "点词时读出来")) { SettingsSwitch(isOn: $speak) }
                SettingsRow(String(localized: "英文发音")) {
                    YYSegments(items: [(ForeignPrefs.Accent.british, String(localized: "英音")), (.american, String(localized: "美音"))], selection: $accent, small: true)
                        .frame(width: 120)
                }
            }
            SettingsHeading(String(localized: "MDict 词典"))
            MDictList(core: library.core)
            SettingsHeading(String(localized: "难词注释"))
            SettingsCard {
                SettingsRow(String(localized: "在难词上方写释义"), detail: String(localized: "英文书里，难一些的词上方直接写着简短的中文意思")) {
                    SettingsSwitch(isOn: $gloss)
                }
                SettingsRow(String(localized: "级别"), detail: String(localized: "级别越高标得越少")) {
                    YYSegments(items: ForeignPrefs.levels.map { (Int($0.level), $0.name) }, selection: $level, small: true)
                        .frame(width: 260)
                }
                .disabled(!gloss || glossVocab)
                SettingsRow(String(localized: "只标生词本里的词")) { SettingsSwitch(isOn: $glossVocab) }
                    .disabled(!gloss)
                glossPreview
            }
            .onChange(of: "\(gloss)\(level)\(glossVocab)") { NotificationCenter.default.post(name: .vocabChanged, object: nil) }
            SettingsHeading(String(localized: "生词"))
            SettingsCard {
                SettingsRow(String(localized: "在所有书里标出来"), detail: String(localized: "生词本里在学的词，在任何一本书里再遇到，都用虚线标出来；掌握了就不再标")) {
                    SettingsSwitch(isOn: $mark)
                }
            }
            .onChange(of: mark) { NotificationCenter.default.post(name: .vocabChanged, object: nil) }
            SettingsHeading(String(localized: "翻译"))
            SettingsCard {
                SettingsRow(String(localized: "系统离线翻译"), detail: String(localized: "免费、不限量，在这台 Mac 上翻，原文不出这台 Mac。“译”和双击一句都用它")) {
                    translationState
                }
            }
            if let failed {
                Label(failed, systemImage: "exclamationmark.circle")
                    .font(.yy(size: 11)).foregroundStyle(YYColor.danger)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
        .task { await check() }
        .translationTask(download) { session in
            // Only ever used from here.
            nonisolated(unsafe) let session = session
            do {
                try await session.prepareTranslation()
                failed = nil
            } catch {
                failed = Translator.message(for: error)
            }
            download = nil
            await check()
        }
    }

    /// A line marked at the level chosen, with the meanings the list really gives.
    private var glossPreview: some View {
        let words: [(String, String?, UInt8)] = [("an ", nil, 0), ("amiable", "亲切的", 4), (" young man of ", nil, 0), ("tolerable", "可容忍的", 5),
                                                 (" fortune, ", nil, 0), ("eager", String(localized: "热心的"), 2), (" to ", nil, 0), ("ascertain", String(localized: "确定"), 3), (" her views…", nil, 0)]
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text("预览").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).padding(.trailing, 10)
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                let shown = gloss && !glossVocab && w.1 != nil && w.2 >= level
                VStack(spacing: 1) {
                    Text(shown ? w.1! : " ").font(.yy(size: 9)).foregroundStyle(YYColor.t2)
                    Text(w.0).font(.custom("Georgia", size: 13.5)).foregroundStyle(YYColor.t1)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .animation(.snappy(duration: 0.2), value: level)
    }

    @ViewBuilder private var translationState: some View {
        switch status {
        case .installed?:
            Label("英文 → 中文 已下载", systemImage: "checkmark")
                .font(.yy(size: 12)).foregroundStyle(YYColor.t2)
        case .supported?:
            Button("下载英文 → 中文") {
                download = .init(source: Locale.Language(identifier: "en"), target: Translator.target)
            }
            .disabled(download != nil)
        case .unsupported?:
            Text("这台 Mac 不支持").font(.yy(size: 12)).foregroundStyle(YYColor.t3)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private func check() async {
        status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Translator.target)
    }

    private func openDictionary() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Dictionary") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
/// 导入 MDict 词典: the ones imported, looked up first and in this order; 导入 reads a `.mdx`
/// once into the library (a big one takes a minute).
private struct MDictList: View {
    let core: YuyueCore
    @State private var list: [DictionaryInfo] = []
    @State private var picking = false
    @State private var importing: String?
    @State private var failed: String?

    var body: some View {
        SettingsCard {
            ForEach(list, id: \.id) { d in
                SettingsRow(d.title, detail: String(localized: "\(d.entries) 个词条")) {
                    SettingsSwitch(isOn: Binding(get: { d.enabled }, set: { on in
                        try? core.setDictionary(id: d.id, enabled: on)
                        reload()
                    }))
                }
                .contextMenu {
                    Button("移除", role: .destructive) {
                        try? core.removeDictionary(id: d.id)
                        reload()
                    }
                }
            }
            SettingsRow(importing.map { String(localized: "正在导入 \($0)…") } ?? String(localized: "导入 MDict 词典"),
                        detail: failed ?? String(localized: "选 .mdx 文件。点词时先查这里的词典，查不到再用系统的；右键一本可以移除")) {
                if importing != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("选文件…") { picking = true }
                }
            }
        }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "mdx") ?? .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await add(urls) }
        }
    }

    private func reload() { list = (try? core.dictionaries()) ?? [] }

    private func add(_ urls: [URL]) async {
        failed = nil
        for url in urls {
            importing = url.deletingPathExtension().lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            let core = core
            let result = await Task.detached { Result { try core.importDictionary(path: url.path(percentEncoded: false)) } }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            if case .failure(let e) = result { failed = Library.message(for: e) }
            reload()
        }
        importing = nil
    }
}
#endif
