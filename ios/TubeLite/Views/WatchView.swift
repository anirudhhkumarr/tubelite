import SwiftUI

/// Mobile Watch screen: top 16:9 inline player with auto-play, video details, channel bar,
/// expandable description, and vertical list of Up Next / Related videos with 1-tap switching.
public struct WatchView: View {
    public let initialVideo: VideoItem
    public let onOpenAccount: () -> Void
    public let onDismiss: () -> Void
    
    private struct HistoryEntry {
        let video: VideoItem
        let related: [VideoItem]
    }
    
    @State private var currentVideo: VideoItem
    @State private var related: [VideoItem] = []
    @State private var history: [HistoryEntry] = []
    @State private var isLoadingRelated = true
    @State private var isDescriptionExpanded = false
    
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
        VStack(spacing: 0) {
            // Top Navigation & Inline Player
            ZStack(alignment: .topLeading) {
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
                
                // Dismiss / Back Button Overlay
                Button {
                    if let previous = history.popLast() {
                        self.currentVideo = previous.video
                        self.related = previous.related
                        self.isLoadingRelated = false
                    } else {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: history.isEmpty ? "chevron.down" : "chevron.backward")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .padding(9)
                        .background(.black.opacity(0.65), in: Circle())
                }
                .padding(.leading, 12)
                .padding(.top, 10)
            }
            
            // Scrollable Video Details & Related Videos
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    // Video Title
                    Text(currentVideo.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(TLTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    
                    // Stats Row (Views · Age · Diagnostics)
                    HStack(spacing: 8) {
                        Text(currentVideo.cardStatsLine)
                            .font(.caption)
                            .foregroundColor(TLTheme.textSecondary)
                        
                        Spacer()
                        
                        if hasLogs {
                            Button {
                                showLogs = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "waveform.path.ecg")
                                    Text("Diagnostics")
                                }
                                .font(.caption2.weight(.medium))
                                .foregroundColor(TLTheme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(TLTheme.surfaceElevated, in: Capsule())
                            }
                        }
                    }
                    
                    // Channel Information Bar
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
                    }
                    .padding(.vertical, 4)
                    
                    // Collapsible Description
                    if !currentVideo.videoDescription.isEmpty {
                        descriptionCard
                    }
                    
                    Divider()
                        .background(TLTheme.surfaceBorder)
                        .padding(.vertical, 4)
                    
                    // Up Next / Related Videos Header
                    HStack {
                        Text("Up Next")
                            .font(.headline)
                            .foregroundColor(TLTheme.textPrimary)
                        
                        Spacer()
                        
                        if isLoadingRelated {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    
                    // Related Videos List
                    LazyVStack(spacing: 14) {
                        ForEach(relatedItems) { item in
                            RelatedVideoRow(video: item) { selected in
                                history.append(HistoryEntry(video: currentVideo, related: related))
                                currentVideo = selected
                                loadRelated()
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, TLTheme.pageInset)
            }
        }
        .background(TLTheme.canvas.ignoresSafeArea())
        .sheet(isPresented: $showLogs) {
            logsSheet
        }
        .task(id: currentVideo.id) {
            loadRelated()
        }
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
    
    private func loadRelated() {
        isLoadingRelated = true
        Task {
            let res = await TubeLiteGatewayClient.shared.fetchWatchNext(videoId: currentVideo.id)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let details = res.details {
                    // Update current video details with richer description/channel if returned
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
        }
    }
    
    private var logsSheet: some View {
        NavigationView {
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
                            Text("AVPlayer Diagnostics:")
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
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLogs = false }
                }
            }
            .background(TLTheme.canvas.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
    }
}
