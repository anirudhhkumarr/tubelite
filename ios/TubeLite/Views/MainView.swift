import SwiftUI

/// Root iOS navigation container with TabView and full-screen WatchView presentation.
public struct MainView: View {
    @ObservedObject private var auth = DeviceAuthService.shared
    @ObservedObject private var client = TubeLiteGatewayClient.shared
    @State private var selectedVideo: VideoItem? = nil
    @State private var selectedTab = 0
    
    public init() {}
    
    public var body: some View {
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
            
            AccountView()
                .tabItem {
                    Label(auth.isSignedIn ? "Account" : "Sign In", systemImage: "person.crop.circle.fill")
                }
                .tag(2)
        }
        .tint(TLTheme.accent)
        .fullScreenCover(item: $selectedVideo) { video in
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
}
