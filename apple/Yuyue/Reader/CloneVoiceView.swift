import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import YuyueCore

/// 克隆一个声音 (docs/design/听书-分角色与克隆声音.html, C2–C3): read a little of this book aloud
/// (or bring a recording), hear what's off, name it, keep it. 存下 is the white block top right;
/// once kept, it asks where to use it.
struct CloneVoiceView: View {
    let context: CastContext
    /// The character it was started from, to offer it to them first.
    let forName: String?
    @Binding var path: [CastSheet.Route]

    @State private var recorder = SampleRecorder()
    @State private var sample: URL?
    @State private var imported = false
    @State private var check: SampleCheck?
    @State private var name = ""
    @State private var consent = false
    @State private var importing = false
    @State private var saving = false
    @State private var saved: ClonedVoice?
    @State private var failure: String?

    private var script: String {
        let sentences = (try? context.core.sentences(bookId: context.bookID, section: context.section)) ?? []
        var text = ""
        // Whole sentences, not the chapter's title (no punctuation in it).
        for s in sentences where !s.trimmingCharacters(in: .whitespaces).isEmpty && s.contains(where: { "，。！？；,.!?;".contains($0) }) {
            text += s
            if text.count > 90 { break }
        }
        return text.isEmpty ? Voices.sampleText(context.language) : text
    }

    var body: some View {
        YYPage {
            steps.padding(.top, YYUI.s(6))
            if sample == nil { record } else { review }
        }
        .navigationTitle(String(localized: "克隆一个声音"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if sample != nil {
                ToolbarItem(placement: .confirmationAction) {
                    // 存下 · 右上角白底小块 (11-03 选的 B)
                    Button(action: save) {
                        HStack(spacing: YYUI.s(6)) {
                            if saving { ProgressView().controlSize(.mini) } else { Text("✓").foregroundStyle(YYColor.ok).fontWeight(.bold) }
                            Text("存下")
                        }
                        .font(YYUI.font(12, .semibold))
                        .foregroundStyle(YYColor.t1)
                        .padding(.horizontal, YYUI.s(12)).frame(height: YYUI.s(30))
                        .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(10)))
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || (imported && !consent))
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appending(path: "yuyue-import-\(UUID().uuidString).\(url.pathExtension)")
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { use(copy, imported: true) }
        }
        .confirmationDialog(String(localized: "用在哪"), isPresented: Binding(get: { saved != nil }, set: { if !$0 { finish() } }), titleVisibility: .visible) {
            if let forName, let saved {
                Button(String(localized: "给\(forName)")) {
                    var v = context.role(forName) ?? RoleVoice(voice: nil, rate: 1, pitch: 0, right: false)
                    v.voice = saved.id
                    context.set(forName, v)
                    finish()
                }
            }
            if let saved, saved.isReady {
                Button(String(localized: "全书（旁白）")) {
                    context.player?.choose(saved, for: context.language)
                    finish()
                }
            }
            Button(String(localized: "先放着"), role: .cancel) { finish() }
        } message: {
            Text(saved?.isReady == false ? String(localized: "存下了。要在设置里接上 ElevenLabs 才能用它念；在那之前，用它的人物先用旁白的声音。") : String(localized: "存下了，只在这台设备上。"))
        }
        .alert(String(localized: "没存下"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(String(localized: "好")) {}
        } message: { Text(failure ?? "") }
        .onDisappear { recorder.stop() }
    }

    private var steps: some View {
        HStack(spacing: YYUI.s(10)) {
            step(1, String(localized: "录一段"), on: sample == nil)
            step(2, String(localized: "试听、起名字"), on: sample != nil)
            Spacer()
        }
    }

    private func step(_ n: Int, _ title: String, on: Bool) -> some View {
        HStack(spacing: YYUI.s(4)) {
            Text("\(n)").font(YYUI.font(9.5, .semibold)).frame(width: YYUI.s(16), height: YYUI.s(16))
                .foregroundStyle(on ? YYTint.standard.onBlack : YYColor.t3)
                .background(on ? YYTint.standard.black : YYColor.inset, in: .circle)
            Text(title).font(YYUI.font(10, on ? .semibold : .regular)).foregroundStyle(on ? YYColor.t1 : YYColor.t3)
        }
    }

    // MARK: 录一段

    private var record: some View {
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            Text(script)
                .font(YYUI.serif(15))
                .lineSpacing(9)
                .foregroundStyle(YYColor.t1)
                .padding(.horizontal, YYUI.s(16)).padding(.vertical, YYUI.s(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .yyCard()
                .padding(.top, YYUI.s(12))
            YYNote(String(localized: "照平常读书的样子念，不用念完。"))
                .padding(.top, -YYUI.s(8))
            // 录音 B · 整条就是录音 (11-03 选的)
            Button { recorder.recording ? stopRecording() : startRecording() } label: {
                HStack(spacing: YYUI.s(10)) {
                    Circle().fill(YYColor.danger).frame(width: YYUI.s(10), height: YYUI.s(10))
                        .overlay(Circle().stroke(YYColor.danger.opacity(0.18), lineWidth: recorder.recording ? 4 : 0).padding(-4))
                    Text(Self.time(recorder.seconds)).font(YYUI.font(17, .bold)).monospacedDigit()
                    HStack(spacing: 2) {
                        ForEach(Array(recorder.levels.suffix(28).enumerated()), id: \.offset) { _, l in
                            Capsule().fill(YYColor.t2).frame(width: 2, height: max(3, CGFloat(l) * YYUI.s(24)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: YYUI.s(24), alignment: .leading)
                    HStack(spacing: YYUI.s(5)) {
                        if recorder.recording {
                            RoundedRectangle(cornerRadius: 2.5).fill(YYColor.danger).frame(width: YYUI.s(10), height: YYUI.s(10))
                            Text("停下")
                        } else {
                            Text("点一下开始录")
                        }
                    }
                    .font(YYUI.font(11.5, .semibold))
                    .foregroundStyle(YYColor.t1)
                }
                .padding(.horizontal, YYUI.s(16))
                .frame(height: YYUI.s(58))
                .yyCard()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if recorder.seconds >= 8 {
                Text("✓ 8 秒够用了；多录到 30 秒更像。").font(YYUI.font(10)).foregroundStyle(YYColor.ok).padding(.horizontal, YYUI.s(4))
            } else {
                YYNote(String(localized: "8 秒就够，30 秒更像。"))
            }
            HStack(spacing: YYUI.s(10)) {
                whiteBlock(String(localized: "重来"), icon: "arrow.uturn.backward") { recorder.discard() }
                    .disabled(recorder.seconds == 0)
                whiteBlock(String(localized: "导入一段录音"), icon: "square.and.arrow.down", wide: true) { importing = true }
            }
        }
    }

    private func whiteBlock(_ title: String, icon: String, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: YYUI.s(7)) {
                Image(systemName: icon).font(YYUI.font(12)).foregroundStyle(YYColor.t2)
                Text(title).font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
            }
            .padding(.horizontal, YYUI.s(14))
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: YYUI.s(34))
            .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(10)))
            .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func startRecording() {
        Task {
            guard await SampleRecorder.allowed() else {
                failure = String(localized: "语阅没有用麦克风的权限。在系统设置的“隐私与安全性 › 麦克风”里打开。")
                return
            }
            context.player?.pause()
            recorder.start()
        }
    }

    private func stopRecording() {
        guard let url = recorder.stop(), recorder.seconds >= 1 else { return }
        use(url, imported: false)
    }

    private func use(_ url: URL, imported: Bool) {
        self.imported = imported
        sample = url
        check = SampleCheck.of(url)
        if name.isEmpty { name = imported ? url.deletingPathExtension().lastPathComponent : String(localized: "我的声音") }
    }

    // MARK: 试听、起名字

    private var review: some View {
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            if let check {
                YYGroup {
                    ForEach(check.items) { item in
                        HStack(spacing: YYUI.s(10)) {
                            Image(systemName: item.level == .ok ? "checkmark" : "exclamationmark.triangle")
                                .font(YYUI.font(10, .semibold))
                                .foregroundStyle(item.level == .ok ? YYColor.ok : YYColor.warn)
                                .frame(width: YYUI.s(22), height: YYUI.s(18))
                                .background((item.level == .ok ? YYColor.ok : YYColor.warn).opacity(0.13), in: .rect(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(YYUI.font(11.5, .semibold))
                                if let d = item.detail { Text(d).font(YYUI.font(10)).foregroundStyle(YYColor.t3) }
                            }
                            Spacer(minLength: 0)
                            if item.level == .warn { whiteBlock(String(localized: "重录"), icon: "arrow.uturn.backward", action: redo) }
                        }
                        .padding(.vertical, YYUI.s(9))
                    }
                }
                .padding(.top, YYUI.s(12))
            }
            if !CloneEngine.available {
                YYNote(String(localized: "试听要等克隆好：现在克隆用你在设置里接的 ElevenLabs（录音会传到你自己的 ElevenLabs 账号）。没接也能先存下，接上后再用。"))
            }
            YYGroup {
                YYField(label: String(localized: "名字")) { TextField(String(localized: "比如：小林"), text: $name) }
            }
            YYGroup {
                Button { consent.toggle() } label: {
                    HStack(spacing: YYUI.s(10)) {
                        Image(systemName: consent ? "checkmark.circle.fill" : "circle").font(YYUI.font(17))
                            .foregroundStyle(consent ? YYTint.standard.fill : YYColor.t3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("这是我的声音，或者我得到了本人同意").font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                            Text(imported ? String(localized: "导入别人的录音时一定要勾") : String(localized: "录的是别人时也要勾")).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, YYUI.s(9))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            YYNote(CloneEngine.available
                ? String(localized: "录音存在这台设备上，克隆时会传到你自己的 ElevenLabs 账号。点右上角“存下”后，问你用在哪。")
                : String(localized: "录音只存在这台设备上。点右上角“存下”后，问你用在哪。"))
        }
    }

    private func redo() {
        sample = nil
        check = nil
        recorder.discard()
    }

    private func save() {
        guard let sample else { return }
        saving = true
        let text = imported ? nil : script
        let seconds = check?.seconds ?? 0
        let name = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { saving = false }
            do {
                saved = try await ClonedVoices.save(recording: sample, name: name, text: text, seconds: seconds)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func finish() {
        saved = nil
        if !path.isEmpty { path.removeLast() }
    }

    static func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

/// The microphone, for 录一段: a level for each tenth of a second, and the file.
@Observable final class SampleRecorder {
    private(set) var recording = false
    private(set) var seconds: Double = 0
    private(set) var levels: [Float] = []
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let url = FileManager.default.temporaryDirectory.appending(path: "yuyue-clone-\(UUID().uuidString).m4a")

    static func allowed() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() {
        discard()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.isMeteringEnabled = true
        guard r.record() else { return }
        recorder = r
        recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        seconds = r.currentTime
        let db = r.averagePower(forChannel: 0)
        levels.append(max(0.08, min(1, (db + 50) / 50)))
        if seconds >= 60 { _ = stop() }
    }

    @discardableResult func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        guard let r = recorder else { return nil }
        seconds = r.currentTime > 0 ? r.currentTime : seconds
        r.stop()
        recorder = nil
        recording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        #endif
        return url
    }

    func discard() {
        _ = stop()
        try? FileManager.default.removeItem(at: url)
        seconds = 0
        levels = []
    }
}
