import SwiftUI
import UIKit

/// Mobile Google OAuth pairing and account management screen.
public struct AccountView: View {
    @ObservedObject private var auth = DeviceAuthService.shared
    @State private var didStart = false
    @State private var copiedCode = false
    public let isActive: Bool
    
    public init(isActive: Bool = true) {
        self.isActive = isActive
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    TLBrandMark()
                        .padding(.top, 24)
                    
                    if auth.isSignedIn {
                        signedInView
                    } else {
                        signedOutView
                    }
                }
                .padding(.horizontal, TLTheme.pageInset)
                .padding(.bottom, 40)
            }
            .background(TLTheme.canvas.ignoresSafeArea())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TLTheme.canvas, for: .navigationBar)
        }
        .task(id: isActive) {
            if isActive && !auth.isSignedIn && !didStart {
                didStart = true
                await auth.startDeviceAuth()
            } else if !isActive {
                didStart = false
                auth.cancel()
            }
        }
    }
    
    private var signedInView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(TLTheme.success)
            
            Text("Signed in to YouTube")
                .font(.title3.weight(.bold))
                .foregroundColor(TLTheme.textPrimary)
            
            Text("Your home feed is personalized with recommendations and subscription updates.")
                .font(.subheadline)
                .foregroundColor(TLTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            TLButton("Sign Out", kind: .danger, systemImage: "rectangle.portrait.and.arrow.right") {
                auth.signOut()
                didStart = false
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(TLTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: TLTheme.radiusCard, style: .continuous))
    }
    
    private var signedOutView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Sign in with Google")
                    .font(.title3.weight(.bold))
                    .foregroundColor(TLTheme.textPrimary)
                
                Text("Enter this code to access your subscriptions and personalized recommendations:")
                    .font(.subheadline)
                    .foregroundColor(TLTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            
            if auth.userCode.isEmpty {
                ProgressView("Generating pairing code…")
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 12) {
                    Text(auth.userCode)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .tracking(6)
                        .foregroundColor(TLTheme.textPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .background(TLTheme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = auth.userCode
                            let generator = UINotificationFeedbackGenerator()
                            generator.notificationOccurred(.success)
                            withAnimation {
                                copiedCode = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                copiedCode = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                                Text(copiedCode ? "Copied" : "Copy Code")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(TLTheme.surfaceElevated)
                            .clipShape(Capsule())
                        }
                        
                        if let url = URL(string: auth.verificationUrl) {
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                    Text("Open Google")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(TLTheme.accent)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            
            if auth.isPolling {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Waiting for authorization…")
                        .font(.caption)
                        .foregroundColor(TLTheme.textSecondary)
                }
                .padding(.top, 4)
            }
            
            if let error = auth.authError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(TLTheme.danger)
                        .multilineTextAlignment(.center)
                    
                    TLButton("Try Again", kind: .secondary, systemImage: "arrow.clockwise") {
                        Task { await auth.startDeviceAuth() }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(TLTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: TLTheme.radiusCard, style: .continuous))
    }
}
