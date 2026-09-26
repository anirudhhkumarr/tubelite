import SwiftUI

/// Root iOS navigation container with TabView and full-screen WatchView presentation.
public struct MainView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject private var auth = DeviceAuthService.shared
    @ObservedObject private var client = TubeLiteGatewayClient.shared
    @State private var selectedVideo: VideoItem? = nil
    @State private var selectedTab = 0
    
    public init() {}
    
    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                HomeFeedView { video in
                    selectedVideo = video
                }
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)
                
                SearchView { video in
                    selectedVideo = video
                }
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(1)
                
                AccountView(isActive: selectedTab == 2)
                    .tabItem {
                        Label(auth.isSignedIn ? "Account" : "Sign In", systemImage: "person.crop.circle.fill")
                    }
                    .tag(2)
            }
            .tint(TLTheme.accent)
            
            if !isLandscape {
                DynamicIslandAuraView()
            }
            
            if let errorMsg = client.activeErrorBubble {
                TLErrorBubbleView(message: errorMsg) {
                    client.dismissErrorBubble()
                }
                .padding(.top, errorBubbleTopPadding)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(999)
                .animation(TLTheme.spring, value: client.activeErrorBubble != nil)
            }
        }
        .fullScreenCover(item: $selectedVideo, onDismiss: {
            PlayerView.teardownActivePlayer()
        }) { video in
            WatchView(
                video: video,
                onOpenAccount: {
                    selectedVideo = nil
                    selectedTab = 2
                },
                onDismiss: {
                    selectedVideo = nil
                }
            )
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 && selectedVideo == nil {
                Task {
                    await client.fetchHomeFeedIfNeeded()
                }
            }
        }
    }
    
    private var errorBubbleTopPadding: CGFloat {
        max(54, TLScreenMetrics.topSafeAreaInset + 6)
    }
}
