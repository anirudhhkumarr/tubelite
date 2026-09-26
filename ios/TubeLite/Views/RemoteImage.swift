import SwiftUI
import UIKit

/// Thread-safe in-memory cache for decoded remote images and thumbnails.
public final class ThumbnailImageCache: @unchecked Sendable {
    public static let shared = ThumbnailImageCache()
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 100 * 1024 * 1024 // ~100 MB
    }
    
    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    
    public func set(_ image: UIImage, forKey key: String, cost: Int = 0) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Helper to normalize and produce fallback candidate URLs for YouTube thumbnails.
public enum ThumbnailURL {
    public static func normalize(_ url: URL) -> URL {
        guard let normalized = normalize(url.absoluteString) else { return url }
        return normalized
    }
    
    public static func normalize(_ string: String) -> URL? {
        var str = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("//") {
            str = "https:" + str
        }
        return URL(string: str)
    }
    
    public static func candidates(primary: URL?, videoId: String?) -> [URL] {
        var list: [URL] = []
        if let primary { list.append(primary) }
        
        if let vid = videoId, !vid.isEmpty {
            let patterns = [
                "https://i.ytimg.com/vi/\(vid)/maxresdefault.jpg",
                "https://i.ytimg.com/vi/\(vid)/sddefault.jpg",
                "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg",
                "https://i.ytimg.com/vi/\(vid)/mqdefault.jpg"
            ]
            for p in patterns {
                if let u = URL(string: p), !list.contains(u) {
                    list.append(u)
                }
            }
        }
        return list
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
            
            if let cached = ThumbnailImageCache.shared.image(forKey: candidate.absoluteString) {
                self.loadedImage = cached
                if let vid = videoId {
                    ThumbnailImageCache.shared.set(cached, forKey: vid)
                }
                return
            }
            
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 6
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
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
                
                // YouTube returns a 120x90 404 image placeholder for missing maxresdefault
                if data.count < 2000 {
                    if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                       let width = properties[kCGImagePropertyPixelWidth] as? Int,
                       let height = properties[kCGImagePropertyPixelHeight] as? Int {
                        if width <= 120 && height <= 90 {
                            continue
                        }
                    }
                }
                
                guard let image = UIImage(data: data) else { continue }
                
                ThumbnailImageCache.shared.set(image, forKey: candidate.absoluteString, cost: data.count)
                if let vid = videoId {
                    ThumbnailImageCache.shared.set(image, forKey: vid, cost: data.count)
                }
                
                await MainActor.run {
                    self.loadedImage = image
                }
                return
            } catch {
                continue
            }
        }
    }
    
    private var placeholder: some View {
        Rectangle()
            .fill(TLTheme.surface)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundColor(TLTheme.textTertiary)
            )
    }
}
