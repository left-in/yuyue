#if os(iOS)
import SwiftUI

/// 点词 on the phone: a card along the bottom with the word, its sound and short meaning, the
/// phrase it was met in, where the meaning came from, 完整释义 and 加入生词本. A tap on the
/// page puts it away (ReaderModel.closeLookup).
struct PhoneWordCard: View {
    let model: ReaderModel
    let lookup: WordLookup
    @State private var full = false
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: YYUI.s(6)) {
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(8)) {
                Text(lookup.definition?.headword ?? lookup.word)
                    .font(.custom("Georgia", size: YYUI.s(20)).weight(.bold))
                    .foregroundStyle(YYColor.t1)
                if let phonetic = lookup.definition?.phonetic {
                    Text(phonetic).font(YYUI.font(11)).foregroundStyle(YYColor.t2)
                }
                Spacer(minLength: YYUI.s(8))
                Button { model.say(lookup.word) } label: {
                    Image(systemName: "headphones").font(YYUI.font(12, .medium)).foregroundStyle(YYColor.t1)
                        .frame(width: YYUI.s(32), height: YYUI.s(32)).background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("再读一遍"))
                Button { model.closeLookup() } label: {
                    Image(systemName: "xmark").font(YYUI.font(11, .semibold)).foregroundStyle(YYColor.t2)
                        .frame(width: YYUI.s(32), height: YYUI.s(32)).background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("关闭"))
            }
            meaning
            if full, let html = lookup.html {
                DictEntryView(html: html).frame(height: YYUI.s(260))
            }
            Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.top, YYUI.s(4))
            HStack(spacing: YYUI.s(8)) {
                Text(source).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                Spacer(minLength: YYUI.s(4))
                if lookup.html != nil {
                    Button(full ? String(localized: "收起释义") : String(localized: "完整释义")) {
                        withAnimation(.snappy(duration: 0.2)) { full.toggle() }
                    }
                    .buttonStyle(YYButtonStyle(kind: .soft, size: .small))
                }
                Button { model.keep(!lookup.kept) } label: {
                    Label(lookup.kept ? String(localized: "在生词本里") : String(localized: "加入生词本"), systemImage: lookup.kept ? "checkmark" : "plus")
                }
                .buttonStyle(YYButtonStyle(kind: lookup.kept ? .soft : .main, size: .small))
            }
        }
        .padding(YYUI.s(16))
        .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(18)))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .onChange(of: lookup.word) { full = false }
    }

    @ViewBuilder private var meaning: some View {
        if let d = lookup.definition {
            (Text(d.partOfSpeech.map { $0 + " " } ?? "").font(.custom("Georgia", size: YYUI.s(13))).italic().foregroundStyle(YYColor.t3)
                + Text(d.meaning).font(YYUI.font(13)).foregroundStyle(YYColor.t1))
                .fixedSize(horizontal: false, vertical: true)
        } else if let gloss = lookup.gloss {
            Text(gloss).font(YYUI.font(13)).foregroundStyle(YYColor.t1)
        } else {
            Text("没查到。可以在 我的 › 外文阅读 里导入 MDict 词典。")
                .font(YYUI.font(12)).foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var source: String {
        let from = lookup.dictionary ?? (lookup.gloss != nil ? String(localized: "系统翻译") : String(localized: "词典"))
        guard let n = lookup.count, n > 0 else { return from }
        return n == 1 ? String(localized: "\(from) · 本书只出现这一次") : String(localized: "\(from) · 本书出现 \(n) 次")
    }
}
#endif

#if os(iOS)
import UniformTypeIdentifiers
import YuyueCore

/// 我的 › 外文阅读 › MDict 词典: the ones imported, on or off, 导入 from Files.
struct PhoneMDictList: View {
    let core: YuyueCore
    @State private var list: [DictionaryInfo] = []
    @State private var picking = false
    @State private var importing: String?
    @State private var failed: String?
    private let tint = YYTint.standard

    var body: some View {
        YYGroup {
            ForEach(list, id: \.id) { d in
                YYRow(title: d.title) {
                    Text("\(d.entries) 个词条").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                    YYSwitch(isOn: Binding(get: { d.enabled }, set: { on in
                        try? core.setDictionary(id: d.id, enabled: on)
                        reload()
                    }), label: d.title)
                }
                .swipeActions { Button("移除", role: .destructive) { try? core.removeDictionary(id: d.id); reload() } }
                .contextMenu { Button("移除", role: .destructive) { try? core.removeDictionary(id: d.id); reload() } }
            }
            Button { picking = true } label: {
                HStack(spacing: YYUI.s(6)) {
                    if importing != nil { ProgressView() } else { Image(systemName: "plus").font(YYUI.font(10.5, .semibold)) }
                    Text(importing.map { String(localized: "正在导入 \($0)…") } ?? String(localized: "导入 MDict 词典（.mdx）"))
                        .font(YYUI.font(11.5, .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint.accent)
                .padding(.vertical, YYUI.s(9))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(importing != nil)
            if let failed {
                Text(failed).font(YYUI.font(10.5)).foregroundStyle(YYColor.danger).padding(.vertical, YYUI.s(6))
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
