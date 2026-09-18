import SwiftUI
import AVKit
import CoreMedia

/// Mobile AVPlayer component with native transport, Picture-in-Picture, and SponsorBlock skipping.
public struct PlayerView: View {
    public let videoId: String
    public let onOpenAccount: () -> Void
    public let onDismiss: () -> Void
    public let onDiagnostics: (TubeLiteGatewayClient.PlaybackDiagnostics?, String?) -> Void
    
    @State private var player: AVPlayer? = nil
    @State private var resourceLoader: TubeLiteResourceLoader? = nil
    @State private var timeObserverToken: Any? = nil
    @State private var itemStatusObserver: NSKeyValueObservation? = nil
    @State private var timeControlObserver: NSKeyValueObservation? = nil
    @State private var failedObserver: Any? = nil
    @State private var errorLogObserver: Any? = nil
    @State private var didPlayToEndObserver: Any? = nil
    
    @State private var sponsorSegments: [TubeLiteGatewayClient.SponsorSegment] = []
    @State private var isLoadingStream: Bool = true
    @State private var isBuffering: Bool = true
    @State private var loadingStage: String = "Loading…"
    @State private var streamError: String? = nil
    @State private var requiresSignIn: Bool = false
    @State private var showSponsorToast: Bool = false
    
    @State private var diagnostics: TubeLiteGatewayClient.PlaybackDiagnostics? = nil
    @State private var avPlayerErrorLog: String? = nil
    
    public init(
        videoId: String,
        onOpenAccount: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {},
        onDiagnostics: @escaping (TubeLiteGatewayClient.PlaybackDiagnostics?, String?) -> Void = { _, _ in }
    ) {
        self.videoId = videoId
        self.onOpenAccount = onOpenAccount
        self.onDismiss = onDismiss
        self.onDiagnostics = onDiagnostics
    }
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let player = player, streamError == nil {
                VideoPlayer(player: player) {
                    VStack {
                        if showSponsorToast {
                            toastBadge("Sponsor segment skipped", icon: "forward.fill")
                        }
                        Spacer()
                    }
                    .animation(.easeInOut(duration: 0.25), value: showSponsorToast)
                }
            }
            
            if streamError != nil {
                errorPanel
            } else if isLoadingStream || isBuffering {
                bufferingOverlay
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .task(id: videoId) { await setupAndPlay() }
        .onDisappear {
            publishDiagnostics()
            teardownPlayer()
        }
    }
    
    private func publishDiagnostics() {
        onDiagnostics(diagnostics, avPlayerErrorLog)
    }
    
    private var bufferingOverlay: some View {
        ZStack {
            Color.black.opacity(isLoadingStream ? 0.95 : 0.4)
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                if isLoadingStream {
                    Text(loadingStage)
                        .font(.caption)
                        .foregroundColor(TLTheme.textSecondary)
                }
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: isLoadingStream || isBuffering)
    }
    
    private var errorPanel: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(TLTheme.warning)
            
            Text("Playback Unavailable")
                .font(.headline)
                .foregroundColor(TLTheme.textPrimary)
            
            Text(streamError ?? "Unable to play video.")
                .font(.caption)
                .foregroundColor(TLTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            
            if requiresSignIn {
                Text("Sign in with Google to watch this video.")
                    .font(.caption2)
                    .foregroundColor(TLTheme.accent)
            }
            
            HStack(spacing: 12) {
                TLButton("Try Again", kind: .primary, systemImage: "arrow.clockwise") {
                    Task { await setupAndPlay() }
                }
                if requiresSignIn {
                    TLButton("Sign In", kind: .secondary, systemImage: "person.crop.circle", action: onOpenAccount)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
    
    private func setupAndPlay() async {
        teardownPlayer()
        Self.configureAudioSession()
        
        isLoadingStream = true
        isBuffering = true
        loadingStage = "Loading…"
        streamError = nil
        requiresSignIn = false
        avPlayerErrorLog = nil
        
        loadingStage = "Resolving stream…"
        let resolution = await PlaybackPreloadCache.shared.resolution(for: videoId)
        guard !Task.isCancelled else { return }
        var diag = resolution.diagnostics
        diag.log("Stream: \(resolution.selectedHeight)p · \(diag.audioStatusDescription)")
        self.diagnostics = diag
        publishDiagnostics()
        
        guard resolution.isPlayable else {
            self.isLoadingStream = false
            self.isBuffering = false
            self.streamError = resolution.error ?? "Unable to resolve playable stream"
            self.requiresSignIn = resolution.requiresAuth
            return
        }
        
        loadingStage = "Buffering…"
        var item: AVPlayerItem?
        
        // 1. Primary Engine: Native HLS
        if let master = resolution.filteredHLSMaster {
            let loader = TubeLiteResourceLoader(
                masterPlaylist: master,
                videoPlaylist: resolution.videoPlaylist,
                audioPlaylist: resolution.audioPlaylist,
                subtitlePlaylists: resolution.subtitlePlaylists,
                subtitleTracks: resolution.subtitleTracks
            )
            self.resourceLoader = loader
            let asset = AVURLAsset(url: loader.masterURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            item = AVPlayerItem(asset: asset)
        } else if let hlsURL = resolution.hlsURL {
            self.resourceLoader = nil
            item = AVPlayerItem(url: hlsURL)
        }
        
        guard !Task.isCancelled else { return }
        
        // 2. Sole Proven Fallback: Progressive MP4
        if item == nil, let progressive = resolution.progressiveURL {
            self.resourceLoader = nil
            item = AVPlayerItem(url: progressive)
            if var d = self.diagnostics {
                d.log("Playing via fallback progressive MP4")
                self.diagnostics = d
            }
            publishDiagnostics()
        }
        
        guard !Task.isCancelled else { return }
        
        guard let item else {
            self.isLoadingStream = false
            self.isBuffering = false
            self.streamError = resolution.error ?? "No playable stream for this video"
            self.requiresSignIn = resolution.requiresAuth
            return
        }
        
        Self.applyMaxQualityPreferences(to: item, targetHeight: resolution.selectedHeight)
        
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .pause
        newPlayer.allowsExternalPlayback = true
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        
        guard !Task.isCancelled else {
            newPlayer.pause()
            newPlayer.replaceCurrentItem(with: nil)
            return
        }
        
        self.player = newPlayer
        self.isLoadingStream = true
        self.isBuffering = true
        
        itemStatusObserver = item.observe(\.status, options: [.new, .initial]) { [weak newPlayer] observedItem, _ in
            Task { @MainActor in
                guard self.player === newPlayer else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.inspectActiveAudioFormat(on: observedItem)
                    newPlayer?.play()
                case .failed:
                    self.capturePlayerFailure(from: observedItem)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        
        timeControlObserver = newPlayer.observe(\.timeControlStatus, options: [.new, .initial]) { observedPlayer, _ in
            Task { @MainActor in
                guard self.player === observedPlayer else { return }
                switch observedPlayer.timeControlStatus {
                case .playing:
                    self.diagnostics?.log("Playback started")
                    self.publishDiagnostics()
                    self.isLoadingStream = false
                    self.isBuffering = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                case .paused:
                    if !self.isLoadingStream {
                        self.isBuffering = false
                    }
                @unknown default:
                    break
                }
            }
        }
        
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard self.player === newPlayer else { return }
                self.appendErrorLog(from: item)
            }
        }
        
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notif in
            let err = notif.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard self.player === newPlayer else { return }
                if let err {
                    self.avPlayerErrorLog = (self.avPlayerErrorLog.map { $0 + "\n" } ?? "") + err.localizedDescription
                }
                self.streamError = "Playback error"
                self.isLoadingStream = false
                self.isBuffering = false
                self.teardownPlayer()
            }
        }
        
        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard self.player === newPlayer else { return }
                // Completed playback
            }
        }
        
        // Load SponsorBlock segments after playback begins
        Task { @MainActor in
            let segments = await TubeLiteGatewayClient.shared.fetchSponsorSegments(videoId: videoId)
            guard !Task.isCancelled, self.player === newPlayer else { return }
            self.sponsorSegments = segments
            guard !segments.isEmpty else { return }
            
            if self.timeObserverToken == nil {
                let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                self.timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                    guard self.player === newPlayer else { return }
                    let currentSec = CMTimeGetSeconds(time)
                    for segment in self.sponsorSegments {
                        if currentSec >= segment.start && currentSec < segment.end {
                            let targetTime = CMTime(seconds: segment.end + 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                            newPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                            Task { @MainActor in
                                guard self.player === newPlayer else { return }
                                self.showSponsorToast = true
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                guard self.player === newPlayer else { return }
                                self.showSponsorToast = false
                            }
                            break
                        }
                    }
                }
            }
        }
    }
    
    private func capturePlayerFailure(from item: AVPlayerItem) {
        var parts: [String] = []
        if let err = item.error {
            parts.append(Self.formatNSError(err))
        }
        appendErrorLog(from: item)
        if let avLog = avPlayerErrorLog, !avLog.isEmpty {
            parts.append(avLog)
        }
        let detailed = parts.joined(separator: "\n")
        print("[TubeLite] AVPlayerItem failed:\n\(detailed)")
        avPlayerErrorLog = detailed
        if var d = diagnostics {
            d.log("AVPlayer failed: \(detailed)")
            diagnostics = d
        }
        publishDiagnostics()
        if detailed.contains("-12660") || detailed.contains("CDN HTTP 403") {
            streamError = "Stream forbidden (HTTP 403). CDN rejected the media request."
        } else if detailed.contains("-11800") {
            streamError = "Playback failed (AVError -11800). See Logs for full detail."
        } else {
            streamError = "Playback Failed"
        }
        isLoadingStream = false
        isBuffering = false
        teardownPlayer()
    }
    
    private func appendErrorLog(from item: AVPlayerItem) {
        guard let errorLog = item.errorLog() else { return }
        var lines: [String] = avPlayerErrorLog.map { [$0] } ?? []
        for event in errorLog.events.suffix(8) {
            let line = "Code: \(event.errorStatusCode) (\(event.errorDomain)) | \(event.errorComment ?? "") | URI: \(event.uri ?? "")"
            if !lines.contains(line) {
                lines.append(line)
            }
        }
        avPlayerErrorLog = lines.joined(separator: "\n")
        publishDiagnostics()
    }
    
    private func teardownPlayer() {
        if let token = timeObserverToken, let activePlayer = player {
            activePlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observer = failedObserver {
            NotificationCenter.default.removeObserver(observer)
            failedObserver = nil
        }
        if let observer = errorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            errorLogObserver = nil
        }
        if let observer = didPlayToEndObserver {
            NotificationCenter.default.removeObserver(observer)
            didPlayToEndObserver = nil
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        resourceLoader = nil
        isLoadingStream = false
        isBuffering = false
    }
    
    private func toastBadge(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundColor(.white)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    
    private static func applyMaxQualityPreferences(to item: AVPlayerItem, targetHeight: Int) {
        let height = max(targetHeight, 1080)
        let width = height >= 2160 ? 3840 : (height >= 1440 ? 2560 : 1920)
        item.preferredMaximumResolution = CGSize(width: width, height: height)
        item.preferredPeakBitRate = height >= 2160 ? 35_000_000
            : (height >= 1440 ? 20_000_000 : 12_000_000)
        if #available(iOS 15.0, *) {
            item.preferredPeakBitRateForExpensiveNetworks = item.preferredPeakBitRate
            item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        }
    }
    
    private static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal fallback
        }
    }
    
    private func inspectActiveAudioFormat(on item: AVPlayerItem) {
        var hardwareChannels: Int? = nil
        for track in item.tracks {
            guard track.isEnabled,
                  let assetTrack = track.assetTrack,
                  assetTrack.mediaType == .audio else {
                continue
            }
            for desc in assetTrack.formatDescriptions {
                let audioDesc = desc as! CMAudioFormatDescription
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc) {
                    let channels = Int(asbd.pointee.mChannelsPerFrame)
                    if channels > 0 {
                        hardwareChannels = channels
                        break
                    }
                }
            }
            if hardwareChannels != nil { break }
        }
        
        if let channels = hardwareChannels {
            let isSurround = channels >= 6
            diagnostics?.audioChannels = channels
            diagnostics?.isSurroundActive = isSurround
            diagnostics?.isUpmixingSelected = !isSurround
            diagnostics?.audioRenderingMode = isSurround ? "5.1 Pass-Through" : "Spatial Upmixing"
            diagnostics?.log("CoreMedia Audio: \(channels)ch \(isSurround ? "(5.1 Surround)" : "(Spatial Upmixing)")")
            publishDiagnostics()
        }
    }
    
    private static func formatNSError(_ error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let err = current, depth < 6 {
            parts.append("\(err.domain) \(err.code): \(err.localizedDescription)")
            if let reason = err.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
                parts.append("reason: \(reason)")
            }
            current = err.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " | ")
    }
}
