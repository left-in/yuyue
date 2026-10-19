#if os(iOS)
import SwiftUI

/// 沉浸设置 (prototype 沉浸阅读): one switch to go in, then what goes with it, each of which can
/// be kept. From a book the switch is for that book now; from 我的 it is for every book opened.
struct PhoneImmersiveSheet: View {
    var model: ReaderModel?
    @AppStorage(ImmersivePrefs.alwaysKey) private var always = false
    @AppStorage(ImmersivePrefs.statusKey) private var status = true
    @AppStorage(ImmersivePrefs.progressKey) private var progress = true
    @AppStorage(ImmersivePrefs.quietKey) private var quiet = true
    @AppStorage(ImmersivePrefs.hintsKey) private var hints = true
    @AppStorage(ImmersivePrefs.stillKey) private var still = true
    @AppStorage(ImmersivePrefs.marksKey) private var marks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: YYUI.s(8)) {
                Image(systemName: "viewfinder").font(YYUI.font(13, .medium)).foregroundStyle(YYColor.t1)
                Text("沉浸阅读").font(YYUI.font(13, .semibold)).foregroundStyle(YYColor.t1)
                Spacer()
                YYSwitch(isOn: Binding { model?.immersive ?? always } set: { on in
                    if let model {
                        model.chromeShown = false
                        model.immersive = on
                    } else {
                        always = on
                    }
                })
            }
            Text(model == nil ? String(localized: "打开后每本书一打开就只留下字。下面这些会一起关掉，也可以逐项留下。") : String(localized: "打开后读书时只留下字。下面这些会一起关掉，也可以逐项留下。"))
                .font(YYUI.font(10)).lineSpacing(YYUI.s(3)).foregroundStyle(YYColor.t3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, YYUI.s(6))
                .padding(.bottom, YYUI.s(12))
            YYGroup {
                row(String(localized: "隐藏状态栏、时间和电量"), $status)
                row(String(localized: "隐藏进度、页码和剩余时间"), $progress)
                row(String(localized: "读书时通知不打扰"), $quiet)
                row(String(localized: "关掉书伴提示和难词注释"), $hints)
                row(String(localized: "关掉翻页动画"), $still)
                row(String(localized: "隐藏划线和想法"), $marks)
            }
            if quiet {
                YYNote(String(localized: "iOS 不让 App 自己打开勿扰：在系统设置的“专注模式”里加一个“阅读”，读书前从控制中心打开。"))
            }
            Spacer(minLength: YYUI.s(12))
            Text("双击屏幕边缘进出沉浸 · 点中间临时呼出控制")
                .font(YYUI.font(9.5)).foregroundStyle(YYColor.t3)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, YYUI.s(14))
        .padding(.top, YYUI.s(20))
        .padding(.bottom, YYUI.s(8))
        .background(YYColor.bg)
        .presentationDetents([.height(YYUI.s(440))])
        .presentationDragIndicator(.visible)
        // Each change shows at once on the page behind.
        .onChange(of: [hints, still, marks]) { if let model { model.immersive = model.immersive } }
    }

    private func row(_ title: String, _ on: Binding<Bool>) -> some View {
        YYRow(title: title) { YYSwitch(isOn: on) }
    }
}
#endif

#if os(iOS)
/// 我的 › 墨水屏: one switch, a piece of the page as it will look, and what changes with it.
struct PhoneEInk: View {
    let library: Library
    @AppStorage(EInk.key) private var on = false
    private let paper = YYPaper.eink

    var body: some View {
        YYPage {
            YYGroup {
                YYRow(title: String(localized: "墨水屏模式"), icon: "rectangle.portrait.on.rectangle.portrait") {
                    YYSwitch(isOn: Binding { on } set: { EInk.set($0, core: library.core) })
                }
            }
            .padding(.top, YYUI.s(10))
            sample.padding(.top, YYUI.s(14))
            YYNote(String(localized: "纸色换成墨水屏那种带颗粒的浅灰，字是纯黑；划线变成黑色的实线、波浪线；封面、插图转成灰度；没有任何动画，翻页是整页直接切换，界面也不再有阴影和毛玻璃。关掉后回到原来的纸色。"))
        }
        .navigationTitle("墨水屏")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A few lines on the e-ink paper: a highlight as a black line under it, a wavy one.
    private var sample: some View {
        let size = YYUI.s(13.5)
        var text = AttributedString(String(localized: "父亲说：“事已如此，不必难过，"))
        var marked = AttributedString(String(localized: "好在天无绝人之路！"))
        marked.underlineStyle = Text.LineStyle(pattern: .solid, color: paper.ink)
        text += marked
        text += AttributedString("”")
        var wave = AttributedString(String(localized: "回家变卖典质，父亲还了亏空；"))
        wave.underlineStyle = Text.LineStyle(pattern: .dot, color: paper.ink)
        var second = AttributedString("\n")
        second += wave
        second += AttributedString(String(localized: "又借钱办了丧事。"))
        return VStack(alignment: .leading, spacing: YYUI.s(8)) {
            Text("背影").font(YYUI.serif(YYUI.s(18), .semibold)).tracking(YYUI.s(18) * 0.05)
            Text(text + second).font(YYUI.serif(size)).lineSpacing(size * 1.05)
        }
        .foregroundStyle(paper.ink)
        .padding(YYUI.s(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper.bg, in: .rect(cornerRadius: YYUI.s(12)))
        .overlay(RoundedRectangle(cornerRadius: YYUI.s(12)).strokeBorder(paper.ink, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
#endif
