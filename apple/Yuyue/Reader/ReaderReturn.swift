import SwiftUI
import YuyueCore

/// 进度冲突 (prototype S4): which device read on, how long ago, the words where it stopped, and
/// whether to go there. Shaped like 前情提要.
struct ElsewhereCard: View {
    let elsewhere: ReaderModel.Elsewhere
    let tint: YYTint
    let stay: () -> Void
    let jump: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer.and.iphone").font(.yy(size: 11)).foregroundStyle(YYColor.t2)
                Text("\(elsewhere.progress.deviceName ?? String(localized: "另一台设备")) 上读到了更后面")
                    .font(.yy(size: 12, weight: .semibold))
                Spacer()
                Text(Self.ago(Date(timeIntervalSince1970: Double(elsewhere.progress.at) / 1000)))
                    .font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            if let text = elsewhere.text {
                Text(text)
                    .font(YYUI.serif(12.5))
                    .lineSpacing(5)
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(2)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(YYColor.line).frame(width: 2) }
                    .padding(.top, 9)
            }
            HStack(spacing: 8) {
                Text("\(elsewhere.chapter.map { $0 + " · " } ?? "")\(Self.percent(elsewhere.progress.fraction)) · 这台在 \(Self.percent(elsewhere.here))")
                    .font(.yy(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3)
                    .lineLimit(1)
                Spacer()
                Button("留在这里", action: stay)
                    .buttonStyle(.plain)
                    .font(.yy(size: 11.5))
                    .foregroundStyle(YYColor.t2)
                    .padding(.horizontal, 10).frame(height: 28)
                Button(action: jump) {
                    Text("跳过去")
                        .font(.yy(size: 11.5, weight: .semibold))
                        .foregroundStyle(tint.onBlack)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(tint.black, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.top, 0) }
            .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(YYColor.card, in: .rect(cornerRadius: 16))
        .yyShadow(scheme == .dark ? YYShadow.floatDark : YYShadow.floatLight)
    }

    static func ago(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return String(localized: "刚刚") }
        if s < 3600 { return String(localized: "\(Int(s / 60)) 分钟前") }
        if Calendar.current.isDateInToday(date) { return String(localized: "今天 ") + date.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "昨天 ") + date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.month().day())
    }

    private static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}

/// 回到原处 (prototype 找得到，也回得来): over the capsule after jumping off, until a few pages
/// are read in the new place.
/// 没把握时书页上会提示: a TXT that may have been read in the wrong encoding or cut into the
/// wrong chapters, with the way to 编码和目录 and a way to let it be.
struct DoubtPill: View {
    let doubt: String
    let paper: YYPaper
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(YYColor.warn)
                    Text(doubt).foregroundStyle(paper.ink).lineLimit(1)
                    Text("去看看").foregroundStyle(paper.ink.opacity(0.6))
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 34)
                .contentShape(.rect)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.yy(size: 10, weight: .bold))
                    .foregroundStyle(paper.ink.opacity(0.5))
                    .frame(width: 30, height: 34)
                    .contentShape(.rect)
            }
            .accessibilityLabel("不用提示了")
        }
        .font(.yy(size: 12.5, weight: .semibold))
        .yyGlass(Capsule(), fill: paper.glass, line: paper.line, shadow: paper.isDark ? 0.35 : 0.08, radius: 10, y: 3,
                 liquid: !paper.isEink)
        .buttonStyle(.plain)
    }
}

struct ReturnPill: View {
    let page: Int?
    let paper: YYPaper
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(page.map { String(localized: "回到第 \($0) 页") } ?? String(localized: "回到原处"), systemImage: "arrow.uturn.backward")
                .font(.yy(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(paper.ink)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .yyGlass(Capsule(), fill: paper.glass, line: paper.line, shadow: paper.isDark ? 0.35 : 0.08, radius: 10, y: 3,
                         liquid: !paper.isEink)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
