import SwiftUI

/// Mobile Home Feed displaying a single-column vertical list of video cards with pull-to-refresh.
public struct HomeFeedView: View {
    @ObservedObject private var client = TubeLiteGatewayClient.shared
    @ObservedObject private var auth = DeviceAuthService.shared
    public let onSelect: (VideoItem) -> Void
    
    @State private var preloadTask: Task<Void, Never>? = nil
    
    public init(onSelect: @escaping (VideoItem) -> Void) {
        self.onSelect = onSelect
    }
    
    public var body: some View {
        NavigationStack {
            GeometryReader { windowProxy in
                let screenHeight = windowProxy.size.height
                let screenCenterY = screenHeight / 2
                
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
                            .padding(.top, 16)
                            
                            if client.isLoadingMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onPreferenceChange(CardVisibilityPreferenceKey.self) { cards in
                    let visible = cards.filter { $0.maxY > 80 && $0.minY < (screenHeight - 60) }
                    guard let mostProminent = visible.min(by: { a, b in
                        let distA = abs((a.minY + a.maxY) / 2 - screenCenterY)
                        let distB = abs((b.minY + b.maxY) / 2 - screenCenterY)
                        return distA < distB
                    }) else { return }
                    
                    let targetId = mostProminent.id
                    preloadTask?.cancel()
                    preloadTask = Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        await PlaybackPreloadCache.shared.preloadExclusive(videoId: targetId)
                    }
                }
                .refreshable {
                    preloadTask?.cancel()
                    await client.fetchHomeFeed()
                }
                .background(TLTheme.canvas.ignoresSafeArea())
                .toolbarBackground(TLTheme.canvas, for: .navigationBar)
            }
        }
        .task {
            await client.fetchHomeFeedIfNeeded()
        }
    }
}
