import CoreML
import AVFoundation
import Foundation
import YuyueCore

/// 强制对齐 (听书开发方案 §4.2): Meta's MMS alignment model, 8-bit, as Core ML. It turns a
/// recording into how likely each letter is every 20 ms; the core lays the book's words along
/// that. It works on every system the app runs on, unlike the transcriber it replaces.
///
/// The model (about 270 MB) isn't in the app: it's fetched from 语阅's own GitHub release the
/// first time an audiobook is made, checked against its BLAKE3, and kept beside the library.
/// Its licence is CC-BY-NC 4.0 — 语阅 is free and takes no money, and 开源许可 names it.
nonisolated enum Aligner {
    static let file = "MMSAligner.mlmodelc"
    static let url = URL(string: "https://github.com/left-in/yuyue/releases/download/models-1/MMSAligner.mlmodelc.zip")!
    /// BLAKE3 of the zip (`yuyue digest`).
    static let digest = "9d5c22f4dcd6194e8c50fd4a15fd734cb84d8441125935a7c836b8cca7df1465"
    static let bytes: Int64 = 273_668_261
    /// The model's fixed window: 30 s with 2 s either side.
    static let rate = 16_000.0
    static let window = 34 * 16_000
    static let hop = 30 * 16_000
    static let context = 2 * 16_000
    /// The model's letters a frame (`forced::LETTERS`).
    static let letters = 28

    static func folder(_ dataDir: URL) -> URL { dataDir.appending(path: "models", directoryHint: .isDirectory) }

    static func installed(_ dataDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder(dataDir).appending(path: file).path(percentEncoded: false))
    }

    /// Fetched, checked and unpacked unless it's here. `progress` hears 0–1.
    static func ensure(_ dataDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if installed(dataDir) { return }
        let dir = folder(dataDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let free, free < bytes * 3 { throw CocoaError(.fileWriteOutOfSpace) }
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: Progress(progress))
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard try fileDigest(path: temp.path(percentEncoded: false)) == digest else { throw AudiobookError.model }
        let unpack = dir.appending(path: "unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: unpack) }
        try unpackModel(zip: temp.path(percentEncoded: false), to: unpack.path(percentEncoded: false))
        let target = dir.appending(path: file)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: unpack.appending(path: file), to: target)
    }

    private final class Progress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        var observer: NSKeyValueObservation?
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observer = task.progress.observe(\.fractionCompleted) { [report] p, _ in report(p.fractionCompleted) }
        }
    }

    /// The model's output for one file: frames × `LETTERS` log probabilities, row by row, and how
    /// long the file is. `progress` hears seconds done.
    @concurrent static func emissions(_ dataDir: URL, file url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (em: [Float], frames: Int, seconds: Double) {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: folder(dataDir).appending(path: file), configuration: config)
        let wave = try samples(url)
        var em: [Float] = []
        var start = 0
        while start < wave.count {
            try Task.checkCancellation()
            let a = max(0, start - context), b = min(wave.count, start + hop + context)
            var x = Array(wave[a..<b])
            // The layer norm the model was trained with, over the window.
            let mean = x.reduce(0, +) / Float(x.count)
            let variance = x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(x.count)
            let scale = 1 / (variance + 1e-5).squareRoot()
            for i in x.indices { x[i] = (x[i] - mean) * scale }
            let input = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                p.update(repeating: 0)
                for i in x.indices { p[i] = x[i] }
            }
            let out = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["wav": input]))
            guard let e = out.featureValue(for: "emissions")?.multiArrayValue else { throw AudiobookError.model }
            let frames = e.shape[1].intValue, classes = e.shape[2].intValue
            let fps = Double(frames) / (Double(window) / rate)
            let lo = Int((Double(start - a) / rate * fps).rounded())
            let hi = min(frames, lo + Int((Double(min(hop, wave.count - start)) / rate * fps).rounded()))
            // The model gives Float16 (it runs in half precision); read either.
            let s1 = e.strides[1].intValue, s2 = e.strides[2].intValue
            if e.dataType == .float16 {
                e.withUnsafeBufferPointer(ofType: Float16.self) { p in
                    for f in lo..<hi { for c in 0..<classes { em.append(Float(p[f * s1 + c * s2])) } }
                }
            } else {
                e.withUnsafeBufferPointer(ofType: Float.self) { p in
                    for f in lo..<hi { for c in 0..<classes { em.append(p[f * s1 + c * s2]) } }
                }
            }
            start += hop
            progress(Double(min(start, wave.count)) / rate)
        }
        return (em, em.count / letters, Double(wave.count) / rate)
    }

    /// The file's sound, one channel at 16 kHz.
    private static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw AudiobookError.unreadable(url.lastPathComponent) }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * rate) + 1024)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(chunk) * rate / file.processingFormat.sampleRate) + 1024) else { throw AudiobookError.unreadable(url.lastPathComponent) }
        var done = false
        while !done {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                do {
                    try file.read(into: input, frameCount: chunk)
                } catch {
                    state.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let p = output.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(output.frameLength))) }
            done = status == .endOfStream || status == .error
        }
        return out
    }
}
