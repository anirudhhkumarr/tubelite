import Foundation

/// Helpers for stream format selection and metadata validation.
public enum TubeLiteHLSBuilder {
    /// Determines whether an audio format is the original audio track (never dubbed or descriptive).
    public static func isOriginalAudioTrack(format: [String: Any]) -> Bool {
        guard let track = format["audioTrack"] as? [String: Any] else {
            // No audioTrack dictionary provided: standard single-audio video, always original
            return true
        }
        
        let displayName = (track["displayName"] as? String)?.lowercased() ?? ""
        let trackId = (track["id"] as? String)?.lowercased() ?? ""
        
        // Exclude descriptive audio tracks (Audio Description / DVS for visually impaired)
        if displayName.contains("descriptive") || trackId.contains("descriptive") {
            return false
        }
        
        // Exclude explicit dubbed markers
        if displayName.contains("dubbed") || displayName.contains("(dub)") || trackId.contains("dub") {
            return false
        }
        
        // Explicitly marked default by YouTube
        if let isDefault = track["audioIsDefault"] as? Bool, isDefault {
            return true
        }
        if let isDefault = format["isDefaultAudioTrack"] as? Bool, isDefault {
            return true
        }
        
        // Explicitly contains "original" keyword in displayName or id
        if displayName.contains("original") || trackId.contains("original") {
            return true
        }
        
        // If audioTrack metadata is present and audioIsDefault is false / not original, it is a dubbed track!
        return false
    }
}
