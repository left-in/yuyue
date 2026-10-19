#if os(macOS)
import AuthenticationServices
import SwiftUI
import YuyueCore

/// 设置 · 同步 (prototype f111): the state and each device's last sync on top, the three ways in
/// the middle, what goes along below.
struct SyncSettings: View {
    let library: Library
    @State private var editingWebDAV = false
    @State private var signingIn = false
    @State private var googleProblem: String?
    /// What 书文件和有声书 take, worked out when the page opens.
    @State private var filesSize: Int64?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private var sync: Sync { library.sync }
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The banner only takes room when there's something to choose.
            VStack(spacing: 0) {
                status
                ConflictsBanner(library: library, above: 12)
            }
            SettingsHeading(String(localized: "同步方式"))
            HStack(spacing: 12) {
                methodCard(.icloud, symbol: "cloud", title: "iCloud", detail: String(localized: "选 iCloud 云盘里的一个文件夹"))
                methodCard(.webdav, symbol: "externaldrive.connected.to.line.below", title: "WebDAV", detail: String(localized: "坚果云、群晖、Nextcloud…"))
                methodCard(.googleDrive, symbol: "globe", title: "Google Drive",
                           detail: GoogleAuth.clientID == nil ? String(localized: "有 Android 设备时用 · 还没开通") : String(localized: "用你自己的 Google 账号"))
            }
            .fixedSize(horizontal: false, vertical: true)
            if editingWebDAV {
                WebDAVForm(sync: sync, editing: $editingWebDAV)
            } else if sync.method == .webdav, let account = sync.webdav {
                SettingsCard {
                    SettingsRow(String(localized: "WebDAV 服务器"), detail: [account.url.host() ?? account.url.absoluteString, account.user].filter { !$0.isEmpty }.joined(separator: " · ")) {
                        Button("修改") { editingWebDAV = true }
                    }
                }
            } else if sync.method == .googleDrive {
                SettingsCard {
                    SettingsRow(String(localized: "Google 账号"), detail: [sync.googleEmail, String(localized: "放在 Drive 里只有语阅看得到的文件夹")].compactMap { $0 }.joined(separator: " · ")) {
                        Button("退出") { sync.stop() }
                    }
                }
            } else if signingIn || googleProblem != nil {
                HStack(spacing: 8) {
                    if signingIn {
                        ProgressView().controlSize(.small)
                        Text("在弹出的窗口里登录 Google…").font(.system(size: 11.5)).foregroundStyle(YYColor.t2)
                    } else if let googleProblem {
                        Label(googleProblem, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(YYColor.danger)
                    }
                }
                .padding(.leading, 8)
            }
            SettingsHeading(String(localized: "同步这些"))
            SettingsCard {
                SettingsRow(String(localized: "进度和书签"), compact: true) { included(.reading) }
                SettingsRow(String(localized: "笔记和生词"), compact: true) { included(.notes) }
                SettingsRow(String(localized: "设置和替换规则"), compact: true) { included(.settings) }
                SettingsRow(String(localized: "书文件和有声书"), detail: filesDetail, compact: true) {
                    SettingsSwitch(isOn: Binding(get: { sync.syncsFiles }, set: { sync.syncFiles($0) }))
                }
            }
            Label("不用注册账号，数据只在你的设备和你自己的网盘之间走", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(YYColor.t3)
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .onAppear {
            sync.loadDevices()
            filesSize = sync.filesSize()
        }
    }

    /// 3.2 GB，占你自己的 iCloud 空间；在这台 Mac 上合成的听读书也跟着过去
    private var filesDetail: String {
        let place = switch sync.method {
        case .webdav: String(localized: "网盘")
        case .googleDrive: "Google Drive "
        default: "iCloud "
        }
        let size = filesSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + "，" } ?? ""
        return String(localized: "\(size)占你自己的 \(place)空间；在这台 Mac 上合成的听读书也跟着过去")
    }

    private func included(_ part: SyncPart) -> some View {
        SettingsSwitch(isOn: Binding(get: { sync.includes(part) }, set: { sync.include(part, $0) }))
    }

    // MARK: Status

    private var status: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                        Text(subline).font(.system(size: 10.5)).foregroundStyle(YYColor.t3)
                    }
                    Spacer()
                    if sync.isOn {
                        Button { sync.now() } label: {
                            Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                        .disabled(sync.state == .syncing)
                    }
                }
                if !sync.devices.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(sync.devices, id: \.id) { device($0) }
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        let (symbol, color): (String, Color) = switch sync.state {
        case .syncing: ("arrow.triangle.2.circlepath", tint.accent)
        case .failed: ("exclamationmark", YYColor.danger)
        case .idle: sync.isOn ? ("checkmark", YYColor.ok) : ("icloud.slash", YYColor.t3)
        }
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
            .symbolEffect(.rotate, isActive: sync.state == .syncing)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.13), in: .circle)
    }

    private var headline: String {
        switch sync.state {
        case .syncing: return String(localized: "正在同步…")
        case .failed: return String(localized: "这次没同步上")
        case .idle:
            guard sync.isOn else { return String(localized: "还没开同步") }
            guard let last = sync.lastSynced else { return String(localized: "已连上") }
            return String(localized: "已同步 · ") + Self.ago(last)
        }
    }

    private var subline: String {
        if case .failed(let why) = sync.state { return why }
        guard sync.isOn else { return String(localized: "下面选一种方式，进度、笔记和设置就在你的设备之间同步") }
        let place = switch sync.method {
        case .webdav: "WebDAV"
        case .googleDrive: "Google Drive"
        default: String(localized: "iCloud 云盘")
        }
        return String(localized: "\(place) · 进度、笔记和设置在 \(max(1, sync.devices.count)) 台设备之间同步")
    }

    private func device(_ d: DeviceInfo) -> some View {
        // `.v-ms-dv`
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(d.platform))
                .font(.system(size: 14))
                .foregroundStyle(YYColor.t2)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name.isEmpty ? String(localized: "设备") : d.name)
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                Text(detail(of: d)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if d.thisDevice {
                Text("这台").font(.system(size: 10.5)).foregroundStyle(YYColor.t2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(YYColor.inset, in: .rect(cornerRadius: 10))
    }

    private func detail(of d: DeviceInfo) -> String {
        if d.thisDevice { return String(localized: "刚刚") }
        guard let at = d.lastAt else { return String(localized: "还没读过") }
        let when = Self.ago(Date(timeIntervalSince1970: Double(at) / 1000))
        guard let book = library.books.first(where: { $0.id == d.lastBook }) else { return when }
        let percent = d.lastFraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
        return "\(when) · \(book.title)\(percent)"
    }

    static func ago(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return String(localized: "刚刚") }
        if s < 3600 { return String(localized: "\(Int(s / 60)) 分钟前") }
        if Calendar.current.isDateInToday(date) { return String(localized: "今天 ") + date.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "昨天 ") + date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.month().day())
    }

    private static func symbol(_ platform: String) -> String {
        switch platform {
        case "ios": "iphone"
        case "ipados": "ipad"
        case "android": "smartphone"
        default: "laptopcomputer"
        }
    }

    // MARK: Ways

    private func methodCard(_ m: Sync.Method, symbol: String, title: String, detail: String) -> some View {
        let on = sync.method == m
        let later = m == .googleDrive && GoogleAuth.clientID == nil
        return Button { pick(m) } label: {
            // `.v-ms-way`
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(on ? tint.accent : YYColor.t1)
                        .frame(width: 28, height: 28)
                        .background(on ? tint.soft : YYColor.inset, in: .rect(cornerRadius: 8))
                    Spacer()
                    if on {
                        Image(systemName: "checkmark.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(tint.accent)
                    }
                }
                .padding(.bottom, 6)
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(YYColor.card, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? tint.accent : YYColor.line, lineWidth: on ? 1.5 : 0.5))
            .opacity(later ? 0.55 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(later)
        .contextMenu {
            if on { Button("停止同步") { sync.stop() } }
        }
    }

    private func pick(_ m: Sync.Method) {
        switch m {
        case .icloud:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "用这个文件夹同步")
            panel.message = String(localized: "在 iCloud 云盘里选一个文件夹（比如新建一个“语阅”），每台设备选同一个")
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try sync.choose(folder: url) } catch { library.alert = Library.message(for: error) }
        case .webdav:
            editingWebDAV = true
        case .googleDrive:
            guard !signingIn else { return }
            signingIn = true
            googleProblem = nil
            editingWebDAV = false
            Task {
                do {
                    try await sync.connectGoogle { url, scheme in
                        try await webAuthenticationSession.authenticate(using: url, callback: .customScheme(scheme), additionalHeaderFields: [:])
                    }
                } catch {
                    googleProblem = Sync.message(for: error)
                }
                signingIn = false
            }
        case .none:
            break
        }
    }
}

/// The WebDAV account: address, name, password, and 连接 to check them.
private struct WebDAVForm: View {
    let sync: Sync
    @Binding var editing: Bool
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var folder = String(localized: "语阅")
    @State private var check: WebDAVCheck?
    @State private var checking = false

    private var account: Sync.WebDAVAccount? {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true, u.host() != nil else { return nil }
        return Sync.WebDAVAccount(url: u, user: user.trimmingCharacters(in: .whitespaces), password: password,
                                  folder: folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow(String(localized: "服务器地址")) {
                    TextField("", text: $url, prompt: Text("https://dav.jianguoyun.com/dav/"))
                        .textFieldStyle(.roundedBorder).frame(width: 300)
                }
                SettingsRow(String(localized: "账号")) {
                    TextField("", text: $user).textFieldStyle(.roundedBorder).frame(width: 300)
                }
                SettingsRow(String(localized: "密码"), detail: String(localized: "坚果云填“应用密码”；存在钥匙串里")) {
                    SecureField("", text: $password).textFieldStyle(.roundedBorder).frame(width: 300)
                }
                SettingsRow(String(localized: "文件夹")) {
                    TextField("", text: $folder).textFieldStyle(.roundedBorder).frame(width: 300)
                }
                HStack {
                    if let check {
                        Text("连接检查 · \(check.summary)").font(.system(size: 11.5)).foregroundStyle(YYColor.t3)
                    }
                    Spacer()
                    Button(check?.failed == true ? String(localized: "重试") : sync.method == .webdav ? String(localized: "重新连接") : String(localized: "连接")) { run() }
                        .buttonStyle(YYButtonStyle(kind: .main, size: .small))
                        .disabled(account == nil || checking)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if let check { WebDAVCheckCard(check: check) }
        }
        .onAppear {
            if let a = sync.webdav {
                url = a.url.absoluteString
                user = a.user
                password = a.password
                folder = a.folder
            }
        }
    }

    private func run() {
        guard let account else { return }
        checking = true
        Task {
            let result = await WebDAVCheck.run(account) { check = $0 }
            check = result
            checking = false
            if result.passed {
                sync.keep(account)
                try? await Task.sleep(for: .seconds(1.2))
                editing = false
            }
        }
    }
}
#endif
