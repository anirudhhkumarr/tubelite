import Foundation
import SwiftUI

/// Google YouTube TV OAuth 2.0 Device Flow Service for Apple TV
@MainActor
public class DeviceAuthService: ObservableObject {
    public static let shared = DeviceAuthService()
    
    public static let clientId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    public static let clientSecret = "SboVhoG9s0rNafixCSGGKXAT"
    public static let scope = "https://www.googleapis.com/auth/youtube"
    
    public static let deviceCodeUrl = "https://oauth2.googleapis.com/device/code"
    public static let tokenUrl = "https://oauth2.googleapis.com/token"
    
    @Published public var isSignedIn: Bool = false
    @Published public var userCode: String = ""
    @Published public var verificationUrl: String = "https://www.google.com/device"
    @Published public var isPolling: Bool = false
    @Published public var authError: String? = nil
    @Published public var accessToken: String? = nil
    @Published public var expiresAt: Date? = nil
    
    private var pollTask: Task<Void, Never>? = nil
    private var refreshTask: Task<String?, Never>? = nil
    
    private let tokenKey = "tubelite_ios_access_token"
    private let refreshTokenKey = "tubelite_ios_refresh_token"
    private let expiresAtKey = "tubelite_ios_expires_at"
    private let refreshBufferSec: TimeInterval = 300 // 5-minute buffer matching Web REFRESH_BUFFER_MS
    
    public init() {
        loadSavedSession()
    }
    
    public func loadSavedSession() {
        if let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty {
            self.accessToken = token
            self.isSignedIn = true
            let exp = UserDefaults.standard.double(forKey: expiresAtKey)
            if exp > 0 {
                self.expiresAt = Date(timeIntervalSince1970: exp)
            } else {
                self.expiresAt = nil
            }
        } else {
            self.isSignedIn = false
            self.accessToken = nil
            self.expiresAt = nil
        }
    }
    
    // MARK: - Start Device Code Flow
    
    public func startDeviceAuth() async {
        self.authError = nil
        self.isPolling = true
        self.userCode = ""
        
        guard let url = URL(string: Self.deviceCodeUrl) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyString = "client_id=\(Self.clientId)&scope=\(Self.scope)"
        request.httpBody = bodyString.data(using: .utf8)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let deviceCode = json["device_code"] as? String,
                  let userCode = json["user_code"] as? String else {
                self.authError = "Failed to initiate sign-in"
                self.isPolling = false
                return
            }
            
            self.userCode = userCode
            if let verUrl = json["verification_url"] as? String {
                self.verificationUrl = verUrl
            }
            
            let interval = (json["interval"] as? Double) ?? 5.0
            startPolling(deviceCode: deviceCode, intervalSec: interval)
        } catch {
            self.authError = "Network error: \(error.localizedDescription)"
            self.isPolling = false
        }
    }
    
    // MARK: - Polling for Token
    
    private func startPolling(deviceCode: String, intervalSec: Double) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let startTime = Date()
            var currentInterval = intervalSec
            
            while Date().timeIntervalSince(startTime) < 1800 {
                try? await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
                if Task.isCancelled { return }
                
                guard let self = self else { return }
                
                guard let url = URL(string: Self.tokenUrl) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                
                let bodyString = "client_id=\(Self.clientId)&client_secret=\(Self.clientSecret)&code=\(deviceCode)&grant_type=http://oauth.net/grant_type/device/1.0"
                request.httpBody = bodyString.data(using: .utf8)
                
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    
                    if (response as? HTTPURLResponse)?.statusCode == 200,
                       let accessToken = json["access_token"] as? String {
                        let expiresIn = (json["expires_in"] as? Double) ?? 3600
                        let expiryDate = Date().addingTimeInterval(expiresIn)
                        self.accessToken = accessToken
                        self.expiresAt = expiryDate
                        self.isSignedIn = true
                        self.isPolling = false
                        UserDefaults.standard.set(accessToken, forKey: self.tokenKey)
                        UserDefaults.standard.set(expiryDate.timeIntervalSince1970, forKey: self.expiresAtKey)
                        if let refreshToken = json["refresh_token"] as? String {
                            UserDefaults.standard.set(refreshToken, forKey: self.refreshTokenKey)
                        }
                        return
                    }
                    
                    if let err = json["error"] as? String {
                        if err == "authorization_pending" {
                            continue
                        } else if err == "slow_down" {
                            currentInterval += 2.0
                            continue
                        } else if err == "access_denied" {
                            self.authError = "Sign-in was denied on Google"
                            self.isPolling = false
                            return
                        } else {
                            self.authError = "Sign-in expired or failed: \(err)"
                            self.isPolling = false
                            return
                        }
                    }
                } catch {
                    // Network glitch: continue polling
                    continue
                }
            }
            
            self?.authError = "Sign-in timed out. Please try again."
            self?.isPolling = false
        }
    }
    
    // MARK: - Sign Out
    
    public func signOut() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        self.accessToken = nil
        self.expiresAt = nil
        self.isSignedIn = false
        self.userCode = ""
        self.isPolling = false
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: expiresAtKey)
    }
    
    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
        self.isPolling = false
        self.userCode = ""
    }

    // MARK: - Proactive Token Refresh (Matching Web getValidAccessToken)

    /// Returns a valid access token, silently refreshing via Google OAuth when near expiry (within 5 minutes).
    /// Multiple concurrent callers share the same in-flight refresh Task.
    /// Returns nil and clears session if refresh fails or no credentials exist.
    public func getValidAccessToken() async -> String? {
        guard isSignedIn, let currentToken = accessToken else {
            return nil
        }

        let nearExpiry: Bool
        if let exp = expiresAt {
            nearExpiry = Date().addingTimeInterval(refreshBufferSec) >= exp
        } else {
            // No expiration recorded (e.g. upgraded session) -> refresh if refresh_token exists
            nearExpiry = true
        }

        if !nearExpiry {
            return currentToken
        }

        guard let refreshToken = UserDefaults.standard.string(forKey: refreshTokenKey), !refreshToken.isEmpty else {
            signOut()
            return nil
        }

        if let inFlight = refreshTask {
            return await inFlight.value
        }

        let task = Task<String?, Never> { @MainActor [weak self] in
            guard let self = self else { return nil }
            return await self.performTokenRefresh(refreshToken: refreshToken)
        }
        self.refreshTask = task
        let result = await task.value
        self.refreshTask = nil
        return result
    }

    private func performTokenRefresh(refreshToken: String) async -> String? {
        guard let url = URL(string: Self.tokenUrl) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "client_id=\(Self.clientId)&client_secret=\(Self.clientSecret)&refresh_token=\(refreshToken)&grant_type=refresh_token"
        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpRes = response as? HTTPURLResponse,
                  httpRes.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                print("[TubeLiteTV] Token refresh rejected by server. Clearing session.")
                self.signOut()
                return nil
            }

            let expiresIn = (json["expires_in"] as? Double) ?? 3600
            let expiryDate = Date().addingTimeInterval(expiresIn)

            self.accessToken = newAccessToken
            self.expiresAt = expiryDate
            self.isSignedIn = true

            UserDefaults.standard.set(newAccessToken, forKey: self.tokenKey)
            UserDefaults.standard.set(expiryDate.timeIntervalSince1970, forKey: self.expiresAtKey)
            if let newRefreshToken = json["refresh_token"] as? String, !newRefreshToken.isEmpty {
                UserDefaults.standard.set(newRefreshToken, forKey: self.refreshTokenKey)
            }

            return newAccessToken
        } catch {
            print("[TubeLiteTV] Network error during token refresh: \(error.localizedDescription)")
            if let exp = self.expiresAt, Date() >= exp {
                self.signOut()
                return nil
            }
            return self.accessToken
        }
    }
}
