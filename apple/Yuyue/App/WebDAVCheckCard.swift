import SwiftUI

/// `.v-sy-dx`: 连接检查's steps down a thread, the failed one red with how to fix it under it,
/// the untested ones dashed.
struct WebDAVCheckCard: View {
    let check: WebDAVCheck
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(check.steps) { step in
                row(step)
                if check.fixAfter == step.id, let fix = check.fix { fixCard(fix) }
            }
        }
        .padding(.vertical, YYUI.s(4))
        .padding(.horizontal, YYUI.s(14))
        .background(alignment: .topLeading) {
            // The thread the steps hang on.
            Rectangle().fill(YYColor.line).frame(width: 1)
                .padding(.vertical, YYUI.s(23))
                .padding(.leading, YYUI.s(23))
        }
        .yyCard()
    }

    private func row(_ step: WebDAVCheck.Step) -> some View {
        HStack(spacing: YYUI.s(10)) {
            badge(step.mark)
            Text(step.title)
                .font(YYUI.font(11.5, step.mark == .bad ? .semibold : .medium))
                .foregroundStyle(step.mark == .bad ? YYColor.danger : step.mark == .untested ? YYColor.t3 : YYColor.t1)
            Spacer(minLength: YYUI.s(8))
            Text(step.note)
                .font(step.code ? YYUI.font(10, design: .monospaced) : YYUI.font(10).monospacedDigit())
                .foregroundStyle(YYColor.t3)
                .lineLimit(1)
        }
        .frame(height: YYUI.s(38))
    }

    @ViewBuilder private func badge(_ mark: WebDAVCheck.Mark) -> some View {
        let size = YYUI.s(19)
        switch mark {
        case .ok:
            Image(systemName: "checkmark").font(YYUI.font(9, .bold)).foregroundStyle(YYColor.ok)
                .frame(width: size, height: size)
                .background(Circle().fill(YYColor.card).overlay(Circle().fill(YYColor.ok.opacity(0.15))))
        case .warn:
            Image(systemName: "exclamationmark").font(YYUI.font(9, .bold)).foregroundStyle(YYColor.warn)
                .frame(width: size, height: size)
                .background(Circle().fill(YYColor.card).overlay(Circle().fill(YYColor.warn.opacity(0.15))))
        case .bad:
            Image(systemName: "xmark").font(YYUI.font(9, .bold)).foregroundStyle(YYColor.card)
                .frame(width: size, height: size)
                .background(YYColor.danger, in: .circle)
        case .running:
            ProgressView().controlSize(.mini)
                .frame(width: size, height: size)
                .background(YYColor.card, in: .circle)
        case .untested:
            Circle().fill(YYColor.card)
                .overlay(Circle().strokeBorder(YYColor.t3, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                .frame(width: size, height: size)
        }
    }

    private func fixCard(_ fix: WebDAVCheck.Fix) -> some View {
        VStack(alignment: .leading, spacing: YYUI.s(2)) {
            Text(fix.headline).fontWeight(.semibold).foregroundStyle(YYColor.t1)
            if !fix.before.isEmpty || fix.path != nil {
                Text("\(fix.before)\(Text(fix.path ?? "").foregroundStyle(YYColor.t1))\(fix.after)")
            }
            if let link = fix.link, let url = fix.url {
                Button { openURL(url) } label: {
                    HStack(spacing: 2) {
                        Text(link)
                        Image(systemName: "chevron.right").font(YYUI.font(8, .bold))
                    }
                    .font(YYUI.font(10.5, .semibold))
                    .foregroundStyle(YYTint.standard.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, YYUI.s(4))
            }
        }
        .font(YYUI.font(10.5))
        .lineSpacing(YYUI.s(10.5) * 0.5)
        .foregroundStyle(YYColor.t2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, YYUI.s(10))
        .padding(.bottom, YYUI.s(11))
        .padding(.horizontal, YYUI.s(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(10)))
        .padding(.leading, YYUI.s(29))
        .padding(.bottom, YYUI.s(8))
    }
}

extension WebDAVCheck {
    /// "刚刚 · 用了 1.2 秒", over the card.
    var summary: String {
        guard finished != nil else { return String(localized: "正在检查…") }
        let s = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        return String(localized: "刚刚 · 用了 \(String(format: "%.1f", s)) 秒")
    }
}
