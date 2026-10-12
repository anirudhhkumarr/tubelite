import SwiftUI

/// Root shell. Home/Search use vertical grids; selection opens WatchView (hero + related, play = fullscreen).
public struct MainView: View {
    @StateObject private var auth = DeviceAuthService.shared
    @StateObject private var client = TubeLiteGatewayClient.shared
    @State private var selectedVideo: VideoItem?
    @State private var selectedTab = 0
    
    public init() {}
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            HomeFeedView(onSelect: { selectedVideo = $0 })
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            
            SearchFeedView(isActive: selectedTab == 1, onSelect: { selectedVideo = $0 })
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)
            
            AccountTabView()
                .tabItem { Label(auth.isSignedIn ? "Account" : "Sign In", systemImage: "person.crop.circle") }
                .tag(2)
        }
        .fullScreenCover(item: $selectedVideo, onDismiss: {
            if selectedTab == 0 { Task { await client.fetchHomeFeedIfNeeded() } }
        }) { video in
            WatchView(
                video: video,
                onOpenAccount: {
                    selectedVideo = nil
                    selectedTab = 2
                },
                onDismiss: { selectedVideo = nil }
            )
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 && selectedVideo == nil {
                Task { await client.fetchHomeFeedIfNeeded() }
            }
        }
        .task(id: selectedVideo?.id) {
            guard selectedVideo != nil else { return }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await client.fetchHomeFeedIfNeeded()
        }
    }
}

// MARK: - Home (vertical scroll grid)

private struct HomeFeedView: View {
    @StateObject private var client = TubeLiteGatewayClient.shared
    @StateObject private var auth = DeviceAuthService.shared
    let onSelect: (VideoItem) -> Void
    
    private var videos: [VideoItem] {
        client.homeVideos
    }
    
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: TLTheme.gridGap, alignment: .top),
            count: TLTheme.gridColumns
        )
    }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    TLBrandMark()
                    Spacer()
                }
                .padding(.leading, TLTheme.pageInset)
                .padding(.top, 63)
                .padding(.bottom, 58)
                .focusable(false)
                .allowsHitTesting(false)
                
                if client.isLoading && videos.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = client.errorMessage, videos.isEmpty {
                    TLEmptyState(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Unable to load videos",
                        message: error,
                        actionTitle: "Retry",
                        action: { Task { await client.fetchHomeFeed() } }
                    )
                } else if videos.isEmpty {
                    TLEmptyState(
                        systemImage: auth.isSignedIn ? "film" : "person.crop.circle.badge.questionmark",
                        title: auth.isSignedIn ? "No videos yet" : "Sign in for a personalized feed",
                        message: auth.isSignedIn
                            ? "Try reloading, or search for something to watch."
                            : "Use Search anytime, or sign in from the Account tab.",
                        actionTitle: auth.isSignedIn ? "Reload" : nil,
                        action: auth.isSignedIn ? { Task { await client.fetchHomeFeed() } } : nil
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: TLTheme.gridGap) {
                        ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                            VideoCardView(video: video, onSelect: onSelect)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .onAppear {
                                    if index >= videos.count - 4 {
                                        Task { await client.fetchMoreHomeFeed() }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, TLTheme.pageInset)
                    
                    if client.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
            .padding(.bottom, 48)
        }
        .ignoresSafeArea(.all, edges: .top)
        .background(TLTheme.canvas.ignoresSafeArea())
        .task {
            await client.fetchHomeFeedIfNeeded()
        }
    }
}

// MARK: - Search

private struct SearchFeedView: View {
    @StateObject private var client = TubeLiteGatewayClient.shared
    let isActive: Bool
    let onSelect: (VideoItem) -> Void
    
    @State private var query = ""
    @State private var appliedQuery = ""
    @FocusState private var searchFieldFocused: Bool
    
    private var videos: [VideoItem] {
        client.searchResults
    }
    
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: TLTheme.gridGap, alignment: .top),
            count: TLTheme.gridColumns
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search YouTube", text: $query)
                .font(.body)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(submit)
                .focused($searchFieldFocused)
                .focusEffectDisabled(true)
                .padding(.horizontal, TLTheme.pageInset)
                .padding(.top, 20)
                .padding(.bottom, 8)
            
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if appliedQuery.isEmpty {
                        TLEmptyState(
                            systemImage: "magnifyingglass",
                            title: "Find something to watch",
                            message: "Type a query and press Done to search."
                        )
                    } else if client.isLoading && videos.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if videos.isEmpty {
                        TLEmptyState(
                            systemImage: "video.slash",
                            title: "No videos found",
                            message: "Try different keywords."
                        )
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: TLTheme.gridGap) {
                            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                                VideoCardView(video: video, onSelect: onSelect)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .onAppear {
                                        if index >= videos.count - 4 {
                                            Task { await client.fetchMoreSearchResults() }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, TLTheme.pageInset)
                        
                        if client.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                }
                .padding(.top, 36)
                .padding(.bottom, 48)
            }
        }
        .background(TLTheme.canvas.ignoresSafeArea())
        .defaultFocus($searchFieldFocused, true)
        .onChange(of: isActive) { _, active in
            if active {
                activateSearchField()
            } else {
                searchFieldFocused = false
            }
        }
        .onAppear {
            if isActive {
                activateSearchField()
            }
        }
    }
    
    private func activateSearchField() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            searchFieldFocused = true
        }
    }
    
    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appliedQuery = trimmed
        searchFieldFocused = false
        Task { await client.search(query: trimmed) }
    }
}
