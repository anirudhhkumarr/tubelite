import SwiftUI
import UIKit

/// Focus includes metadata so tvOS scrolls the entire card into view.
public struct VideoCardView: View {
    public let video: VideoItem
    public let compact: Bool
    public let onSelect: (VideoItem) -> Void
    public var focusedId: FocusState<String?>.Binding?
    
    @FocusState private var isFocusedInternal: Bool
    
    private var isFocused: Bool {
        if let focusedId = focusedId {
            return focusedId.wrappedValue == video.id
        }
        return isFocusedInternal
    }
    
    public init(
        video: VideoItem,
        compact: Bool = false,
        focusedId: FocusState<String?>.Binding? = nil,
        onSelect: @escaping (VideoItem) -> Void
    ) {
        self.video = video
        self.compact = compact
        self.focusedId = focusedId
        self.onSelect = onSelect
    }
    
    public var body: some View {
        cardButton
        .frame(width: compact ? TLTheme.relatedCardWidth : nil, alignment: .topLeading)
        .frame(maxWidth: compact ? TLTheme.relatedCardWidth : .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(isFocused ? 1.07 : 0.94)
        .zIndex(isFocused ? 10 : 1)
        .animation(TLTheme.spring, value: isFocused)
        .task(id: isFocused) {
            guard isFocused else {
                // Focus left — cancel in-flight preload but keep any cached result.
                PlaybackPreloadCache.shared.cancelInflight(videoId: video.id)
                return
            }
            try? await Task.sleep(nanoseconds: PlaybackPreloadCache.focusDwellDelayNanoseconds)
            guard !Task.isCancelled else { return }
            PlaybackPreloadCache.shared.preload(videoId: video.id)
        }
    }
    
    @ViewBuilder
    private var cardButton: some View {
        if let focusedId = focusedId {
            Button {
                onSelect(video)
            } label: {
                cardContent
            }
            .buttonStyle(TLBareButtonStyle())
            .focused(focusedId, equals: video.id)
            .focusEffectDisabled(true)
            .hoverEffectDisabled(true)
            .accessibilityLabel(video.title)
        } else {
            Button {
                onSelect(video)
            } label: {
                cardContent
            }
            .buttonStyle(TLBareButtonStyle())
            .focused($isFocusedInternal)
            .focusEffectDisabled(true)
            .hoverEffectDisabled(true)
            .accessibilityLabel(video.title)
        }
    }
    
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbContent
            metadata
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Locked 16:9 box — fixed px on tray cards, aspect-locked width on the home grid.
    private var thumbContent: some View {
        Group {
            if compact {
                thumbInner
                    .frame(width: TLTheme.relatedCardWidth, height: TLTheme.relatedThumbHeight)
                    .clipped()
            } else {
                ThumbnailFrame { thumbInner }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TLTheme.radiusThumb, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: TLTheme.radiusThumb, style: .continuous)
                .strokeBorder(isFocused ? Color.white : Color.clear, lineWidth: 3)
        )
        .shadow(color: isFocused ? Color.black.opacity(0.45) : Color.clear, radius: 14, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: TLTheme.radiusThumb, style: .continuous))
    }
    
    private var thumbInner: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: video.thumbnailUrl, videoId: video.id)
            if !video.duration.isEmpty {
                durationBadge
            }
        }
    }
    
    private var durationBadge: some View {
        Text(video.duration)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(8)
    }
    
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            // First and maybe second row: video title from left to right across full card
            Text(video.title)
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundColor(isFocused ? TLTheme.accent : TLTheme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            
            // Next row: two columns (channel thumbnail on left, channel name & video info on right)
            HStack(alignment: .top, spacing: compact ? 10 : 12) {
                ChannelAvatar(
                    url: video.channelThumbnailUrl,
                    channelTitle: video.channelTitle,
                    size: compact ? 36 : 44
                )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.channelTitle.isEmpty ? " " : video.channelTitle)
                        .font(.caption2)
                        .foregroundColor(TLTheme.textSecondary)
                        .lineLimit(1)
                        .opacity(video.channelTitle.isEmpty ? 0 : 1)
                    
                    Text(statsLine.isEmpty ? " " : statsLine)
                        .font(.caption2)
                        .foregroundColor(TLTheme.textTertiary)
                        .lineLimit(1)
                        .opacity(statsLine.isEmpty ? 0 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.top, compact ? 24 : 18)
        .padding(.bottom, 4)
        // Ensure compact cards in the horizontal tray have uniform height
        // so the ScrollView doesn't clip 2-line titles.
        .frame(minHeight: compact ? TLTheme.relatedMetaHeight : nil, alignment: .topLeading)
        .allowsHitTesting(false)
    }
    
    private var statsLine: String {
        video.cardStatsLine
    }
}

/// Circular channel image — loads real yt3 avatars; letter only as last resort.
public struct ChannelAvatar: View {
    public let url: URL?
    public let channelTitle: String
    public let size: CGFloat
    
    @State private var image: UIImage? = nil
    
    public init(url: URL?, channelTitle: String, size: CGFloat = 44) {
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
                    .font(.system(size: size * 0.38, weight: .semibold))
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
            "Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)",
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
            // Non-speculative: failed network or cancellation leaves initial placeholder
        }
    }
}

public struct RelatedVideoRow: View {
    public let video: VideoItem
    public let onSelect: (VideoItem) -> Void
    
    public init(video: VideoItem, onSelect: @escaping (VideoItem) -> Void) {
        self.video = video
        self.onSelect = onSelect
    }
    
    public var body: some View {
        VideoCardView(video: video, compact: true, onSelect: onSelect)
    }
}
