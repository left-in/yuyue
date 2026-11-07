import Foundation
import YuyueCore

/// "第五回 游幻境指迷十二钗": the number and the name, when the title has both.
struct ChapterTitle {
    let number: String?
    let name: String

    init(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        if let m = t.firstMatch(of: /^(第[〇零一二三四五六七八九十百千两\d]+[回章节卷部篇集])[\s　:：、.]*(.*)$/), !m.2.isEmpty {
            number = String(m.1)
            name = String(m.2)
        } else {
            number = nil
            name = t
        }
    }
}

/// One line of 目录: an entry and the sections it covers, up to the next entry's.
struct TocChapter: Identifiable {
    let id: Int
    let title: String
    let depth: Int
    let item: TocItem
    let sections: Range<Int>
}

extension ReaderModel {
    /// The book's own table of contents; with none, the sections that have something to read.
    var tocChapters: [TocChapter] {
        guard let detail else { return [] }
        var items = detail.toc
        if items.isEmpty {
            // Counted among the ones listed, so they go 1, 2, 3 — not the sections' own places.
            var n = 0
            items = detail.sections.enumerated().compactMap { i, s in
                guard s.linear, s.kind == .text, !s.continued else { return nil }
                n += 1
                return TocItem(title: s.title ?? String(localized: "第 \(n) 节"), depth: 0, section: UInt32(i), anchor: nil)
            }
        }
        return items.enumerated().map { i, item in
            let start = Int(item.section)
            let end = items[(i + 1)...].first { Int($0.section) > start }.map { Int($0.section) } ?? detail.sections.count
            return TocChapter(id: i, title: item.title, depth: Int(item.depth), item: item, sections: start ..< max(start + 1, end))
        }
    }

    /// The chapter being read.
    func currentChapter(in chapters: [TocChapter]) -> Int? {
        guard let section else { return nil }
        return chapters.last { $0.sections.lowerBound <= Int(section) }?.id
    }

    /// About how long the chapter takes to read.
    func minutes(of chapter: TocChapter) -> Int {
        chapter.sections.reduce(0) { $0 + minutes(of: $1) }
    }

    /// How far into the chapter, by its sections' length.
    func within(_ chapter: TocChapter) -> Double {
        guard let detail, let section else { return 0 }
        let units = chapter.sections.map { Double(detail.sections[safe: $0]?.units ?? 0) }
        let total = units.reduce(0, +)
        guard total > 0 else { return 0 }
        var done = 0.0
        for (k, i) in chapter.sections.enumerated() {
            if i < Int(section) { done += units[k] }
            if i == Int(section) { done += units[k] * Double(sentence) / Double(max(1, sentenceCount)) }
        }
        return min(1, done / total)
    }
}
