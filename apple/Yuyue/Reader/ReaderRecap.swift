import SwiftUI
import YuyueCore

/// 前情提要 (prototype): back to a book after a few days, three lines on what happened so far
/// float over the page. Written by 书伴 from the part already read only; not within a day.
struct Recap: Codable, Equatable {
    let lines: [String]
    /// Days since the book was last read, on any device.
    var days: Int
}

extension ReaderModel {
    /// Asks for the recap when the book was last read a day or more ago and 书伴 is set up.
    func startRecap(lastRead at: Int64, here: Position) {
        let days = Int(Date().timeIntervalSince1970 - Double(at) / 1000) / 86400
        let config = CompanionConfig.current
        guard days >= 1, config.isReady, let detail, here.section > detail.start || here.sentence > 20 else { return }
        let key = "recap|\(here.section)|\(here.sentence / 20)"
        if var kept = recapCache[key] {
            kept.days = days
            recap = kept
            return
        }
        let core = core, book = bookID
        Task { [weak self] in
            let text = await Self.readBefore(core: core, book: book, detail: detail, here: here)
            guard text.count > 200 else { return }
            let system = """
            你是「语阅」里的书伴。读者隔了 \(days) 天又打开《\(detail.summary.title)》，帮他想起之前读到哪、发生了什么。
            规则：
            1. 只根据下面的原文，不要提后面的情节，不要剧透。
            2. 写三句话，每句一行，每句不超过 30 个字（英文不超过 20 个词），用\(Companion.replyLanguage)，按发生的先后。
            3. 只写这三行，不要标题，不要编号，不要别的话。
            """
            guard let reply = try? await Companion.answer(config, system: system, prompt: "原文（读者读过的最后一部分）：\n" + text),
                  let self else { return }
            let lines = reply.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*·0123456789.、）)")) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { return }
            let recap = Recap(lines: Array(lines.prefix(3)), days: days)
            self.recapCache[key] = recap
            // Not if the reader has already moved on.
            if self.pager.position.map({ $0.section == here.section && abs(Int($0.sentence) - Int(here.sentence)) < 30 }) ?? true {
                self.recap = recap
            }
        }
    }

    /// About the last 2,400 characters read, the chapter before included when this one has
    /// only just started.
    @concurrent private static func readBefore(core: YuyueCore, book: String, detail: BookDetail, here: Position) async -> String {
        var parts: [String] = []
        var count = 0
        var section = here.section
        var upTo = Int(here.sentence)
        while count < 2400 {
            let all = (try? core.sentences(bookId: book, section: section)) ?? []
            let end = min(all.count, upTo + 1)
            if end > 0 {
                var taken: [String] = []
                for s in all[..<end].reversed() where count < 2400 {
                    taken.append(s)
                    count += s.count
                }
                parts.insert(taken.reversed().joined(), at: 0)
            }
            guard count < 2400, section > detail.start,
                  let previous = try? core.previousSection(bookId: book, section: section, speech: false) else { break }
            section = previous
            upTo = Int.max - 1
        }
        return parts.joined(separator: "\n").replacingOccurrences(of: "\n\n", with: "\n")
    }

    /// Kept recaps, in the 书伴 answers' file for this book.
    var recapCache: [String: Recap] {
        get {
            guard let url = recapFile, let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: Recap].self, from: data)) ?? [:]
        }
        set {
            guard let url = recapFile else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: url, options: .atomic)
        }
    }

    private var recapFile: URL? {
        library.map { $0.dataDir.appending(path: "companion", directoryHint: .isDirectory).appending(path: "\(bookID).recap.json") }
    }
}

/// The card: 前情提要 · N 天没读了, the three lines, and 接着读.
struct RecapCard: View {
    let recap: Recap
    let tint: YYTint
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold)).foregroundStyle(tint.accent)
                Text("前情提要").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(recap.days) 天没读了").font(.system(size: 11)).foregroundStyle(YYColor.t3)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(recap.lines.enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(i + 1).").font(.system(size: 11)).monospacedDigit().foregroundStyle(YYColor.t3)
                        Text(line).font(.system(size: 13.5)).lineSpacing(4).foregroundStyle(YYColor.t1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 11)
            HStack {
                Text("只提要你读过的部分").font(.system(size: 11)).foregroundStyle(YYColor.t3)
                Spacer()
                Button(action: done) {
                    Text("接着读")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tint.onBlack)
                        .padding(.horizontal, 15).frame(height: 30)
                        .background(tint.black, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
        }
        .foregroundStyle(YYColor.t1)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(YYColor.card, in: .rect(cornerRadius: 16))
        .yyShadow(scheme == .dark ? YYShadow.floatDark : YYShadow.floatLight)
    }
}
