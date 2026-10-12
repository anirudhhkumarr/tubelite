import SwiftUI
import UIKit

/// Glassy matte slightly translucent background along the top row with vertical fade to full transparency.
/// Sized to cover the full Dynamic Island section, finishing smoothly at the bottom of the island section
/// without overlapping the top feed video.
public struct TLGlassyTopRowBackground: View {
    public let height: CGFloat?
    
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    public init(height: CGFloat? = nil) {
        self.height = height
    }
    
    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }
    
    private var resolvedHeight: CGFloat {
        height ?? TLScreenMetrics.symmetricTopPadding()
    }
    
    public var body: some View {
        if isLandscape {
            EmptyView()
        } else {
            ZStack(alignment: .top) {
                // 1. Apple Liquid Glass Material: Ultra-thin real-time optical blur with smooth continuous fade
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.88), location: 0.0),
                                .init(color: .black.opacity(0.78), location: 0.20),
                                .init(color: .black.opacity(0.58), location: 0.45),
                                .init(color: .black.opacity(0.36), location: 0.68),
                                .init(color: .black.opacity(0.16), location: 0.86),
                                .init(color: .black.opacity(0.04), location: 0.96),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                
                // 2. Liquid Glass Specular Meniscus Highlight (Apple-style luminous surface sheen, not grey)
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.14), location: 0.0),
                        .init(color: Color.white.opacity(0.05), location: 0.20),
                        .init(color: Color.white.opacity(0.01), location: 0.45),
                        .init(color: .clear, location: 0.70)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                // 3. Featherlight ambient depth gradient (ultra-soft, preserves status bar legibility without grey mud)
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.15), location: 0.0),
                        .init(color: Color.black.opacity(0.08), location: 0.30),
                        .init(color: Color.black.opacity(0.02), location: 0.65),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: resolvedHeight)
            .allowsHitTesting(false)
            .ignoresSafeArea(.all, edges: .top)
        }
    }
}

/// Renders a pulsing neon light aura contouring the iPhone Dynamic Island hardware pill
/// together with a glassy matte slightly translucent background across the top row fading to full transparency.
public struct DynamicIslandAuraView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    public init() {}
    
    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }
    
    public var body: some View {
        if isLandscape {
            EmptyView()
        } else {
            let topInset = TLScreenMetrics.topSafeAreaInset
            let hasDynamicIsland = TLScreenMetrics.hasDynamicIsland(topInset: topInset)
            let symmetricGlassHeight = TLScreenMetrics.symmetricTopPadding(topInset: topInset)
            let islandCenterY = TLScreenMetrics.islandCenterY(topInset: topInset)
            let islandWidth = TLScreenMetrics.islandWidth
            let islandHeight = TLScreenMetrics.islandHeight
            
            ZStack(alignment: .top) {
                // Glassy matte slightly translucent background along the top row with fade to full transparency
                TLGlassyTopRowBackground(height: symmetricGlassHeight)
                
                // Dynamic Island Neon Aura around the hardware pill
                if hasDynamicIsland {
                    let topSectionHeight = symmetricGlassHeight
                    
                    ZStack {
                        // 1. Wide subtle horizontal dissipation across the frosted glass top row
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color(red: 0.15, green: 0.65, blue: 1.0).opacity(0.24), location: 0.0),
                                .init(color: Color(red: 0.08, green: 0.50, blue: 0.95).opacity(0.14), location: 0.40),
                                .init(color: Color(red: 0.02, green: 0.35, blue: 0.80).opacity(0.04), location: 0.75),
                                .init(color: Color.clear, location: 1.0)
                            ]),
                            center: .center,
                            startRadius: islandWidth * 0.25,
                            endRadius: 180
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: topSectionHeight)
                        .blur(radius: 12)
                        
                        // 2. Mid-range tube light bloom dissipating outward from the cutout
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.05, green: 0.45, blue: 0.95).opacity(0.08),
                                        Color(red: 0.18, green: 0.70, blue: 1.0).opacity(0.30),
                                        Color(red: 0.05, green: 0.45, blue: 0.95).opacity(0.08)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: islandWidth + 56, height: islandHeight + 18)
                            .blur(radius: 10)
                            .offset(y: islandCenterY - (topSectionHeight / 2))
                        
                        // 3. Core vibrant cyan neon tube illumination
                        Capsule()
                            .fill(Color(red: 0.25, green: 0.78, blue: 1.0).opacity(0.48))
                            .frame(width: islandWidth + 12, height: islandHeight + 8)
                            .blur(radius: 5)
                            .offset(y: islandCenterY - (topSectionHeight / 2))
                        
                        // 4. Soft illuminated edge contour outlining the hardware pill
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.50, green: 0.88, blue: 1.0).opacity(0.68),
                                        Color(red: 0.20, green: 0.65, blue: 0.95).opacity(0.42),
                                        Color(red: 0.50, green: 0.88, blue: 1.0).opacity(0.68)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 1.0
                            )
                            .frame(width: islandWidth + 2, height: islandHeight + 2)
                            .shadow(color: Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.60), radius: 5, x: 0, y: 0)
                            .offset(y: islandCenterY - (topSectionHeight / 2))
                    }
                    .frame(maxWidth: .infinity, maxHeight: topSectionHeight)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.78),
                                .init(color: .black.opacity(0.35), location: 0.92),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: symmetricGlassHeight)
            .ignoresSafeArea(.all, edges: .top)
            .allowsHitTesting(false)
        }
    }
}

/// Unified Header Brand Mark that adapts to the Dynamic Island on iOS.
public struct TLDynamicBrandHeader: View {
    public init() {}
    
    public var body: some View {
        HStack(spacing: 0) {
            Text("Tube")
                .foregroundColor(TLTheme.textPrimary)
            Text("Lite")
                .foregroundColor(TLTheme.accent)
        }
        .font(.system(size: 19, weight: .bold))
        .tracking(-0.4)
        .shadow(color: TLTheme.accent.opacity(0.45), radius: 6, x: 0, y: 1)
        .accessibilityLabel("TubeLite")
    }
}
