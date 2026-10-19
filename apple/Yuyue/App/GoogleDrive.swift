import AuthenticationServices
import CryptoKit
import Foundation

/// 同步 · Google Drive: the devices' files in the app's own hidden folder on the user's Drive
/// (`appDataFolder`), which only 语阅 can see. Signing in happens once, in the system's sheet;
/// the refresh token is kept in the Keychain and nothing else about the account is stored but
/// its address, to show.
enum GoogleAuth {
    /// Set when 语阅 is registered with Google: an iOS client in its Cloud project, put in the
    /// build as `GOOGLE_CLIENT_ID`. Android signs in under the same project, so both see the
    /// same hidden folder. Until then 同步 · Google Drive says it isn't open yet.
    static let clientID: String? = {
        let id = (Bundle.main.object(forInfoDictionaryKey: "YYGoogleClientID") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.hasSuffix(".apps.googleusercontent.com") ? id : nil
    }()

    /// The client's id reversed, which Google sends the sign-in back to.
    static var scheme: String? {
        clientID.map { "com.googleusercontent.apps." + $0.replacingOccurrences(of: ".apps.googleusercontent.com", with: "") }
    }

    static let scope = "https://www.googleapis.com/auth/drive.appdata"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// Opens Google's page in the system's sign-in sheet (`authenticate`, from SwiftUI's
    /// `webAuthenticationSession`) and trades what comes back for a refresh token.
    static func signIn(authenticate: (URL, String) async throws -> URL) async throws -> String {
        guard let clientID, let scheme else { throw SyncError.notRegistered }
        let verifier = random(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = random(16)
        let redirect = "\(scheme):/oauth2redirect"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Asked every time: the refresh token comes only with consent.
            .init(name: "prompt", value: "consent"),
            .init(name: "access_type", value: "offline"),
        ]
        let back = try await authenticate(c.url!, scheme)
        let items = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw SyncError.signInFailed }
        if items.contains(where: { $0.name == "error" }) { throw CancellationError() }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw SyncError.signInFailed }
        let reply = try await token([
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        guard let refresh = reply.refresh_token else { throw SyncError.signInFailed }
        DriveSession.shared.took(reply)
        return refresh
    }

    /// A fresh access token for the kept refresh token.
    static func refresh(_ refreshToken: String) async throws -> TokenReply {
        guard let clientID else { throw SyncError.notRegistered }
        do {
            return try await token(["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"])
        } catch SyncError.status(400), SyncError.status(401) {
            // Taken back in the Google account, or expired.
            throw SyncError.signedOut
        }
    }

    struct TokenReply: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private static func token(_ form: [String: String]) async throws -> TokenReply {
        var r = URLRequest(url: tokenURL)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SyncError.status(status) }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }

    private static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

/// The access token in hand, and which Drive file is which.
final class DriveSession {
    static let shared = DriveSession()
    private var access: String?
    private var expires = Date.distantPast
    var ids: [String: String] = [:]

    func took(_ reply: GoogleAuth.TokenReply) {
        access = reply.access_token
        expires = Date().addingTimeInterval(reply.expires_in - 60)
    }

    func forget() {
        access = nil
        expires = .distantPast
        ids = [:]
    }

    func token(force: Bool = false) async throws -> String {
        if !force, let access, Date() < expires { return access }
        guard let refresh = Keychain.read(Sync.googleRefreshKey) else { throw SyncError.signedOut }
        let reply = try await GoogleAuth.refresh(refresh)
        took(reply)
        return reply.access_token
    }
}

struct GoogleDriveFolder: SyncFolder {
    private static let api = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let upload = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    private var session: DriveSession { DriveSession.shared }

    func prepare() async throws {
        _ = try await session.token()
    }

    func list() async throws -> [String: String] {
        struct Files: Decodable {
            struct File: Decodable { let id: String; let name: String; let md5Checksum: String?; let modifiedTime: String? }
            let files: [File]
            let nextPageToken: String?
        }
        var out: [String: String] = [:]
        var ids: [String: String] = [:]
        var page: String?
        repeat {
            var c = URLComponents(url: Self.api, resolvingAgainstBaseURL: false)!
            c.queryItems = [
                .init(name: "spaces", value: "appDataFolder"),
                .init(name: "fields", value: "nextPageToken,files(id,name,md5Checksum,modifiedTime)"),
                .init(name: "pageSize", value: "1000"),
            ] + (page.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let files = try JSONDecoder().decode(Files.self, from: try await send(URLRequest(url: c.url!)))
            for f in files.files {
                ids[f.name] = f.id
                out[f.name] = f.md5Checksum ?? f.modifiedTime ?? f.id
            }
            page = files.nextPageToken
        } while page != nil
        session.ids = ids
        return out
    }

    func read(_ name: String) async throws -> Data {
        if session.ids[name] == nil { _ = try await list() }
        guard let id = session.ids[name] else { throw SyncError.status(404) }
        var c = URLComponents(url: Self.api.appending(path: id), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "alt", value: "media")]
        return try await send(URLRequest(url: c.url!))
    }

    func write(_ name: String, _ data: Data) async throws {
        if let id = session.ids[name] {
            var r = URLRequest(url: URL(string: Self.upload.appending(path: id).absoluteString + "?uploadType=media")!)
            r.httpMethod = "PATCH"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = data
            _ = try await send(r)
            return
        }
        // New: the name and the hidden folder, then the content, in one request.
        let boundary = "yuyue-\(UUID().uuidString)"
        let meta = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]])
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += meta
        body += Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8)
        body += data
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        var r = URLRequest(url: URL(string: Self.upload.absoluteString + "?uploadType=multipart&fields=id")!)
        r.httpMethod = "POST"
        r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        struct Made: Decodable { let id: String }
        session.ids[name] = try JSONDecoder().decode(Made.self, from: try await send(r)).id
    }

    /// 书文件 and recordings: a resumable upload (Google takes only small files in one go), the
    /// name and the hidden folder first when the file is new, then the content straight from disk.
    func upload(_ name: String, from file: URL) async throws {
        if session.ids[name] == nil { _ = try await list() }
        let type = Self.type(of: name)
        var r: URLRequest
        if let id = session.ids[name] {
            r = URLRequest(url: URL(string: Self.upload.appending(path: id).absoluteString + "?uploadType=resumable")!)
            r.httpMethod = "PATCH"
        } else {
            r = URLRequest(url: URL(string: Self.upload.absoluteString + "?uploadType=resumable&fields=id")!)
            r.httpMethod = "POST"
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]])
        }
        r.setValue(type, forHTTPHeaderField: "X-Upload-Content-Type")
        let (_, response) = try await authorized(r)
        guard let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw SyncError.status(response.statusCode)
        }
        var put = URLRequest(url: url, timeoutInterval: 600)
        put.httpMethod = "PUT"
        put.setValue(type, forHTTPHeaderField: "Content-Type")
        let (data, done) = try await URLSession.shared.upload(for: put, fromFile: file)
        let status = (done as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SyncError.status(status) }
        struct Made: Decodable { let id: String }
        if let made = try? JSONDecoder().decode(Made.self, from: data) { session.ids[name] = made.id }
    }

    func download(_ name: String, to file: URL) async throws {
        if session.ids[name] == nil { _ = try await list() }
        guard let id = session.ids[name] else { throw SyncError.status(404) }
        var c = URLComponents(url: Self.api.appending(path: id), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "alt", value: "media")]
        var r = URLRequest(url: c.url!, timeoutInterval: 600)
        for attempt in 0..<2 {
            r.setValue("Bearer \(try await session.token(force: attempt > 0))", forHTTPHeaderField: "Authorization")
            let (temp, response) = try await URLSession.shared.download(for: r)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { try? FileManager.default.removeItem(at: temp); continue }
            guard (200..<300).contains(status) else { try? FileManager.default.removeItem(at: temp); throw SyncError.status(status) }
            try Self.place(temp, at: file)
            return
        }
        throw SyncError.signedOut
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try await authorized(request).0
    }

    /// With the access token; once more with a new one if Google says it has run out.
    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var r = request
        r.timeoutInterval = 60
        for attempt in 0..<2 {
            r.setValue("Bearer \(try await session.token(force: attempt > 0))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: r)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(status) else { throw SyncError.status(status) }
            return (data, http)
        }
        throw SyncError.signedOut
    }

    /// The account's address, to show under 同步方式.
    func email() async -> String? {
        struct About: Decodable { struct User: Decodable { let emailAddress: String? }; let user: User }
        guard let data = try? await send(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!)) else { return nil }
        return (try? JSONDecoder().decode(About.self, from: data))?.user.emailAddress
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
