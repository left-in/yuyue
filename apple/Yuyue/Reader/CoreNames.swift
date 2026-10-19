import YuyueCore

// SwiftUI has a `Font` too, and `YuyueCore.Font` can't disambiguate it: inside the app,
// `YuyueCore` names the core's class, not its module. This file sees only the core's.
typealias ReaderFont = Font
// Foundation has a `Progress` too.
typealias ReadingProgress = Progress
