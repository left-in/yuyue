import Foundation
import YuyueCore

/// 播客: each host's voice. Kept on this device (voices differ between devices), by show and
/// host name. A host with none chosen gets a voice of their own: the best for the language for
/// the first host, the next best for the second, so the two never sound alike.
enum HostVoices {
    private static func key(show: String, host: String) -> String { "podcast.voice.\(show).\(host)" }

    static func chosen(show: String, host: String) -> (any Voice)? {
        UserDefaults.standard.string(forKey: key(show: show, host: host)).flatMap(Voices.find)
    }

    static func choose(_ voice: any Voice, show: String, host: String) {
        UserDefaults.standard.set(voice.id, forKey: key(show: show, host: host))
    }

    /// The voice reading `host` (the `index`-th) in `language`.
    static func voice(show: String, host: String, index: Int, language: String) -> (any Voice)? {
        if let v = chosen(show: show, host: host), v.speaks(language) { return v }
        let all = SystemVoice.all(for: language)
        guard !all.isEmpty else { return nil }
        // Different speakers where there are, the best of each first.
        var seen = Set<String>()
        let distinct = all.filter { seen.insert($0.name).inserted }
        return distinct[min(index, distinct.count - 1)]
    }
}

extension Player.Script {
    /// An episode: each sentence read by its host's voice; the title and the source lines by
    /// the first host's.
    static func episode(_ core: YuyueCore, _ detail: BookDetail, show: Show) -> Player.Script {
        var script = Player.Script.book(core, detail)
        let id = detail.summary.id
        var speakers: [UInt32: [String?]] = [:]
        let names = show.hosts.map(\.name)
        script.voice = { section, sentence, language in
            if speakers[section] == nil { speakers[section] = (try? core.sectionSpeakers(bookId: id, section: section)) ?? [] }
            let who = speakers[section].flatMap { $0.indices.contains(sentence) ? $0[sentence] : nil } ?? names.first ?? ""
            let index = names.firstIndex(of: who) ?? 0
            return HostVoices.voice(show: show.id, host: who, index: index, language: language)
        }
        return script
    }
}
