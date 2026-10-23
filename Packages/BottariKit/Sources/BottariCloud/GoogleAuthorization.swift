@preconcurrency import AppAuth
import AppKit
import Foundation

/// Signs in to Google in the browser (loopback redirect and PKCE, through
/// AppAuth) with the user's own OAuth client, and keeps the tokens fresh.
/// The state archives to `Data` for the Keychain.
public final class GoogleAuthorization: AccessTokenSource, @unchecked Sendable {
    private let state: OIDAuthState
    private let lock = NSLock()

    static let scopes = ["openid", "email", "https://www.googleapis.com/auth/drive"]
    static var configuration: OIDServiceConfiguration {
        OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
    }

    private init(state: OIDAuthState) {
        self.state = state
    }

    /// Restores a sign-in saved with `archived`.
    public convenience init(archived: Data) throws {
        guard let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archived) else {
            throw GoogleSignInError("저장된 Google 로그인을 읽지 못했어요. 다시 로그인해 주세요.")
        }
        self.init(state: state)
    }

    public var archived: Data {
        lock.withLock { (try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)) ?? Data() }
    }

    /// The account's email, from the ID token.
    public var account: String {
        lock.withLock {
            guard let token = state.lastTokenResponse?.idToken ?? state.lastAuthorizationResponse.idToken else { return "" }
            let parts = token.split(separator: ".")
            guard parts.count > 1 else { return "" }
            var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload),
                  let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return "" }
            return claims["email"] as? String ?? ""
        }
    }

    /// Opens Google's sign-in page and waits for the user to finish there.
    @MainActor
    public static func signIn(clientID: String, clientSecret: String?, presentingWindow: NSWindow) async throws -> GoogleAuthorization {
        let listener = OIDRedirectHTTPHandler(successURL: nil)
        var listenError: NSError?
        let redirect = listener.startHTTPListener(&listenError)
        if let listenError { throw listenError }
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientID,
            clientSecret: clientSecret?.isEmpty == false ? clientSecret : nil,
            scopes: scopes,
            redirectURL: redirect,
            responseType: OIDResponseTypeCode,
            // A refresh token every time, so the sign-in lasts.
            additionalParameters: ["access_type": "offline", "prompt": "consent"]
        )
        return try await withCheckedThrowingContinuation { continuation in
            listener.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: presentingWindow) { state, error in
                listener.cancelHTTPListener()
                if let state {
                    continuation.resume(returning: GoogleAuthorization(state: state))
                } else {
                    continuation.resume(throwing: error ?? GoogleSignInError("Google 로그인을 마치지 못했어요"))
                }
            }
        }
    }

    public func accessToken() async throws -> String {
        let state = lock.withLock { self.state }
        return try await withCheckedThrowingContinuation { continuation in
            state.performAction { token, _, error in
                if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: error ?? GoogleSignInError("Google 토큰을 새로 받지 못했어요. 다시 로그인해 주세요."))
                }
            }
        }
    }
}

public struct GoogleSignInError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
