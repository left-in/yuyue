#if os(iOS)
import SwiftUI
import UIKit

/// Wi‑Fi 传书 (prototype 导入): the address in big type, what the computer will see there, and a
/// row for each file coming over — how far, how long still, and when it's on the shelf.
struct PhoneWifi: View {
    @State private var transfer: WifiTransfer
    @State private var copied = false
    /// No computer has come for a while: perhaps 本地网络 was turned down for 语阅.
    @State private var stuck = false
    @Environment(\.scenePhase) private var phase
    private let tint = YYTint.standard

    init(library: Library) {
        _transfer = State(initialValue: WifiTransfer(library: library))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                addressCard.padding(.top, YYUI.s(8))
                browser.padding(.top, YYUI.s(12))
                if !transfer.items.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("正在接收").font(YYUI.font(12.5, .semibold)).foregroundStyle(YYColor.t1)
                        Spacer()
                        Text("\(transfer.items.count) 个文件").font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
                    }
                    .padding(.horizontal, YYUI.s(2))
                    .padding(.top, YYUI.s(18))
                    .padding(.bottom, YYUI.s(8))
                    YYGroup {
                        ForEach(transfer.items) { row($0) }
                    }
                }
                if stuck, transfer.client == nil, transfer.problem == nil { stuckCard.padding(.top, YYUI.s(12)) }
                YYNote(String(localized: "传的时候让这一页亮着；锁屏会断开，回来后从断的地方接着传。"))
            }
            .padding(.horizontal, YYUI.s(16))
            .padding(.bottom, YYUI.s(24))
        }
        .background(YYColor.bg)
        .navigationTitle("Wi‑Fi 传书")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            transfer.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            transfer.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: phase) { _, now in
            if now == .active { transfer.start() } else if now == .background { transfer.stop() }
        }
        .task {
            try? await Task.sleep(for: .seconds(25))
            withAnimation(.snappy) { stuck = true }
        }
    }

    /// The computer can't open the address: the two things it usually is, and the way to the switch.
    private var stuckCard: some View {
        VStack(alignment: .leading, spacing: YYUI.s(6)) {
            Text("电脑打不开这个地址？").font(YYUI.font(12.5, .semibold)).foregroundStyle(YYColor.t1)
            Text("看看电脑和 iPhone 是不是连的同一个 Wi‑Fi。都对的话，多半是没让语阅用“本地网络”：在设置 › 语阅 里把它打开，再回来。")
                .font(YYUI.font(10.5)).lineSpacing(YYUI.s(10.5) * 0.4).foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("去设置")
            }
            .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
            .padding(.top, YYUI.s(4))
        }
        .padding(YYUI.s(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .yyCard()
        .transition(.opacity)
    }

    /// `.v-lib-url`: 在电脑浏览器里打开, the address and 复制, then whether a computer has come.
    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("在电脑浏览器里打开").font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
            HStack(spacing: YYUI.s(8)) {
                if let address = transfer.address, transfer.problem == nil {
                    Text(address)
                        .font(.yy(size: YYUI.s(19), weight: .bold, design: .monospaced).monospacedDigit())
                        .tracking(YYUI.s(19) * 0.02)
                        .foregroundStyle(YYColor.t1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        UIPasteboard.general.string = "http://\(address)"
                        copied = true
                    } label: {
                        Label(copied ? String(localized: "已复制") : String(localized: "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                } else {
                    Text(transfer.problem ?? String(localized: "正在准备…"))
                        .font(YYUI.font(14, .semibold))
                        .foregroundStyle(transfer.problem == nil ? YYColor.t2 : YYColor.danger)
                        .frame(maxWidth: .infinity, minHeight: YYUI.s(28), alignment: .leading)
                }
            }
            .padding(.top, YYUI.s(6))
            Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.top, YYUI.s(12))
            HStack(spacing: YYUI.s(6)) {
                Circle().fill(transfer.client == nil ? YYColor.t3 : YYColor.ok).frame(width: YYUI.s(6), height: YYUI.s(6))
                Text(transfer.client.map { $0.isEmpty ? String(localized: "已连上一台电脑") : String(localized: "已连上一台电脑 · \($0)") } ?? String(localized: "电脑和这台 iPhone 连同一个 Wi‑Fi"))
                    .font(YYUI.font(10.5)).foregroundStyle(YYColor.t2)
            }
            .padding(.top, YYUI.s(11))
        }
        .padding(.horizontal, YYUI.s(16))
        .padding(.top, YYUI.s(16))
        .padding(.bottom, YYUI.s(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .yyCard()
    }

    /// `.v-lib-web`: what the computer shows at that address.
    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: YYUI.s(6)) {
                Circle().fill(YYColor.tint).frame(width: YYUI.s(6), height: YYUI.s(6))
                Text(transfer.address ?? " ")
                    .font(.yy(size: YYUI.s(9.5), design: .monospaced))
                    .foregroundStyle(YYColor.t3)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, YYUI.s(24))
            }
            .padding(.horizontal, YYUI.s(9))
            .frame(height: YYUI.s(24))
            .background(YYColor.inset)
            HStack(spacing: YYUI.s(6)) {
                Image(systemName: "square.and.arrow.up").font(YYUI.font(12))
                Text("把书拖到这里，或者点这里选文件").font(YYUI.font(10.5))
            }
            .foregroundStyle(YYColor.t2)
            .frame(maxWidth: .infinity)
            .frame(height: YYUI.s(58))
            .overlay(RoundedRectangle(cornerRadius: YYUI.s(9)).strokeBorder(tint.accent, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
            .padding(YYUI.s(10))
        }
        .background(YYColor.card)
        .clipShape(.rect(cornerRadius: YYUI.s(12)))
        .overlay(RoundedRectangle(cornerRadius: YYUI.s(12)).strokeBorder(YYColor.line, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    /// `.v-lib-rx .row`: a tile for the kind (a tick once it's in), the name, how it's going.
    private func row(_ item: WifiTransfer.Item) -> some View {
        HStack(alignment: .top, spacing: YYUI.s(10)) {
            Image(systemName: symbol(item))
                .font(YYUI.font(12, .medium))
                .foregroundStyle(YYColor.t1)
                .frame(width: YYUI.s(28), height: YYUI.s(28))
                .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: YYUI.s(2)) {
                Text(item.name).font(YYUI.font(11, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1).truncationMode(.middle)
                Text("\(Snapshots.size(UInt64(item.size))) · \(detail(item))")
                    .font(YYUI.font(10).monospacedDigit())
                    .foregroundStyle(failed(item) ? YYColor.danger : YYColor.t3)
                    .lineLimit(2)
                if item.state == .receiving {
                    GeometryReader { g in
                        Capsule().fill(YYColor.inset)
                            .overlay(alignment: .leading) {
                                Capsule().fill(tint.accent).frame(width: g.size.width * Double(item.received) / Double(max(item.size, 1)))
                            }
                    }
                    .frame(height: 3)
                    .padding(.top, YYUI.s(4))
                }
            }
        }
        .padding(.vertical, YYUI.s(9))
    }

    private func symbol(_ item: WifiTransfer.Item) -> String {
        if item.state == .done { return "checkmark" }
        if failed(item) { return "exclamationmark" }
        switch (item.name as NSString).pathExtension.lowercased() {
        case "m4b", "mp3", "m4a", "aac": return "music.note"
        default: return "book.closed"
        }
    }

    private func failed(_ item: WifiTransfer.Item) -> Bool {
        if case .failed = item.state { true } else { false }
    }

    private func detail(_ item: WifiTransfer.Item) -> String {
        switch item.state {
        case .queued: item.received > 0 ? String(localized: "停在 \(Int(Double(item.received) / Double(max(item.size, 1)) * 100))%，等电脑接着传") : String(localized: "排队中")
        case .receiving: WifiTransfer.progress(item)
        case .importing: String(localized: "正在放进书架…")
        case .done: String(localized: "已经放进书架")
        case .failed(let why): why
        }
    }
}

/// 导入 (prototype): the shelf's 加号. Each way in on its own row, with what it takes written out.
struct PhoneImportSheet: View {
    /// The folder being watched, when there is one.
    var watching: String?
    var fromFiles: () -> Void
    var overWifi: () -> Void
    var remote: () -> Void
    var watch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            YYSheetHeader(title: String(localized: "导入")) { dismiss() }
                .padding(.bottom, YYUI.s(12))
            YYGroup {
                way("folder", String(localized: "从文件导入"), String(localized: "EPUB、PDF、TXT、MOBI"), fromFiles)
                way("wifi", String(localized: "Wi‑Fi 传书"), String(localized: "电脑和手机连同一个 Wi‑Fi，用浏览器传"), overWifi)
                way("server.rack", String(localized: "远程书库"), String(localized: "OPDS、WebDAV：Calibre、Kavita、Komga、坚果云"), remote)
                way("folder.badge.gearshape", String(localized: "监听一个文件夹"), watching.map { String(localized: "正在监听“\($0)”") } ?? String(localized: "放进这个文件夹的书，下次打开语阅时自动导入"), watch)
            }
            YYNote(String(localized: "同一个文件不会重复导入。"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, YYUI.s(14))
        .padding(.top, YYUI.s(14))
        .background(YYColor.bg)
        .presentationDetents([.height(YYUI.s(400))])
        .presentationDragIndicator(.visible)
    }

    /// `.v-r2`: the tile, the name and the line under it, the chevron.
    private func way(_ symbol: String, _ title: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: YYUI.s(10)) {
                Image(systemName: symbol)
                    .font(YYUI.font(12, .medium))
                    .foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(28), height: YYUI.s(28))
                    .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                VStack(alignment: .leading, spacing: YYUI.s(1)) {
                    Text(title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                    Text(detail).font(YYUI.font(10)).lineSpacing(YYUI.s(2)).foregroundStyle(YYColor.t3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
            }
            .padding(.vertical, YYUI.s(11))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif

#if os(iOS)
/// 监听一个文件夹: which one, choosing another, stopping.
struct PhoneWatchedFolder: View {
    let library: Library
    @State private var picking = false
    @State private var working = false

    var body: some View {
        YYPage {
            Text("放进这个文件夹的书，下次打开语阅时自动导入。可以是“文件”App 里的任何文件夹，iCloud 云盘、网盘的也行。")
                .font(YYUI.font(10.5)).lineSpacing(YYUI.s(4)).foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, YYUI.s(4))
                .padding(.top, YYUI.s(10))
                .padding(.bottom, YYUI.s(14))
            YYGroup {
                YYRow(String(localized: "文件夹"), icon: "folder", value: library.watched.name ?? String(localized: "还没选"))
            }
            Button {
                picking = true
            } label: {
                if working { ProgressView().controlSize(.small).tint(YYTint.standard.onBlack) } else { Text(library.watched.name == nil ? String(localized: "选一个文件夹") : String(localized: "换一个文件夹")) }
            }
            .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
            .disabled(working)
            .padding(.top, YYUI.s(14))
            if library.watched.name != nil {
                Button("停止监听") { library.watched.stop() }
                    .buttonStyle(YYButtonStyle(kind: .plain, size: .large, wide: true))
                    .padding(.top, YYUI.s(6))
            }
            YYNote(String(localized: "从书架删掉的书不会再导入；文件改过以后会当成新的一本。"))
        }
        .navigationTitle("监听一个文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            working = true
            Task {
                do { try await library.watched.choose(url, into: library) } catch { library.alert = Library.message(for: error) }
                working = false
            }
        }
    }
}
#endif
