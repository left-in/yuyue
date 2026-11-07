import Foundation
import Security

/// 连接检查: the server, its certificate, the account, then the folder, one
/// after another. It stops at the first that fails and says how to put it right; the ones after
/// it are marked as not tested, so they don't look broken too.
struct WebDAVCheck: Equatable {
    enum Mark: Equatable { case ok, warn, bad, untested, running }

    struct Step: Equatable, Identifiable {
        var id: Int
        var title: String
        var note = ""
        var mark = Mark.untested
        /// The note is a code (HTTP 401), set in the monospaced face.
        var code = false
    }

    /// How to fix the step that failed: a bold line, then what to do with a path to tap through
    /// in the middle, then maybe a link.
    struct Fix: Equatable {
        var headline: String
        var before: String
        var path: String?
        var after = ""
        var link: String?
        var url: URL?
    }

    var steps: [Step] = [
        Step(id: 0, title: String(localized: "能连上服务器")),
        Step(id: 1, title: String(localized: "证书有效")),
        Step(id: 2, title: String(localized: "账号和密码对")),
        Step(id: 3, title: String(localized: "文件夹能读写")),
    ]
    /// After which step the fix goes.
    var fixAfter: Int?
    var fix: Fix?
    var finished: Date?
    var took: Duration = .zero

    var passed: Bool { finished != nil && !steps.contains { $0.mark == .bad } }
    var failed: Bool { steps.contains { $0.mark == .bad } }

    /// Runs the four steps against `account`, reporting each as it lands.
    static func run(_ account: Sync.WebDAVAccount, update: (WebDAVCheck) -> Void) async -> WebDAVCheck {
        var c = WebDAVCheck()
        let clock = ContinuousClock()
        let started = clock.now
        let folder = WebDAVFolder(account)
        let host = account.url.host() ?? ""
        let jianguo = host.contains("jianguoyun")

        func done() -> WebDAVCheck {
            c.finished = Date()
            c.took = clock.now - started
            update(c)
            return c
        }
        func stop(at i: Int, _ title: String, _ note: String, code: Bool = false, _ fix: Fix) -> WebDAVCheck {
            c.steps[i].title = title
            c.steps[i].note = note
            c.steps[i].mark = .bad
            c.steps[i].code = code
            c.fixAfter = i
            c.fix = fix
            for j in (i + 1) ..< c.steps.count {
                c.steps[j].note = i == 0 ? String(localized: "没测，要先连上") : i == 2 ? String(localized: "没测，要先登录") : String(localized: "没测")
            }
            return done()
        }

        // 1 and 2: reach it at all, and see its certificate on the way.
        c.steps[0].mark = .running
        update(c)
        let peek = TrustPeek()
        var probe = URLRequest(url: account.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        probe.httpMethod = "OPTIONS"
        let t0 = clock.now
        do {
            _ = try await URLSession.shared.data(for: probe, delegate: peek)
        } catch let e as URLError where Self.certificateCodes.contains(e.code) {
            c.steps[0].mark = .ok
            c.steps[0].note = "\(Self.ms(clock.now - t0)) ms"
            return stop(at: 1, String(localized: "证书不受信任"), e.code == .serverCertificateHasBadDate ? String(localized: "已经过期") : e.code == .serverCertificateNotYetValid ? String(localized: "还没生效") : String(localized: "自签名或来路不明"),
                        Fix(headline: String(localized: "语阅只连证书可信的服务器。"),
                            before: String(localized: "群晖、Nextcloud 这类自己搭的服务器，装一张正经的证书（比如 Let's Encrypt 的免费证书）再试。")))
        } catch let e as URLError {
            let (title, note): (String, String) = switch e.code {
            case .notConnectedToInternet: (String(localized: "没有联网"), "")
            case .timedOut: (String(localized: "连不上服务器"), String(localized: "超时"))
            case .cannotFindHost, .dnsLookupFailed: (String(localized: "找不到这个服务器"), host)
            default: (String(localized: "连不上服务器"), "")
            }
            return stop(at: 0, title, note, Fix(
                headline: e.code == .notConnectedToInternet ? String(localized: "联上网再试。") : String(localized: "看看地址对不对。"),
                before: String(localized: "坚果云填 "), path: "https://dav.jianguoyun.com/dav/",
                after: String(localized: "；群晖和 Nextcloud 填自己服务器的地址，出门在外要用外网能到的那个。")))
        } catch {
            return stop(at: 0, String(localized: "连不上服务器"), "", Fix(headline: String(localized: "看看地址对不对。"), before: Library.message(for: error)))
        }
        c.steps[0].mark = .ok
        c.steps[0].note = "\(Self.ms(clock.now - t0)) ms"
        if account.url.scheme == "http" {
            c.steps[1].title = String(localized: "没有加密")
            c.steps[1].note = String(localized: "http，密码明着传")
            c.steps[1].mark = .warn
        } else {
            c.steps[1].mark = .ok
            c.steps[1].note = peek.expiry.map { String(localized: "到 \(Calendar.current.component(.year, from: $0)) 年 \(Calendar.current.component(.month, from: $0)) 月") } ?? String(localized: "已验证")
        }
        c.steps[2].mark = .running
        update(c)

        // 3: the account.
        var login = folder.request(account.url, "PROPFIND")
        login.setValue("0", forHTTPHeaderField: "Depth")
        login.timeoutInterval = 20
        let code: Int
        do {
            let (_, response) = try await URLSession.shared.data(for: login)
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return stop(at: 2, String(localized: "登录时断了"), Sync.message(for: error), Fix(headline: String(localized: "网络不稳，再试一次。"), before: ""))
        }
        switch code {
        case 200 ..< 300:
            c.steps[2].mark = .ok
            c.steps[2].note = account.user
        case 401, 403:
            return stop(at: 2, String(localized: "账号或密码不对"), "HTTP \(code)", code: true, jianguo
                ? Fix(headline: String(localized: "坚果云要用应用密码，不是登录密码。"),
                      before: String(localized: "在网页版打开 "), path: String(localized: "账户信息 › 安全选项 › 第三方应用管理"),
                      after: String(localized: "，添加一个应用，把生成的密码粘贴到上面。"),
                      link: String(localized: "打开坚果云网页版"), url: URL(string: "https://www.jianguoyun.com/d/account#safe"))
                : Fix(headline: String(localized: "再核对一遍账号和密码。"),
                      before: String(localized: "开了两步验证的服务（Nextcloud、群晖）要建一个"), path: String(localized: "应用密码"), after: String(localized: "来填，不能用登录密码。")))
        case 404, 405:
            return stop(at: 2, String(localized: "服务器上没有这个地址"), "HTTP \(code)", code: true, Fix(
                headline: String(localized: "地址最后那段多半不对。"),
                before: String(localized: "坚果云是 …/dav/，Nextcloud 是 "), path: String(localized: "…/remote.php/dav/files/你的账号/"),
                after: String(localized: "，群晖要先在套件中心装好 WebDAV Server。")))
        default:
            return stop(at: 2, String(localized: "服务器回了 \(code)"), "HTTP \(code)", code: true, Fix(headline: String(localized: "服务器那边出了问题。"), before: String(localized: "过一会儿再试；一直这样的话，看看服务器的日志。")))
        }
        c.steps[3].mark = .running
        update(c)

        // 4: make the folder, write a file into it, take it away again.
        do {
            try await folder.prepare()
            let name = ".yuyue-check-\(UUID().uuidString.prefix(8))"
            try await folder.write(name, Data("ok".utf8))
            _ = try? await URLSession.shared.data(for: folder.request(folder.dir.appending(path: name), "DELETE"))
        } catch SyncError.status(let code) {
            return stop(at: 3, code == 507 ? String(localized: "网盘满了") : String(localized: "文件夹写不进去"), "HTTP \(code)", code: true, Fix(
                headline: code == 507 ? String(localized: "腾出点空间再试。") : String(localized: "这个账号对这个文件夹没有写的权限。"),
                before: code == 507 ? String(localized: "语阅只放几个很小的同步文件，有几百 KB 就够。") : String(localized: "换一个能写的文件夹，或者在网盘那边给这个账号开写的权限。")))
        } catch {
            return stop(at: 3, String(localized: "文件夹写不进去"), Sync.message(for: error), Fix(headline: String(localized: "网络不稳，再试一次。"), before: ""))
        }
        c.steps[3].mark = .ok
        c.steps[3].note = "/" + account.folder.split(separator: "/").joined(separator: "/")
        return done()
    }

    private static let certificateCodes: Set<URLError.Code> = [
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .secureConnectionFailed,
    ]

    private static func ms(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Looks at the server's certificate as it goes by, leaving the system to judge it.
private final class TrustPeek: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var notAfter: Date?

    var expiry: Date? { lock.withLock { notAfter } }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            let date = Self.notAfter(leaf)
            lock.withLock { notAfter = date }
        }
        return (.performDefaultHandling, nil)
    }

    nonisolated private static func notAfter(_ cert: SecCertificate) -> Date? {
        #if os(macOS)
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(cert, keys, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let n = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: n.doubleValue)
        #else
        return nil
        #endif
    }
}
