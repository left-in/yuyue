import AVFoundation
import Foundation
import Speech
import YuyueCore

/// The system's on-device transcriber.
@available(iOS 26, macOS 26, *)
enum Transcriber {
    /// The transcriber's language for a book's.
    static func locale(for language: String) async throws -> Locale {
        for tag in SpokenLanguage.voiceLanguages(for: language) {
            if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: tag)) { return l }
        }
        throw AudiobookError.language(language)
    }

    /// Every word heard in the file, times counted from `offset`. `progress` hears the words so
    /// far and up to where.
    @concurrent static func words(in url: URL, locale: Locale, offset: Double,
                                  progress: @escaping @MainActor ([HeardWord], Double) -> Void) async throws -> [HeardWord] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if await AssetInventory.status(forModules: [transcriber]) < .installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw AudiobookError.model
            }
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let reader = Task {
            var words: [HeardWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { continue }
                    words.append(HeardWord(text: text, start: offset + range.start.seconds, end: offset + range.end.seconds))
                }
                let snapshot = words, through = offset + result.range.end.seconds
                await progress(snapshot, through)
            }
            return words
        }
        try await withTaskCancellationHandler {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        } onCancel: {
            reader.cancel()
        }
        return try await reader.value
    }
}
