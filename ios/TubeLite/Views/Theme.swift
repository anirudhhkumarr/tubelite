import SwiftUI

/// TubeLite iOS design tokens — tailored for mobile touch and high-contrast OLED displays.
public enum TLTheme {
    public static let canvas = Color.black
    public static let surface = Color(white: 0.10)
    public static let surfaceElevated = Color(white: 0.16)
    public static let surfaceBorder = Color(white: 0.22)
    
    public static let textPrimary = Color.white
    public static let textSecondary = Color(white: 0.72)
    public static let textTertiary = Color(white: 0.48)
    
    public static let accent = Color(red: 0.0, green: 0.48, blue: 1.0)
    public static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    public static let success = Color(red: 0.19, green: 0.82, blue: 0.35)
    public static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)
    
    public static let pageInset: CGFloat = 16
    public static let cardGap: CGFloat = 20
    public static let radiusThumb: CGFloat = 12
    public static let radiusCard: CGFloat = 10
    
    public static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

/// Touch button style with subtle opacity press state.
public struct TLBareButtonStyle: ButtonStyle {
    public init() {}
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct TLButton: View {
    public enum Kind { case primary, secondary, danger }
    
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
    
    private var backgroundColor: Color {
        switch kind {
        case .primary: return TLTheme.accent
        case .secondary: return TLTheme.surfaceElevated
        case .danger: return TLTheme.danger
        }
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .clipShape(Capsule())
        }
        .buttonStyle(TLBareButtonStyle())
    }
}

/// Modern minimalist glowing neon Tubelight logo matching the web and tvOS apps.
public struct TLTubelightIcon: View {
    public let width: CGFloat
    public let height: CGFloat
    
    public init(width: CGFloat = 110, height: CGFloat = 11) {
        self.width = width
        self.height = height
    }
    
    public var body: some View {
        ZStack {
            // Ambient Neon Bloom (diffuse background glow)
            Capsule()
                .fill(Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.45))
                .frame(width: width * 0.86, height: height * 1.6)
                .blur(radius: 5)
            
            // Left Connector Pin
            Capsule()
                .fill(Color(red: 0.58, green: 0.64, blue: 0.72))
                .frame(width: max(3.5, width * 0.04), height: max(1.5, height * 0.25))
                .offset(x: -width * 0.48)
            
            // Right Connector Pin
            Capsule()
                .fill(Color(red: 0.58, green: 0.64, blue: 0.72))
                .frame(width: max(3.5, width * 0.04), height: max(1.5, height * 0.25))
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
                .frame(width: max(4, width * 0.045), height: height * 0.92)
                .offset(x: -width * 0.435)
            
            // Right End Cap
            RoundedRectangle(cornerRadius: 1.5)
                .fill(capGradient)
                .frame(width: max(4, width * 0.045), height: height * 0.92)
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
                        .stroke(Color(red: 0.49, green: 0.83, blue: 0.99), lineWidth: 0.7)
                )
                .shadow(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.85), radius: 4, x: 0, y: 0)
                .shadow(color: Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.5), radius: 8, x: 0, y: 0)
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
        VStack(spacing: compact ? 2 : 4) {
            TLTubelightIcon(
                width: compact ? 88 : 110,
                height: compact ? 9 : 11
            )
            
            HStack(spacing: 0) {
                Text("Tube")
                    .foregroundColor(TLTheme.textPrimary)
                Text("Lite")
                    .foregroundColor(TLTheme.accent)
            }
            .font(.system(size: compact ? 18 : 22, weight: .bold))
            .tracking(-0.4)
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
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundColor(TLTheme.textTertiary)
            Text(title)
                .font(.headline)
                .foregroundColor(TLTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundColor(TLTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                TLButton(actionTitle, kind: .secondary, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, TLTheme.pageInset)
    }
}
