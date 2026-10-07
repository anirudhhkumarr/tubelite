import SwiftUI

/// Mobile Search interface with integrated search bar and pull-to-refresh results.
public struct SearchView: View {
    @ObservedObject private var client = TubeLiteGatewayClient.shared
    public let onSelect: (VideoItem) -> Void
    
    @State private var query = ""
    @State private var appliedQuery = ""
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
                        if appliedQuery.isEmpty {
                            TLEmptyState(
                                systemImage: "magnifyingglass",
                                title: "Find something to watch",
                                message: "Search for videos, topics, or creators."
                            )
                        } else if client.isLoading && client.searchResults.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else if client.searchResults.isEmpty {
                            TLEmptyState(
                                systemImage: "video.slash",
                                title: "No videos found",
                                message: "Try searching with different keywords."
                            )
                        } else {
                            LazyVStack(spacing: TLTheme.cardGap) {
                                ForEach(Array(client.searchResults.enumerated()), id: \.element.id) { index, video in
                                    VideoCardView(video: video, onSelect: onSelect)
                                        .onAppear {
                                            if index >= client.searchResults.count - 3 {
                                                Task { await client.fetchMoreSearchResults() }
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
                    if !appliedQuery.isEmpty {
                        await client.search(query: appliedQuery)
                    }
                }
                .background(TLTheme.canvas.ignoresSafeArea())
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search YouTube")
                .onSubmit(of: .search) {
                    preloadTask?.cancel()
                    submitSearch()
                }
                .toolbarBackground(TLTheme.canvas, for: .navigationBar)
            }
        }
    }
    
    private func submitSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appliedQuery = trimmed
        Task {
            await client.search(query: trimmed)
        }
    }
}
