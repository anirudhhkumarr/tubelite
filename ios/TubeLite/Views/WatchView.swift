import SwiftUI

/// Mobile Watch screen: opens in full-screen edge-to-edge playback with zero clutter
/// and a glassy matte top row along the Dynamic Island.
/// Pressing back transitions to the details page featuring Up Next related videos,
/// video title, channel info, and expandable description.
public struct WatchView: View {
    public let initialVideo: VideoItem
    public let onOpenAccount: () -> Void
    public let onDismiss: () -> Void
    
    private struct HistoryEntry {
        let video: VideoItem
        let related: [VideoItem]
    }
    
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var currentVideo: VideoItem
    @State private var related: [VideoItem] = []
    @State private var history: [HistoryEntry] = []
    @State private var isLoadingRelated = true
    @State private var isDescriptionExpanded = false
    @State private var isFullScreen = true
    
    @State private var lastDiagnostics: TubeLiteGatewayClient.PlaybackDiagnostics? = nil
    @State private var lastAVPlayerLog: String? = nil
    @State private var showLogs = false
    
    public init(
        video: VideoItem,
        onOpenAccount: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.initialVideo = video
        self.onOpenAccount = onOpenAccount
        self.onDismiss = onDismiss
        self._currentVideo = State(initialValue: video)
    }
    
    private var relatedItems: [VideoItem] {
        related.filter { $0.id != currentVideo.id }
    }
    
    private var hasLogs: Bool {
        lastDiagnostics != nil || !(lastAVPlayerLog ?? "").isEmpty
    }
    
    public var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height || verticalSizeClass == .compact
            let leadingInset = proxy.safeAreaInsets.leading
            let inlineTopPadding = isFullScreen || isLandscape ? 0 : TLScreenMetrics.symmetricTopPadding(topInset: proxy.safeAreaInsets.top)
            
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Player Container (Persistent identity)
                    PlayerView(
                        videoId: currentVideo.id,
                        onOpenAccount: onOpenAccount,
                        onDismiss: onDismiss,
                        onDiagnostics: { diag, avLog in
                            self.lastDiagnostics = diag
                            self.lastAVPlayerLog = avLog
                        }
                    )
                    .id(currentVideo.id)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: isLandscape ? proxy.size.height : nil)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10)
                            .onEnded { value in
                                guard !PlayerViewControllerWrapper.isFullScreenActive else { return }
                                let vertical = value.translation.height
                                let absVertical = abs(vertical)
                                let horizontal = value.translation.width
                                let absHorizontal = abs(horizontal)
                                let predictedVertical = value.predictedEndTranslation.height
                                let predictedHorizontal = value.predictedEndTranslation.width
                                
                                // Horizontal swipe (swipe left or swipe right) on player -> go back in history all the way to home
                                if (absHorizontal > 20 || abs(predictedHorizontal) > 35) && absHorizontal > absVertical * 0.75 {
                                    withAnimation(TLTheme.spring) {
                                        navigateBack()
                                    }
                                } else if isFullScreen {
                                    // Swipe UP or swipe DOWN in full screen -> return to older style view
                                    if (absVertical > 16 || abs(predictedVertical) > 30) && absVertical > absHorizontal * 0.75 {
                                        withAnimation(TLTheme.spring) {
                                            isFullScreen = false
                                        }
                                    }
                                } else {
                                    // In older view: swipe down on player -> dismiss to feed
                                    if (vertical > 25 || predictedVertical > 50) && vertical > absHorizontal * 1.0 {
                                        PlayerView.teardownActivePlayer()
                                        onDismiss()
                                    } else if (vertical < -25 || predictedVertical < -50) && absVertical > absHorizontal * 1.0 {
                                        // Swipe up on player -> expand to full screen
                                        withAnimation(TLTheme.spring) {
                                            isFullScreen = true
                                        }
                                    }
                                }
                            }
                    )
                    
                    if !isFullScreen && !isLandscape {
                        // Older style view: Scrollable Video Details & Up Next / Related Videos (no drawer)
                        ScrollView(.vertical, showsIndicators: true) {
                            detailsContent
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.top, inlineTopPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: (isFullScreen || isLandscape) ? .center : .top)
                
                // Dynamic Island Aura along top row (portrait only)
                if !isLandscape {
                    DynamicIslandAuraView()
                }
                
                // Back button in full screen (no other controls on this page)
                if isFullScreen {
                    Button {
                        withAnimation(TLTheme.spring) {
                            isFullScreen = false
                        }
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .padding(.leading, max(leadingInset, 16))
                    .padding(.top, isLandscape ? 14 : max(proxy.safeAreaInsets.top, 12) + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        guard isFullScreen, !PlayerViewControllerWrapper.isFullScreenActive else { return }
                        let vertical = value.translation.height
                        let absVertical = abs(vertical)
                        let horizontal = value.translation.width
                        let absHorizontal = abs(horizontal)
                        let predictedVertical = value.predictedEndTranslation.height
                        let predictedHorizontal = value.predictedEndTranslation.width
                        
                        // Horizontal swipe anywhere in full screen -> navigate back in history all the way to home
                        if (absHorizontal > 20 || abs(predictedHorizontal) > 35) && absHorizontal > absVertical * 0.75 {
                            withAnimation(TLTheme.spring) {
                                navigateBack()
                            }
                        } else if (absVertical > 16 || abs(predictedVertical) > 30) && absVertical > absHorizontal * 0.75 {
                            // Swipe UP or swipe DOWN anywhere on the entire page -> return to older style view
                            withAnimation(TLTheme.spring) {
                                isFullScreen = false
                            }
                        }
                    }
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showLogs) {
            logsSheet
        }
        .task(id: currentVideo.id) {
            await loadRelated()
        }
        .onAppear {
            Task.detached(priority: .utility) {
                await PlaybackPreloadCache.shared.cancelAll()
            }
        }
    }
    
    private func navigateBack() {
        if let previous = history.popLast() {
            self.currentVideo = previous.video
            self.related = previous.related
            self.isLoadingRelated = false
        } else {
            PlayerView.teardownActivePlayer()
            onDismiss()
        }
    }
    
    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Video Title & Stats
            VStack(alignment: .leading, spacing: 4) {
                Text(currentVideo.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(TLTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Stats Row (Views · Days ago)
                Text(currentVideo.cardStatsLine)
                    .font(.subheadline)
                    .foregroundColor(TLTheme.textSecondary)
            }
            .padding(.top, 14)
            
            // Channel Information Bar & Logs Button
            HStack(alignment: .center, spacing: 12) {
                ChannelAvatar(
                    url: currentVideo.channelThumbnailUrl,
                    channelTitle: currentVideo.channelTitle,
                    size: 40
                )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentVideo.channelTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(TLTheme.textPrimary)
                        .lineLimit(1)
                    
                    if !currentVideo.subscriberCount.isEmpty {
                        Text(currentVideo.subscriberCount)
                            .font(.caption2)
                            .foregroundColor(TLTheme.textTertiary)
                    }
                }
                
                Spacer()
                
                Button {
                    showLogs = true
                } label: {
                    Text("Logs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(TLTheme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(TLTheme.surfaceElevated, in: Capsule())
                }
                .accessibilityLabel("Video playback logs")
            }
            
            // Collapsible Description
            if !currentVideo.videoDescription.isEmpty {
                descriptionCard
            }
            
            if isLoadingRelated {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }
            
            // Related Videos List
            LazyVStack(spacing: 12) {
                ForEach(relatedItems) { item in
                    RelatedVideoRow(video: item) { selected in
                        history.append(HistoryEntry(video: currentVideo, related: related))
                        currentVideo = selected
                        withAnimation(TLTheme.spring) {
                            isFullScreen = true
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .padding(.horizontal, TLTheme.pageInset)
    }
    
    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(currentVideo.videoDescription)
                .font(.caption)
                .foregroundColor(TLTheme.textSecondary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDescriptionExpanded.toggle()
                }
            } label: {
                Text(isDescriptionExpanded ? "Show less" : "…more")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(TLTheme.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TLTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: TLTheme.radiusCard, style: .continuous))
    }
    
    private func loadRelated() async {
        isLoadingRelated = true
        let res = await TubeLiteGatewayClient.shared.fetchWatchNext(videoId: currentVideo.id)
        guard !Task.isCancelled else { return }
        if let details = res.details {
            self.currentVideo = VideoItem(
                id: self.currentVideo.id,
                title: details.title.isEmpty ? self.currentVideo.title : details.title,
                channelTitle: details.channelTitle.isEmpty ? self.currentVideo.channelTitle : details.channelTitle,
                channelId: details.channelId ?? self.currentVideo.channelId,
                duration: details.duration.isEmpty ? self.currentVideo.duration : details.duration,
                views: details.views.isEmpty ? self.currentVideo.views : details.views,
                publishedAt: details.publishedAt.isEmpty ? self.currentVideo.publishedAt : details.publishedAt,
                thumbnailUrl: details.thumbnailUrl ?? self.currentVideo.thumbnailUrl,
                channelThumbnailUrl: details.channelThumbnailUrl ?? self.currentVideo.channelThumbnailUrl,
                videoDescription: details.videoDescription.isEmpty ? self.currentVideo.videoDescription : details.videoDescription,
                subscriberCount: details.subscriberCount.isEmpty ? self.currentVideo.subscriberCount : details.subscriberCount
            )
        }
        self.related = res.related
        self.isLoadingRelated = false
    }
    
    private var logsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let diag = lastDiagnostics {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Audio Rendering: \(diag.audioRenderingMode)")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(TLTheme.accent)
                            
                            Text("Channels: \(diag.audioChannels)ch · \(diag.audioStatusDescription)")
                                .font(.footnote)
                                .foregroundColor(TLTheme.textSecondary)
                            
                            Divider()
                            
                            Text("Timeline:")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(TLTheme.textPrimary)
                            
                            ForEach(Array(diag.executionTimeline.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(TLTheme.textSecondary)
                            }
                        }
                        .padding()
                        .background(TLTheme.surface)
                        .cornerRadius(10)
                    }
                    
                    if let avLog = lastAVPlayerLog, !avLog.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AVPlayer Logs:")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(TLTheme.warning)
                            
                            Text(avLog)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TLTheme.textSecondary)
                        }
                        .padding()
                        .background(TLTheme.surface)
                        .cornerRadius(10)
                    }
                }
                .padding()
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showLogs = false
                    }
                }
            }
            .background(TLTheme.canvas.ignoresSafeArea())
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
