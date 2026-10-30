import AuthenticationServices
import CryptoKit
import Foundation
import Network
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 用 OpenRouter 登录: OpenRouter's sign-in for apps (PKCE, openrouter.ai/docs/guides/overview/auth/oauth).
/// Its page runs in the system's sign-in sheet and sends the browser back to
/// `http://localhost:<port>/callback?code=…`, which a listener here answers; the code, with the
/// verifier only this run knows, is traded for a key of the user's own. OpenRouter documents
/// localhost callbacks on any port, not custom schemes, hence the listener.
@MainActor
final class OpenRouterSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var waiting: CheckedContinuation<String, Error>?

    enum Failure: LocalizedError {
        case cancelled, refused

        var errorDescription: String? {
            switch self {
            case .cancelled: String(localized: "没有登录")
            case .refused: String(localized: "OpenRouter 没给 Key，再登录一次")
            }
        }
    }

    /// Signs in and returns the new key.
    func run() async throws -> String {
        let verifier = Self.base64URL(Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        let code = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            waiting = c
            do {
                try listen(state: state) { [weak self] port in
                    self?.present(port: port, challenge: challenge, state: state)
                }
            } catch {
                finish(.failure(error))
            }
        }
        return try await exchange(code: code, verifier: verifier)
    }

    private func listen(state: String, ready: @escaping @MainActor (UInt16) -> Void) throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                switch s {
                case .ready: if let port = listener.port?.rawValue { ready(port) }
                case .failed(let e): self?.finish(.failure(e))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.answer(connection, state: state) }
        }
        listener.start(queue: .main)
    }

    /// Reads the browser's GET, says it worked, and takes the code out of it.
    private func answer(_ connection: NWConnection, state: String) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://localhost" + target)?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let ok = code != nil && items.first { $0.name == "state" }?.value == state
                let page = ok ? String(localized: "已经登录 OpenRouter，可以回到语阅了。") : String(localized: "没有登录成功，回到语阅再试一次。")
                let body = Data("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><body style='font:16px -apple-system,sans-serif;padding:48px 24px;text-align:center'>\(page)".utf8)
                let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: head + body, completion: .contentProcessed { _ in connection.cancel() })
                guard target.hasPrefix("/callback") else { return }
                if ok, let code { self?.finish(.success(code)) } else { self?.finish(.failure(Failure.refused)) }
            }
        }
    }

    private func present(port: UInt16, challenge: String, state: String) {
        var url = URLComponents(string: "https://openrouter.ai/auth")!
        url.queryItems = [
            .init(name: "callback_url", value: "http://localhost:\(port)/callback"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "key_label", value: String(localized: "语阅 · 书伴")),
        ]
        // The page's redirect never reaches a scheme of ours; the listener ends it instead.
        let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "yuyue-openrouter") { [weak self] _, error in
            MainActor.assumeIsolated {
                if error != nil { self?.finish(.failure(Failure.cancelled)) }
            }
        }
        session.presentationContextProvider = self
        self.session = session
        if !session.start() { finish(.failure(Failure.cancelled)) }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let waiting else { return }
        self.waiting = nil
        listener?.cancel()
        listener = nil
        session?.cancel()
        session = nil
        waiting.resume(with: result)
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        let (data, response) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let key = json?["key"] as? String, !key.isEmpty else { throw Failure.refused }
        return key
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
            #else
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
