import Foundation

/// A book whose voice carries on after its pages close: the phone's 播放条 over the tabs, and
/// on the Mac an episode's 播放条 at the bottom of 播客 (the episode's window needn't be open).
protocol NowPlaying: AnyObject {
    var bookID: String { get }
    var player: Player? { get }
    var isPlaying: Bool { get }
    func togglePlay()
    func stopAndClose()
}

extension ReaderModel: NowPlaying {
    func stopAndClose() { close() }
}

extension PdfModel: NowPlaying {
    func stopAndClose() { close() }
}

extension AudiobookPlayer: NowPlaying {
    var player: Player? { nil }
    func stopAndClose() { close() }
}
