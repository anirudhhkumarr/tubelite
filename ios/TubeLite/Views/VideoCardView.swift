import SwiftUI
import UIKit

/// Mobile touch-first video card for feeds (16:9 hero thumbnail with clean metadata row).
public struct VideoCardView: View {
    public let video: VideoItem
    public let onSelect: (VideoItem) -> Void
    
    public init(video: VideoItem, onSelect: @escaping (VideoItem) -> Void) {
        self.video = video
        self.onSelect = onSelect
    }
    
    public var body: some View {
        Button {
            onSelect(video)
        } label: {
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
        }
        .buttonStyle(TLBareButtonStyle())
        .accessibilityLabel("\(video.title), by \(video.channelTitle)")
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
