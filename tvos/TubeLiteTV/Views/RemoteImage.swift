import SwiftUI
import UIKit

/// Thread-safe in-memory cache for decoded remote images and thumbnails.
public final class ThumbnailImageCache: @unchecked Sendable {
    public static let shared = ThumbnailImageCache()
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 120 * 1024 * 1024 // ~120 MB
    }
    
    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    
    public func set(_ image: UIImage, forKey key: String, cost: Int = 0) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Remote image that always fills its parent (crop, never stretch).
/// Supports automatic multi-tier fallback (maxresdefault -> sddefault -> API thumb -> hqdefault -> mqdefault)
/// and rejects YouTube's 120x90 placeholder when high-res is missing.
public struct RemoteImage: View {
    let url: URL?
    var videoId: String? = nil
    
    @State private var loadedImage: UIImage? = nil
    
    public init(url: URL?, videoId: String? = nil, contentMode: ContentMode = .fill) {
        self.url = url
        self.videoId = videoId
        // contentMode kept for call-site compatibility; always fill+crop.
        _ = contentMode
        
        let initialKey = videoId ?? url?.absoluteString
        if let initialKey, let cached = ThumbnailImageCache.shared.image(forKey: initialKey) {
            _loadedImage = State(initialValue: cached)
        }
    }
    
    public var body: some View {
        ZStack {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .task(id: "\(videoId ?? "")_\(url?.absoluteString ?? "")") {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        // Fast path: check cache for videoId or primary url
        if let vid = videoId, let cached = ThumbnailImageCache.shared.image(forKey: vid) {
            self.loadedImage = cached
            return
        }
        if let u = url?.absoluteString, let cached = ThumbnailImageCache.shared.image(forKey: u) {
            self.loadedImage = cached
            return
        }
        
        let candidates = ThumbnailURL.candidates(primary: url, videoId: videoId)
        guard !candidates.isEmpty else { return }
        
        for candidate in candidates {
            guard !Task.isCancelled else { return }
            
            // Check cache for this candidate URL
            if let cached = ThumbnailImageCache.shared.image(forKey: candidate.absoluteString) {
                self.loadedImage = cached
                if let vid = videoId {
                    ThumbnailImageCache.shared.set(cached, forKey: vid)
                }
                return
            }
            
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 8
            request.setValue(
                "Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                forHTTPHeaderField: "User-Agent"
            )
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                
                let http = response as? HTTPURLResponse
                let statusCode = http?.statusCode ?? 0
                guard statusCode == 200 || statusCode == 0 else {
                    continue
                }
                
                // Decode image off the main thread to avoid blocking UI during rapid thumbnail loading.
                guard let decoded = await Self.decodeImage(data: data) else {
                    continue
                }
                
                guard decoded.size.width > 1 && decoded.size.height > 1 else {
                    continue
                }
                
                let cost = data.count
                ThumbnailImageCache.shared.set(decoded, forKey: candidate.absoluteString, cost: cost)
                if let vid = videoId {
                    ThumbnailImageCache.shared.set(decoded, forKey: vid, cost: cost)
                }
                if let primaryUrl = url?.absoluteString {
                    ThumbnailImageCache.shared.set(decoded, forKey: primaryUrl, cost: cost)
                }
                
                await MainActor.run {
                    self.loadedImage = decoded
                }
                return
            } catch {
                continue
            }
        }
    }
    
    /// Decode UIImage on a background thread to keep thumbnail-heavy grids responsive.
    private static func decodeImage(data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }
    
    private var placeholder: some View {
        ZStack {
            TLTheme.surface
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(TLTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Fixed 16:9 frame — image is cropped to fit, never stretched or letterboxed into a different ratio.
public struct ThumbnailFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    
    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    
    public var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .clipped()
            // Prevent LazyVGrid row stretching from growing the thumb.
            .fixedSize(horizontal: false, vertical: true)
    }
}

public enum ThumbnailURL {
    public static func candidates(primary: URL?, videoId: String?) -> [URL] {
        var list: [URL] = []
        if let n = normalize(primary) {
            list.append(n)
        }
        if let id = videoId, !id.isEmpty {
            if let u = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") {
                list.append(u)
            }
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }
    
    public static func normalize(_ url: URL?) -> URL? {
        normalize(url?.absoluteString)
    }
    
    public static func normalize(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var s = raw
        if s.hasPrefix("//") {
            s = "https:" + s
        } else if s.hasPrefix("http://") {
            s = "https://" + String(s.dropFirst(7))
        }
        if let u = URL(string: s) {
            return u
        }
        if let encoded = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: encoded)
        }
        return nil
    }
}
