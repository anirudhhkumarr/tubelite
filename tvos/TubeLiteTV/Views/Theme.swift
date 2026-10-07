import SwiftUI

/// Apple TV design tokens — compact type for 10-foot UI without oversized headings.
public enum TLTheme {
    public static let canvas = Color.black
    public static let surface = Color(white: 0.08)
    public static let surfaceElevated = Color(white: 0.12)
    
    public static let textPrimary = Color.white
    public static let textSecondary = Color(white: 0.72)
    public static let textTertiary = Color(white: 0.48)
    
    public static let accent = Color(red: 0.0, green: 0.48, blue: 1.0)
    public static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    public static let success = Color(red: 0.19, green: 0.82, blue: 0.35)
    public static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)
    
    public static let pageInset: CGFloat = 60
    public static let gridColumns = 3
    public static let gridGap: CGFloat = 32
    public static let cardSpacing: CGFloat = 28
    /// Horizontal “up next” tray — same card scale as the 3-up home grid.
    public static let trayCardWidth: CGFloat = 560
    public static let trayThumbHeight: CGFloat = trayCardWidth * 9 / 16
    public static let relatedCardWidth: CGFloat = trayCardWidth
    public static let relatedThumbHeight: CGFloat = trayThumbHeight
    public static let relatedMetaHeight: CGFloat = 100
    /// Shared meta block height so home + tray cards stay aligned in a row.
    public static let cardMetaHeight: CGFloat = 118
    
    public static let radiusThumb: CGFloat = 10
    public static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

public extension View {
    /// Kill the system white focus glow/halo; callers draw their own ring.
    func tlNoSystemFocus() -> some View {
        self.focusEffectDisabled(true)
    }
}

/// Neutral button style — no tvOS card chrome / white focus plate.
public struct TLBareButtonStyle: ButtonStyle {
    public init() {}
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

public struct TLButton: View {
    public enum Kind { case primary, secondary }
    
    let title: String
    let kind: Kind
    let systemImage: String?
    let action: () -> Void
    
    public init(
        _ title: String,
        kind: Kind = .primary,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.systemImage = systemImage
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.callout.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(kind == .primary ? TLTheme.accent : TLTheme.surfaceElevated)
    }
}

/// Modern minimalist glowing neon Tubelight logo matching the web app.
public struct TLTubelightIcon: View {
    public let width: CGFloat
    public let height: CGFloat
    
    public init(width: CGFloat = 126, height: CGFloat = 13) {
        self.width = width
        self.height = height
    }
    
    public var body: some View {
        ZStack {
            // Ambient Neon Bloom (diffuse background glow)
            Capsule()
                .fill(Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.42))
                .frame(width: width * 0.86, height: height * 1.6)
                .blur(radius: 6)
            
            // Left Connector Pin
            Capsule()
                .fill(Color(red: 0.58, green: 0.64, blue: 0.72))
                .frame(width: max(4, width * 0.04), height: max(1.5, height * 0.25))
                .offset(x: -width * 0.48)
            
            // Right Connector Pin
            Capsule()
                .fill(Color(red: 0.58, green: 0.64, blue: 0.72))
                .frame(width: max(4, width * 0.04), height: max(1.5, height * 0.25))
                .offset(x: width * 0.48)
            
            // Metallic End Caps
            let capGradient = LinearGradient(
                colors: [
                    Color(red: 0.70, green: 0.75, blue: 0.82),
                    Color(red: 0.32, green: 0.37, blue: 0.45)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Left End Cap
            RoundedRectangle(cornerRadius: 1.5)
                .fill(capGradient)
                .frame(width: max(4.5, width * 0.045), height: height * 0.92)
                .offset(x: -width * 0.435)
            
            // Right End Cap
            RoundedRectangle(cornerRadius: 1.5)
                .fill(capGradient)
                .frame(width: max(4.5, width * 0.045), height: height * 0.92)
                .offset(x: width * 0.435)
            
            // Luminescent Glass Tube Body
            let tubeGradient = LinearGradient(
                stops: [
                    .init(color: Color(red: 0.01, green: 0.52, blue: 0.78).opacity(0.85), location: 0.0),
                    .init(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.95), location: 0.16),
                    .init(color: Color.white, location: 0.5),
                    .init(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.95), location: 0.84),
                    .init(color: Color(red: 0.01, green: 0.52, blue: 0.78).opacity(0.85), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            
            Capsule()
                .fill(tubeGradient)
                .overlay(
                    Capsule()
                        .stroke(Color(red: 0.49, green: 0.83, blue: 0.99), lineWidth: 0.8)
                )
                .shadow(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.85), radius: 5, x: 0, y: 0)
                .shadow(color: Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.5), radius: 10, x: 0, y: 0)
                .frame(width: width * 0.82, height: height * 0.80)
            
            // Central Phosphor Filament Beam
            Capsule()
                .fill(Color.white)
                .frame(width: width * 0.68, height: max(1.5, height * 0.18))
            
            // Specular Glaze Highlight (top sheen)
            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: width * 0.70, height: max(0.8, height * 0.10))
                .offset(y: -height * 0.22)
        }
        .frame(width: width, height: height)
    }
}

public struct TLBrandMark: View {
    var compact: Bool = false
    
    public init(compact: Bool = false) {
        self.compact = compact
    }
    
    public var body: some View {
        VStack(spacing: compact ? 3 : 5) {
            // Tubelight on top, stretching across the brand text below
            TLTubelightIcon(
                width: compact ? 100 : 126,
                height: compact ? 10 : 13
            )
            
            HStack(spacing: 0) {
                Text("Tube")
                    .foregroundColor(TLTheme.textPrimary)
                Text("Lite")
                    .foregroundColor(TLTheme.accent)
            }
            .font(.system(size: compact ? 22 : 28, weight: .bold))
            .tracking(-0.5)
        }
        .accessibilityLabel("TubeLite")
    }
}

public struct TLEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    
    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .medium))
                .foregroundColor(TLTheme.textTertiary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundColor(TLTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundColor(TLTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
            if let actionTitle, let action {
                TLButton(actionTitle, kind: .secondary, action: action)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .padding(.horizontal, TLTheme.pageInset)
    }
}
