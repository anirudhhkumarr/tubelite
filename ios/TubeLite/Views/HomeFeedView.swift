import SwiftUI

/// Mobile Home Feed displaying a single-column vertical list of video cards with pull-to-refresh.
public struct HomeFeedView: View {
    @ObservedObject private var client = TubeLiteGatewayClient.shared
    @ObservedObject private var auth = DeviceAuthService.shared
    public let onSelect: (VideoItem) -> Void
    
    public init(onSelect: @escaping (VideoItem) -> Void) {
        self.onSelect = onSelect
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: TLTheme.cardGap) {
                    if client.isLoading && client.homeVideos.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else if let error = client.errorMessage, client.homeVideos.isEmpty {
                        TLEmptyState(
                            systemImage: "exclamationmark.triangle.fill",
                            title: "Unable to load videos",
                            message: error,
                            actionTitle: "Retry",
                            action: { Task { await client.fetchHomeFeed() } }
                        )
                    } else if client.homeVideos.isEmpty {
                        TLEmptyState(
                            systemImage: auth.isSignedIn ? "film" : "person.crop.circle.badge.questionmark",
                            title: auth.isSignedIn ? "No videos yet" : "Sign in for personalized feed",
                            message: auth.isSignedIn
                                ? "Pull to refresh, or search for something to watch."
                                : "Use Search anytime, or sign in from the Account tab.",
                            actionTitle: auth.isSignedIn ? "Reload" : nil,
                            action: auth.isSignedIn ? { Task { await client.fetchHomeFeed() } } : nil
                        )
                    } else {
                        LazyVStack(spacing: TLTheme.cardGap) {
                            ForEach(Array(client.homeVideos.enumerated()), id: \.element.id) { index, video in
                                VideoCardView(video: video, onSelect: onSelect)
                                    .onAppear {
                                        if index >= client.homeVideos.count - 3 {
                                            Task { await client.fetchMoreHomeFeed() }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, TLTheme.pageInset)
                        .padding(.top, 8)
                        
                        if client.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable {
                await client.fetchHomeFeed()
            }
            .background(TLTheme.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    TLBrandMark(compact: true)
                }
            }
            .toolbarBackground(TLTheme.canvas, for: .navigationBar)
        }
        .task {
            await client.fetchHomeFeedIfNeeded()
        }
    }
}
