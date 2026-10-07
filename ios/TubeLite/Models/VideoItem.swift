import Foundation

/// Represents a video item displayed in the TubeLite interface.
public struct VideoItem: Identifiable, Hashable, Codable {
    public let id: String
    public let title: String
    public let channelTitle: String
    public let channelId: String?
    public let duration: String
    public let views: String
    public let publishedAt: String
    public let thumbnailUrl: URL?
    public let channelThumbnailUrl: URL?
    public let videoDescription: String
    public let subscriberCount: String
    public let feedbackToken: String?
    public let channelFeedbackToken: String?
    
    public init(
        id: String,
        title: String,
        channelTitle: String,
        channelId: String? = nil,
        duration: String = "",
        views: String = "",
        publishedAt: String = "",
        thumbnailUrl: URL? = nil,
        channelThumbnailUrl: URL? = nil,
        videoDescription: String = "",
        subscriberCount: String = "",
        feedbackToken: String? = nil,
        channelFeedbackToken: String? = nil
    ) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.channelId = channelId
        self.duration = duration
        self.views = views
        self.publishedAt = publishedAt
        self.thumbnailUrl = thumbnailUrl
        self.channelThumbnailUrl = channelThumbnailUrl
        self.videoDescription = videoDescription
        self.subscriberCount = subscriberCount
        self.feedbackToken = feedbackToken
        self.channelFeedbackToken = channelFeedbackToken
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case channelTitle
        case channelId
        case duration
        case views
        case publishedAt
        case publishedTime
        case thumbnailUrl
        case channelThumbnailUrl
        case videoDescription
        case description
        case subscriberCount
        case feedbackToken
        case channelFeedbackToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = (try? container.decode(String.self, forKey: .title)) ?? ""
        self.channelTitle = (try? container.decode(String.self, forKey: .channelTitle)) ?? ""
        self.channelId = try? container.decodeIfPresent(String.self, forKey: .channelId)
        self.duration = (try? container.decode(String.self, forKey: .duration)) ?? ""
        self.views = (try? container.decode(String.self, forKey: .views)) ?? ""
        
        let pubAt = (try? container.decode(String.self, forKey: .publishedAt))
        let pubTime = (try? container.decode(String.self, forKey: .publishedTime))
        self.publishedAt = pubAt ?? pubTime ?? ""

        if let thumbStr = try? container.decodeIfPresent(String.self, forKey: .thumbnailUrl) {
            self.thumbnailUrl = ThumbnailURL.normalize(thumbStr)
        } else if let thumbUrl = try? container.decodeIfPresent(URL.self, forKey: .thumbnailUrl) {
            self.thumbnailUrl = ThumbnailURL.normalize(thumbUrl)
        } else {
            self.thumbnailUrl = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }

        if let chanStr = try? container.decodeIfPresent(String.self, forKey: .channelThumbnailUrl) {
            self.channelThumbnailUrl = ThumbnailURL.normalize(chanStr)
        } else if let chanUrl = try? container.decodeIfPresent(URL.self, forKey: .channelThumbnailUrl) {
            self.channelThumbnailUrl = ThumbnailURL.normalize(chanUrl)
        } else {
            self.channelThumbnailUrl = nil
        }
        
        let desc = (try? container.decode(String.self, forKey: .videoDescription))
        let altDesc = (try? container.decode(String.self, forKey: .description))
        self.videoDescription = desc ?? altDesc ?? ""

        self.subscriberCount = (try? container.decode(String.self, forKey: .subscriberCount)) ?? ""
        self.feedbackToken = try? container.decodeIfPresent(String.self, forKey: .feedbackToken)
        self.channelFeedbackToken = try? container.decodeIfPresent(String.self, forKey: .channelFeedbackToken)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(channelTitle, forKey: .channelTitle)
        try container.encodeIfPresent(channelId, forKey: .channelId)
        try container.encode(duration, forKey: .duration)
        try container.encode(views, forKey: .views)
        try container.encode(publishedAt, forKey: .publishedAt)
        try container.encodeIfPresent(thumbnailUrl, forKey: .thumbnailUrl)
        try container.encodeIfPresent(channelThumbnailUrl, forKey: .channelThumbnailUrl)
        try container.encode(videoDescription, forKey: .videoDescription)
        try container.encode(subscriberCount, forKey: .subscriberCount)
        try container.encodeIfPresent(feedbackToken, forKey: .feedbackToken)
        try container.encodeIfPresent(channelFeedbackToken, forKey: .channelFeedbackToken)
    }

    public var durationSeconds: Double {
        let parts = duration.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    /// "1.2M views · 3 days ago" — compact count + age when present.
    public var cardStatsLine: String {
        VideoMetaFormat.statsLine(views: views, publishedAt: publishedAt)
    }
}

/// Normalized feed response schema returned by the Cloudflare Worker Gateway.
public struct FeedResponse: Codable {
    public let items: [VideoItem]
    public let continuationToken: String?
    
    public init(items: [VideoItem] = [], continuationToken: String? = nil) {
        self.items = items
        self.continuationToken = continuationToken
    }
}

/// Normalized watch-next response schema returned by the Cloudflare Worker Gateway.
public struct WatchNextResponse: Codable {
    public let details: VideoItem?
    public let items: [VideoItem]
    public let continuationToken: String?
    
    public init(details: VideoItem? = nil, items: [VideoItem] = [], continuationToken: String? = nil) {
        self.details = details
        self.items = items
        self.continuationToken = continuationToken
    }
}

/// Compact view counts (K/M/B) and age line for cards / watch meta.
public enum VideoMetaFormat {
    public static func statsLine(views: String, publishedAt: String) -> String {
        let parts = [compactViews(views), age(publishedAt)].filter { !$0.isEmpty }
        return parts.joined(separator: "  ·  ")
    }
    
    public static func age(_ publishedAt: String) -> String {
        let trimmed = publishedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.contains("ago") || lower.contains("yesterday") || lower.contains("today") || lower.contains("just now") {
            return normalizeRelativeAge(trimmed)
        }
        return formatRelativeDate(from: trimmed) ?? trimmed
    }
    
    /// "1,234,567 views" / "4.8 million views" / "800K views" → "1.2M views"
    public static func compactViews(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let n = parseCount(trimmed) else { return trimmed }
        let unit = n == 1 ? "view" : "views"
        return "\(formatCompact(n)) \(unit)"
    }
    
    private static func normalizeRelativeAge(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d+)\s*(d|w|mo|m|y)\s*ago$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return trimmed
        }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3,
              let numRange = Range(match.range(at: 1), in: trimmed),
              let unitRange = Range(match.range(at: 2), in: trimmed) else {
            return trimmed
        }
        let count = Int(trimmed[numRange]) ?? 1
        let unitChar = trimmed[unitRange].lowercased()
        let unit: String
        switch unitChar {
        case "d": unit = count == 1 ? "day" : "days"
        case "w": unit = count == 1 ? "week" : "weeks"
        case "mo": unit = count == 1 ? "month" : "months"
        case "m": unit = count == 1 ? "minute" : "minutes"
        case "y": unit = count == 1 ? "year" : "years"
        default: return trimmed
        }
        return "\(count) \(unit) ago"
    }
    
    private static func formatRelativeDate(from rawDate: String) -> String? {
        let prefixes = ["streamed live on", "streamed on", "streamed", "premiered", "published on", "published"]
        var cleaned = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        
        let dateFormats = [
            "MMM d, yyyy",
            "MMMM d, yyyy",
            "d MMM yyyy",
            "d MMMM yyyy",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "MM/dd/yyyy",
            "M/d/yyyy"
        ]
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        var parsedDate: Date? = nil
        for format in dateFormats {
            formatter.dateFormat = format
            if let d = formatter.date(from: cleaned) {
                parsedDate = d
                break
            }
        }
        
        if parsedDate == nil {
            let isoFormatter = ISO8601DateFormatter()
            parsedDate = isoFormatter.date(from: cleaned)
        }
        
        guard let date = parsedDate else { return nil }
        
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .full
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
    
    public static func parseCount(_ raw: String) -> Int64? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        if lower.contains("no view") { return 0 }
        
        let patterns: [(String, Double)] = [
            (#"([\d,.]+)\s*billion\b"#, 1_000_000_000),
            (#"([\d,.]+)\s*million\b"#, 1_000_000),
            (#"([\d,.]+)\s*thousand\b"#, 1_000),
            (#"([\d,.]+)\s*b\b"#, 1_000_000_000),
            (#"([\d,.]+)\s*m\b"#, 1_000_000),
            (#"([\d,.]+)\s*k\b"#, 1_000),
            (#"([\d,.]+)"#, 1),
        ]
        
        for (pattern, mult) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let ns = lower as NSString
            guard let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges >= 2,
                  let numRange = Range(match.range(at: 1), in: lower) else {
                continue
            }
            let numStr = String(lower[numRange]).replacingOccurrences(of: ",", with: "")
            guard let base = Double(numStr) else { continue }
            return Int64((base * mult).rounded())
        }
        return nil
    }
    
    public static func formatCompact(_ n: Int64) -> String {
        let absN = abs(n)
        if absN >= 1_000_000_000 {
            return trimDecimal(Double(n) / 1_000_000_000) + "B"
        }
        if absN >= 1_000_000 {
            return trimDecimal(Double(n) / 1_000_000) + "M"
        }
        if absN >= 1_000 {
            return trimDecimal(Double(n) / 1_000) + "K"
        }
        return "\(n)"
    }
    
    private static func trimDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded(.towardZero) {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

/// Direct decoder adapter for standardized gateway payloads
public enum InnerTubeParser {
    public static func parse(data: Data) -> (videos: [VideoItem], continuationToken: String?) {
        if let feed = try? JSONDecoder().decode(FeedResponse.self, from: data) {
            return (feed.items, feed.continuationToken)
        }
        return ([], nil)
    }
    
    public static func parseWithContinuation(data: Data) -> (videos: [VideoItem], continuationToken: String?) {
        return parse(data: data)
    }

    public static func parseWatchNext(data: Data) -> (details: VideoItem?, related: [VideoItem]) {
        if let resp = try? JSONDecoder().decode(WatchNextResponse.self, from: data) {
            return (resp.details, resp.items)
        }
        return (nil, [])
    }
}
