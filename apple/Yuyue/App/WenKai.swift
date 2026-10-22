import CoreText
import Foundation
import Observation
import SwiftUI
import YuyueCore

/// 霞鹜文楷 (排版 · 字体): an open-source 楷体, too big to ship (two weights, about 28 MB), so it
/// is fetched from its own GitHub releases the first time it is chosen. The files go in the
/// core's fonts folder, where the page loads them from (`/fonts/…`); the app registers them too,
/// so the choice itself can be shown in the face. Until they are here the page uses 楷体.
@MainActor @Observable
final class WenKai {
    static let shared = WenKai()

    nonisolated static let files = ["LXGWWenKaiLite-Regular.ttf", "LXGWWenKaiLite-Medium.ttf"]
    nonisolated static let base = URL(string: "https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.530/")!

    /// 0–1 while downloading.
    private(set) var progress: Double?
    private(set) var failure: String?
    private(set) var installed = false
    @ObservationIgnored private var dir: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Called once the library is open: knows where fonts go, and registers any already there.
    func attach(fontsDir: String) {
        let dir = URL(fileURLWithPath: fontsDir, isDirectory: true)
        self.dir = dir
        installed = Self.files.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0).path(percentEncoded: false)) }
        if installed { register() }
    }

    /// Chosen in 排版: fetched unless it is here or on its way.
    func ensure() {
        guard !installed, task == nil, let dir else { return }
        failure = nil
        progress = 0
        task = Task {
            defer { task = nil }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, name) in Self.files.enumerated() {
                    let target = dir.appending(path: name)
                    if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { continue }
                    let temp = try await Self.download(Self.base.appending(path: name)) { [weak self] f in
                        Task { @MainActor in self?.progress = (Double(i) + f) / Double(Self.files.count) }
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temp, to: target)
                }
                progress = nil
                installed = true
                register()
                NotificationCenter.default.post(name: .fontsChanged, object: nil)
            } catch {
                progress = nil
                failure = (error as? URLError)?.code == .notConnectedToInternet ? String(localized: "没有联网") : String(localized: "没下载下来")
            }
        }
    }

    private func register() {
        guard let dir else { return }
        for name in Self.files {
            CTFontManagerRegisterFontsForURL(dir.appending(path: name) as CFURL, .process, nil)
        }
    }

    nonisolated private static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let total = max(1, response.expectedContentLength)
        let temp = FileManager.default.temporaryDirectory.appending(path: "wenkai-\(UUID().uuidString).ttf")
        FileManager.default.createFile(atPath: temp.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(Double(written) / Double(total))
            }
        }
        try handle.write(contentsOf: buffer)
        return temp
    }
}

extension Notification.Name {
    /// A downloaded font (霞鹜文楷) arrived: pages already open load again to use it.
    static let fontsChanged = Notification.Name("yuyue.fontsChanged")
}

/// Under 排版's fonts while 霞鹜文楷 is on its way, or when it didn't come.
struct WenKaiStatus: View {
    let chosen: Bool
    private var w: WenKai { WenKai.shared }

    var body: some View {
        if chosen, let p = w.progress {
            HStack(spacing: 8) {
                ProgressView(value: p).progressViewStyle(.linear).tint(YYTint.standard.fill).frame(width: 90)
                Text("霞鹜文楷正在下载 \(Int(p * 100))%，先用楷体").font(.system(size: 11)).foregroundStyle(YYColor.t2)
            }
        } else if chosen, let f = w.failure {
            HStack(spacing: 8) {
                Text("霞鹜文楷\(f)").font(.system(size: 11)).foregroundStyle(YYColor.danger)
                Button("再试一次") { w.ensure() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(YYTint.standard.accent)
            }
        }
    }
}
