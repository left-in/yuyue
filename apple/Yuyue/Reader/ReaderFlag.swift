import SwiftUI

/// 有声书: while the narrator reads a stretch the recording doesn't line up with, an amber line
/// beside its paragraph and a card over the page: 先不管, or 微调.
struct NarrationFlag: Equatable, Identifiable {
    let issue: Issue
    /// Which of the book's stretches this is, from 1, and how many there are.
    let number: Int
    let total: Int
    var id: String { issue.id }
}

extension ReaderModel {
    /// The book's stretches to look at again, from its recording's timings.
    func loadFlags() {
        guard let books = Audiobooks.shared, let a = books.audiobook(for: bookID), let t = books.timings(a) else {
            flagTimings = nil
            flagIssues = []
            return
        }
        flagTimings = t
        flagIssues = Issue.all(in: t, introSkipped: true).filter { if case .unsure = $0.kind { true } else { false } }
    }

    /// The stretch `spot` is in, while the narrator is reading.
    func checkFlag(_ spot: Player.Spot) {
        guard let player, player.narrated, let t = flagTimings else { return showFlag(nil) }
        let s = t.sentences
        let here = UInt32(max(0, spot.sentence))
        guard let i = flagIssues.firstIndex(where: { s[$0.at].section == spot.section && s[$0.at].sentence <= here && here <= s[$0.last].sentence }) else {
            return showFlag(nil)
        }
        showFlag(NarrationFlag(issue: flagIssues[i], number: i + 1, total: flagIssues.count))
    }

    func showFlag(_ f: NarrationFlag?) {
        if let f, let t = flagTimings {
            let s = t.sentences
            pager.setFlag(section: s[f.issue.at].section, first: Int(s[f.issue.at].sentence), last: Int(s[f.issue.last].sentence))
        } else {
            pager.clearFlag()
        }
        let shown = f.flatMap { flagsLetBe.contains($0.id) ? nil : $0 }
        if narrationFlag != shown { narrationFlag = shown }
    }

    /// 先不管: the card goes; the line stays while it's read.
    func letFlagBe() {
        guard let f = narrationFlag else { return }
        flagsLetBe.insert(f.id)
        narrationFlag = nil
    }

    /// 微调: stops the voice and opens the stretch's first sentence.
    func adjustFlag() {
        guard let f = narrationFlag else { return }
        player?.pause()
        adjustingFlag = f
    }

    /// After 微调: the recording reads with the new timings, and the stretch is gone if it's fixed.
    func adjusted(_ t: Timings) {
        guard let books = Audiobooks.shared, let a = books.audiobook(for: bookID) else { return }
        books.save(t, for: a)
    }

    /// The timings were saved, here or in 对齐检查.
    func timingsChanged() {
        loadFlags()
        if let spot = player?.spot { checkFlag(spot) } else { showFlag(nil) }
    }

    #if os(macOS)
    /// 对齐检查 on the Mac: which audiobook, and where.
    var flagTarget: AlignTarget? {
        guard let f = adjustingFlag ?? narrationFlag, let a = Audiobooks.shared?.audiobook(for: bookID) else { return nil }
        return AlignTarget(audiobook: a.id, at: f.issue.at)
    }
    #endif
}

struct NarrationFlagCard: View {
    let flag: NarrationFlag
    let letBe: () -> Void
    let adjust: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(YYColor.warn).frame(width: 6, height: 6)
                Text("这一段对得不太准").font(.yy(size: 12, weight: .semibold))
                Spacer()
                Text("第 \(flag.number) / \(flag.total) 处").font(.yy(size: 10)).monospacedDigit().foregroundStyle(YYColor.t3)
            }
            Text(note)
                .font(.yy(size: 11))
                .lineSpacing(3)
                .foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack(spacing: 8) {
                Spacer()
                Button("先不管", action: letBe).buttonStyle(YYButtonStyle(kind: .plain, size: .small))
                Button("微调", action: adjust).buttonStyle(YYButtonStyle(kind: .plain, size: .small))
            }
            .padding(.top, 9)
            .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
            .padding(.top, 10)
        }
        .foregroundStyle(YYColor.t1)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .yyFloatCard(.rect(cornerRadius: 16), shadow: scheme == .dark ? YYShadow.floatDark : YYShadow.floatLight)
    }

    private var note: String {
        guard case .unsure(let n) = flag.issue.kind else { return "" }
        return n > 1 ? String(localized: "这 \(n) 句录音只听清一部分，墨线可能跟声音错开。可以先听着，回头再调。")
            : String(localized: "这句录音只听清一部分，墨线可能跟声音错开。可以先听着，回头再调。")
    }
}

/// 微调 from the card, over the reader.
struct NarrationAdjustSheet: View {
    let model: ReaderModel
    let flag: NarrationFlag

    var body: some View {
        if let library = model.library, let books = Audiobooks.shared, let a = books.audiobook(for: model.bookID),
           let t = model.flagTimings {
            TimingAdjust(library: library, audiobook: a, timings: t, at: flag.issue.at) { model.adjusted($0) }
        }
    }
}
