import SwiftUI
import UIKit

/// Mobile touch-first video card for feeds with swipe left (Not Interested) and swipe right (Watched).
public struct VideoCardView: View {
    public let video: VideoItem
    public let onSelect: (VideoItem) -> Void
    
    @State private var dragOffset: CGFloat = 0
    @State private var isSwiping: Bool = false
    @State private var isScrollingVertically: Bool = false
    @State private var hasTriggeredHaptic: Bool = false
    
    private let swipeThreshold: CGFloat = 75
    
    public init(video: VideoItem, onSelect: @escaping (VideoItem) -> Void) {
        self.video = video
        self.onSelect = onSelect
    }
    
    public var body: some View {
        ZStack {
            swipeBackground
            
            cardContent
                .background(TLTheme.canvas)
                .offset(x: dragOffset)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isSwiping, !isScrollingVertically, abs(dragOffset) < 5 else {
                        return
                    }
                    onSelect(video)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { value in
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            
                            // If vertical movement dominates, lock into vertical scrolling
                            if vertical > horizontal && !isSwiping {
                                isScrollingVertically = true
                                return
                            }
                            
                            // Engage horizontal swipe left (Not Interested) or swipe right (Watched)
                            if horizontal > vertical * 1.3 && !isScrollingVertically {
                                if value.translation.width < -20 {
                                    isSwiping = true
                                    dragOffset = value.translation.width
                                    
                                    if dragOffset <= -swipeThreshold && !hasTriggeredHaptic {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        hasTriggeredHaptic = true
                                    } else if dragOffset > -swipeThreshold {
                                        hasTriggeredHaptic = false
                                    }
                                } else if value.translation.width > 20 {
                                    isSwiping = true
                                    dragOffset = value.translation.width
                                    
                                    if dragOffset >= swipeThreshold && !hasTriggeredHaptic {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        hasTriggeredHaptic = true
                                    } else if dragOffset < swipeThreshold {
                                        hasTriggeredHaptic = false
                                    }
                                }
                            }
                        }
                        .onEnded { value in
                            if isSwiping {
                                if dragOffset < -swipeThreshold {
                                    // Swipe Left -> Not Interested
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        dragOffset = -450
                                    }
                                    Task {
                                        let success = await TubeLiteGatewayClient.shared.sendFeedback(videoId: video.id, feedbackToken: video.feedbackToken)
                                        if !success {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                dragOffset = 0
                                            }
                                        } else {
                                            dragOffset = 0
                                        }
                                        isSwiping = false
                                    }
                                } else if dragOffset > swipeThreshold {
                                    // Swipe Right -> Watched
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        dragOffset = 450
                                    }
                                    Task {
                                        let success = await TubeLiteGatewayClient.shared.recordWatchStatus(videoId: video.id, durationSec: video.durationSeconds)
                                        if !success {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                dragOffset = 0
                                            }
                                        } else {
                                            dragOffset = 0
                                        }
                                        isSwiping = false
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        dragOffset = 0
                                    }
                                    isSwiping = false
                                }
                            }
                            
                            hasTriggeredHaptic = false
                            isScrollingVertically = false
                        }
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(video.title), by \(video.channelTitle)")
                .accessibilityAction {
                    onSelect(video)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: TLTheme.radiusThumb, style: .continuous))
        .background(
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear.preference(
                    key: CardVisibilityPreferenceKey.self,
                    value: [VideoCardVisibility(id: video.id, minY: frame.minY, maxY: frame.maxY)]
                )
            }
        )
    }
    
    private var swipeBackground: some View {
        ZStack {
            if dragOffset > 0 {
                // Swipe right background: Green "Watched"
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3.weight(.bold))
                        Text("Watched")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)
                    .background(Color.green.opacity(0.88))
                    
                    Spacer()
                }
            } else if dragOffset < 0 {
                // Swipe left background: Red "Not Interested"
                HStack {
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Text("Not Interested")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "hand.thumbsdown.fill")
                            .font(.title3.weight(.bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)
                    .background(Color.red.opacity(0.88))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TLTheme.radiusThumb, style: .continuous))
    }
    
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 16:9 Thumbnail with duration overlay
            thumbContent
            
            // Metadata Row
            HStack(alignment: .top, spacing: 12) {
                ChannelAvatar(
                    url: video.channelThumbnailUrl,
                    channelTitle: video.channelTitle,
                    size: 38
                )
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(TLTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 4) {
                        if !video.channelTitle.isEmpty {
                            Text(video.channelTitle)
                                .font(.caption)
                                .foregroundColor(TLTheme.textSecondary)
                                .lineLimit(1)
                        }
                        
                        if !video.channelTitle.isEmpty && !video.cardStatsLine.isEmpty {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(TLTheme.textTertiary)
                        }
                        
                        if !video.cardStatsLine.isEmpty {
                            Text(video.cardStatsLine)
                                .font(.caption)
                                .foregroundColor(TLTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }
    
    private var thumbContent: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black
                .aspectRatio(16/9, contentMode: .fit)
                .overlay(
                    RemoteImage(url: video.thumbnailUrl, videoId: video.id)
                )
            
            if !video.duration.isEmpty {
                durationBadge
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: TLTheme.radiusThumb, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: TLTheme.radiusThumb, style: .continuous))
    }
    
    private var durationBadge: some View {
        Text(video.duration)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(8)
    }
}

/// Compact horizontal video card for "Up Next" / Related videos in the mobile Watch screen.
public struct RelatedVideoRow: View {
    public let video: VideoItem
    public let onSelect: (VideoItem) -> Void
    
    @State private var dwellTask: Task<Void, Never>? = nil
    
    public init(video: VideoItem, onSelect: @escaping (VideoItem) -> Void) {
        self.video = video
        self.onSelect = onSelect
    }
    
    public var body: some View {
        Button {
            onSelect(video)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // 16:9 Thumbnail
                ZStack(alignment: .bottomTrailing) {
                    Color.black
                        .frame(width: 124, height: 70)
                        .overlay(
                            RemoteImage(url: video.thumbnailUrl, videoId: video.id)
                        )
                    
                    if !video.duration.isEmpty {
                        Text(video.duration)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.82))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .padding(4)
                    }
                }
                .frame(width: 124, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                
                // Metadata
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(TLTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    if !video.channelTitle.isEmpty {
                        Text(video.channelTitle)
                            .font(.caption2)
                            .foregroundColor(TLTheme.textSecondary)
                            .lineLimit(1)
                    }
                    
                    if !video.cardStatsLine.isEmpty {
                        Text(video.cardStatsLine)
                            .font(.caption2)
                            .foregroundColor(TLTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TLBareButtonStyle())
        .accessibilityLabel("\(video.title), by \(video.channelTitle)")
        .onAppear {
            let videoId = video.id
            dwellTask?.cancel()
            dwellTask = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: PlaybackPreloadCache.focusDwellDelayNanoseconds)
                guard !Task.isCancelled else { return }
                await PlaybackPreloadCache.shared.preload(videoId: videoId)
            }
        }
        .onDisappear {
            dwellTask?.cancel()
            dwellTask = nil
            let videoId = video.id
            Task.detached(priority: .utility) {
                await PlaybackPreloadCache.shared.cancelInflight(videoId: videoId)
            }
        }
    }
}

/// Circular channel image — loads avatar with letter placeholder fallback.
public struct ChannelAvatar: View {
    public let url: URL?
    public let channelTitle: String
    public let size: CGFloat
    
    @State private var image: UIImage? = nil
    
    public init(url: URL?, channelTitle: String, size: CGFloat = 38) {
        self.url = url
        self.channelTitle = channelTitle
        self.size = size
        if let key = url?.absoluteString, let cached = ThumbnailImageCache.shared.image(forKey: key) {
            _image = State(initialValue: cached)
        }
    }
    
    private var initial: String {
        let trimmed = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
    
    public var body: some View {
        ZStack {
            Circle()
                .fill(TLTheme.surfaceElevated)
            
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initial)
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundColor(TLTheme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url?.absoluteString) {
            guard let url else {
                self.image = nil
                return
            }
            if let cached = ThumbnailImageCache.shared.image(forKey: url.absoluteString) {
                self.image = cached
                return
            }
            await loadImage(from: url)
        }
    }
    
    private func loadImage(from url: URL) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (status == 200 || status == 0),
                  let ui = UIImage(data: data),
                  ui.size.width > 1 else {
                return
            }
            ThumbnailImageCache.shared.set(ui, forKey: url.absoluteString, cost: data.count)
            await MainActor.run {
                self.image = ui
            }
        } catch {
            // Keep letter fallback
        }
    }
}

public struct VideoCardVisibility: Equatable {
    public let id: String
    public let minY: CGFloat
    public let maxY: CGFloat
    
    public init(id: String, minY: CGFloat, maxY: CGFloat) {
        self.id = id
        self.minY = minY
        self.maxY = maxY
    }
}

public struct CardVisibilityPreferenceKey: PreferenceKey {
    public static var defaultValue: [VideoCardVisibility] = []
    
    public static func reduce(value: inout [VideoCardVisibility], nextValue: () -> [VideoCardVisibility]) {
        value.append(contentsOf: nextValue())
    }
}

