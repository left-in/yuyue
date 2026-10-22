#if os(macOS)
import AppKit
import SwiftUI

/// 点词 (prototype 外文原著): under the word, its headword and sound, the short meaning, the
/// phrase it was met in, then 系统词典 · 本书出现 N 次, 更多释义 and 加入生词本.
struct WordCard: View {
    let model: ReaderModel
    let lookup: WordLookup
    private let tint = YYTint.standard
    /// 完整释义 of an MDict entry, open under the short meaning.
    @State private var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lookup.definition?.headword ?? lookup.word)
                    .font(.custom("Georgia", size: 21).weight(.bold))
                    .foregroundStyle(YYColor.t1)
                if let phonetic = lookup.definition?.phonetic {
                    Text(phonetic).font(.system(size: 11.5)).foregroundStyle(YYColor.t2)
                }
                Spacer(minLength: 8)
                Button { model.say(lookup.word) } label: {
                    Image(systemName: "headphones").font(.system(size: 12, weight: .medium)).foregroundStyle(YYColor.t1)
                        .frame(width: 28, height: 28).background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                .help("再读一遍")
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
            meaning.padding(.top, 6)
            if full, let html = lookup.html {
                DictEntryView(html: html)
                    .frame(height: 260)
                    .padding(.top, 8)
            }
            if let phrase {
                (Text(phrase).font(.custom("Georgia", size: 11.5)).italic().foregroundStyle(YYColor.t1))
                    .lineLimit(2)
                    .padding(.top, 4)
            }
            Divider().overlay(YYColor.line).padding(.top, 12)
            HStack(spacing: 6) {
                // The buttons keep their words; a long source gives way (it cut 加入生词本 short).
                Text(source).font(.system(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
                Spacer(minLength: 4)
                Button(lookup.html == nil ? String(localized: "更多释义") : full ? String(localized: "收起释义") : String(localized: "完整释义")) { more() }
                    .buttonStyle(CardButton(filled: false))
                    .fixedSize()
                Button { model.keep(!lookup.kept) } label: {
                    Label(lookup.kept ? String(localized: "在生词本里") : String(localized: "加入生词本"), systemImage: lookup.kept ? "checkmark" : "plus")
                }
                .buttonStyle(CardButton(filled: !lookup.kept))
                .fixedSize()
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        // A little wider than `.dict` (310): 本书只出现这一次 and both buttons on one line.
        .frame(width: 350)
        .onChange(of: lookup.word) { full = false }
        .background(YYColor.card, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 15, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
    }

    @ViewBuilder private var meaning: some View {
        if let d = lookup.definition {
            (Text(d.partOfSpeech.map { $0 + " " } ?? "").font(.custom("Georgia", size: 13)).italic().foregroundStyle(YYColor.t3)
                + Text(d.meaning).font(.system(size: 13)).foregroundStyle(YYColor.t1))
                .fixedSize(horizontal: false, vertical: true)
        } else if let gloss = lookup.gloss {
            Text(gloss).font(.system(size: 13)).foregroundStyle(YYColor.t1)
        } else {
            Text("系统词典里没有这个词。可以在“词典”App 的设置里打开英汉词典。")
                .font(.system(size: 12)).foregroundStyle(YYColor.t2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A few words either side of it in the sentence: "in possession of a good fortune".
    private var phrase: String? {
        let words = lookup.context.split(separator: " ", omittingEmptySubsequences: true)
        guard let i = words.firstIndex(where: { $0.lowercased().contains(lookup.word.lowercased()) }) else { return nil }
        let from = max(0, i - 4), to = min(words.count - 1, i + 1)
        let core = words[from ... to].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:“”\"'‘’"))
        return (from > 0 ? "…" : "") + core + (to < words.count - 1 ? "…" : "")
    }

    private var source: String {
        let from = lookup.dictionary ?? (lookup.definition != nil ? String(localized: "系统词典") : lookup.gloss != nil ? String(localized: "系统翻译") : String(localized: "词典"))
        guard let n = lookup.count, n > 0 else { return from }
        return n == 1 ? String(localized: "\(from) · 本书只出现这一次") : String(localized: "\(from) · 本书出现 \(n) 次")
    }

    /// The whole entry, in the system's own look-up window.
    private func more() {
        if lookup.html != nil {
            withAnimation(.snappy(duration: 0.2)) { full.toggle() }
            return
        }
        let word = lookup.definition?.headword ?? lookup.word
        if let url = URL(string: "dict://" + (word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 双击一句: the sentence and its translation, under where it was clicked.
struct SentenceCard: View {
    let model: ReaderModel
    let item: SentenceTranslation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.text)
                .font(.custom("Georgia", size: 12.5)).foregroundStyle(YYColor.t2)
                .lineSpacing(3).lineLimit(4)
            if let t = item.translated {
                Text(t).font(.system(size: 13.5)).foregroundStyle(YYColor.t1).lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failed = item.failed {
                Label(failed, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5)).foregroundStyle(YYColor.danger)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在翻译…").font(.system(size: 11.5)).foregroundStyle(YYColor.t3)
                }
            }
            Divider().overlay(YYColor.line).padding(.top, 2)
            HStack {
                Text("系统翻译 · 在这台 Mac 上").font(.system(size: 10.5)).foregroundStyle(YYColor.t3)
                Spacer()
                if let t = item.translated {
                    Button("拷贝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t, forType: .string)
                    }
                    .buttonStyle(CardButton(filled: false))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(width: 360, alignment: .leading)
        .background(YYColor.card, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 15, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
    }
}

/// The small buttons at the foot of a card: plain inset, or filled in the tint.
struct CardButton: ButtonStyle {
    let filled: Bool
    private let tint = YYTint.standard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(CardLabel())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? tint.onBlack : YYColor.t1)
            .padding(.horizontal, 9).frame(height: 24)
            .background(filled ? tint.black : YYColor.inset, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct CardLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9.5, weight: .bold))
            configuration.title
        }
    }
}

/// Puts a card under `rect` (above it when there is no room below), its left edge near the
/// rect's.
struct Beneath: ViewModifier {
    let rect: CGRect
    let size: CGSize
    @State private var card = CGSize(width: 330, height: 150)

    init(rect: CGRect, in size: CGSize) {
        self.rect = rect
        self.size = size
    }

    func body(content: Content) -> some View {
        let below = rect.maxY + 10 + card.height < size.height - 70
        let x = min(max(rect.minX - 30, 12), max(12, size.width - card.width - 12))
        let y = below ? rect.maxY + 10 : max(8, rect.minY - card.height - 10)
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { card = $0 }
            .offset(x: x, y: y)
    }
}
#endif
