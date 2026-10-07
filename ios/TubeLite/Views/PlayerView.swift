import SwiftUI
import AVKit
import CoreMedia

/// Mobile AVPlayer component with native transport, Picture-in-Picture, and SponsorBlock skipping.
public struct PlayerView: View {
    public let videoId: String
    public let onOpenAccount: () -> Void
    public let onDismiss: () -> Void
    public let onDiagnostics: (TubeLiteGatewayClient.PlaybackDiagnostics?, String?) -> Void
    
    // Persistent active player session across view layout transitions
    public static var activePlayer: AVPlayer? = nil
    public static var activeVideoId: String? = nil
    public static var activeDiagnostics: TubeLiteGatewayClient.PlaybackDiagnostics? = nil
    public static var savedPlaybackTimes: [String: Double] = [:]
    
    public static func teardownActivePlayer() {
        activePlayer?.pause()
        activePlayer?.replaceCurrentItem(with: nil)
        activePlayer = nil
        activeVideoId = nil
        activeDiagnostics = nil
    }
    
    @State private var player: AVPlayer? = nil
    @State private var resourceLoader: TubeLiteResourceLoader? = nil
    @State private var timeObserverToken: Any? = nil
    @State private var telemetryTimeObserverToken: Any? = nil
    @State private var telemetrySession: TubeLiteGatewayClient.WatchTelemetrySession? = nil
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
        
        if Self.activeVideoId == videoId, let active = Self.activePlayer, active.currentItem != nil {
            _player = State(initialValue: active)
            _isLoadingStream = State(initialValue: false)
            _isBuffering = State(initialValue: active.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            _diagnostics = State(initialValue: Self.activeDiagnostics)
        }
    }
    
    public var body: some View {
        ZStack {
            Color.black
            
            if let player = player, streamError == nil {
                TubeLitePlayerViewControllerRepresentable(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if showSponsorToast {
                        toastBadge("Sponsor segment skipped", icon: "forward.fill")
                            .padding(.top, 16)
                            .animation(.easeInOut(duration: 0.25), value: showSponsorToast)
                            .allowsHitTesting(false)
                    }
                }
            }
            
            if streamError != nil {
                errorPanel
            } else if isLoadingStream || isBuffering {
                bufferingOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: videoId) { await setupAndPlay() }
        .onDisappear {
            publishDiagnostics()
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
                TLButton("Close", kind: .secondary, systemImage: "xmark", action: onDismiss)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
    
    private func setupAndPlay() async {
        if Self.activeVideoId == videoId, let existingPlayer = Self.activePlayer, let currentItem = existingPlayer.currentItem {
            self.player = existingPlayer
            self.diagnostics = Self.activeDiagnostics
            self.isLoadingStream = false
            self.isBuffering = existingPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
            publishDiagnostics()
            attachObservers(to: existingPlayer, item: currentItem, isReattaching: true)
            if existingPlayer.timeControlStatus != .playing && existingPlayer.status == .readyToPlay {
                existingPlayer.play()
            }
            return
        }
        
        teardownPlayer()
        await Self.configureAudioSession()
        
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
        if let tracking = resolution.trackingInfo {
            let session = TubeLiteGatewayClient.WatchTelemetrySession(videoId: videoId, trackingInfo: tracking)
            session.onLog = { message, _ in
                Task { @MainActor in
                    if var d = self.diagnostics {
                        d.log(message)
                        self.diagnostics = d
                    }
                    self.publishDiagnostics()
                }
            }
            self.telemetrySession = session
        }
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
        Self.activePlayer = newPlayer
        Self.activeVideoId = videoId
        Self.activeDiagnostics = self.diagnostics
        self.isLoadingStream = true
        self.isBuffering = true
        
        attachObservers(to: newPlayer, item: item, isReattaching: false)
    }
    
    private func attachObservers(to newPlayer: AVPlayer, item: AVPlayerItem, isReattaching: Bool) {
        removeObservers()
        
        itemStatusObserver = item.observe(\.status, options: [.new, .initial]) { [weak newPlayer] observedItem, _ in
            Task { @MainActor in
                guard self.player === newPlayer else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.inspectActiveAudioFormat(on: observedItem)
                    if !isReattaching {
                        if let saved = Self.savedPlaybackTimes[self.videoId], saved > 1.0 {
                            let resumeTime = CMTime(seconds: saved, preferredTimescale: 600)
                            newPlayer?.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                                newPlayer?.play()
                            }
                        } else {
                            newPlayer?.play()
                        }
                    }
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
                    Task {
                        let token = await DeviceAuthService.shared.getValidAccessToken()
                        self.telemetrySession?.start(accessToken: token)
                    }
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                case .paused:
                    if !self.isLoadingStream {
                        self.isBuffering = false
                        let curSec = CMTimeGetSeconds(observedPlayer.currentTime())
                        Task {
                            let token = await DeviceAuthService.shared.getValidAccessToken()
                            self.telemetrySession?.reportState(state: "paused", currentTime: curSec, accessToken: token)
                        }
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
                Self.savedPlaybackTimes.removeValue(forKey: self.videoId)
            }
        }
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        self.timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
            guard self.player === newPlayer else { return }
            let currentSec = CMTimeGetSeconds(time)
            if currentSec > 0.5 && !currentSec.isNaN && !currentSec.isInfinite {
                Self.savedPlaybackTimes[self.videoId] = currentSec
            }
            for segment in self.sponsorSegments {
                if currentSec >= segment.start && currentSec < segment.end {
                    let targetTime = CMTime(seconds: segment.end + 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                    newPlayer?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
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
        
        if self.telemetryTimeObserverToken == nil {
            let telemetryInterval = CMTime(seconds: 15.0, preferredTimescale: 1)
            self.telemetryTimeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: telemetryInterval, queue: .main) { [weak newPlayer] time in
                guard self.player === newPlayer else { return }
                let currentSec = CMTimeGetSeconds(time)
                let isPlaying = newPlayer?.timeControlStatus == .playing
                Task {
                    let token = await DeviceAuthService.shared.getValidAccessToken()
                    self.telemetrySession?.reportProgress(currentTime: currentSec, isPlaying: isPlaying, accessToken: token)
                }
            }
        }
        
        // Load SponsorBlock segments
        Task { @MainActor in
            let segments = await TubeLiteGatewayClient.shared.fetchSponsorSegments(videoId: videoId)
            guard !Task.isCancelled, self.player === newPlayer else { return }
            self.sponsorSegments = segments
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
    
    private func removeObservers() {
        if let token = telemetryTimeObserverToken, let activePlayer = player ?? Self.activePlayer {
            activePlayer.removeTimeObserver(token)
            telemetryTimeObserverToken = nil
        }
        if let token = timeObserverToken, let activePlayer = player ?? Self.activePlayer {
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
    }
    
    private func teardownPlayer() {
        let finalSec = (player ?? Self.activePlayer).map { CMTimeGetSeconds($0.currentTime()) } ?? 0.0
        let activeTelemetry = self.telemetrySession
        self.telemetrySession = nil
        Task {
            let token = await DeviceAuthService.shared.getValidAccessToken()
            activeTelemetry?.teardown(finalTime: finalSec, accessToken: token)
        }
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if Self.activePlayer === player {
            Self.activePlayer = nil
            Self.activeVideoId = nil
            Self.activeDiagnostics = nil
        }
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
        .padding(.top, 64)
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
    
    private static func configureAudioSession() async {
        await Task.detached(priority: .userInitiated) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                // Non-fatal fallback
            }
        }.value
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

/// UIKit representable embedding AVPlayerViewController with native playback controls,
/// Picture-in-Picture, and native full-screen support.
struct TubeLitePlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> PlayerViewControllerWrapper {
        let wrapper = PlayerViewControllerWrapper()
        wrapper.player = player
        return wrapper
    }
    
    func updateUIViewController(_ uiViewController: PlayerViewControllerWrapper, context: Context) {
        uiViewController.player = player
    }
}

final class PlayerViewControllerWrapper: UIViewController, AVPlayerViewControllerDelegate {
    static var isFullScreenActive: Bool = false
    static var isPiPActive: Bool = false
    
    var player: AVPlayer? {
        didSet {
            if playerViewController.player !== player {
                playerViewController.player = player
            }
        }
    }
    
    let playerViewController = AVPlayerViewController()
    
    deinit {
        Self.isFullScreenActive = false
        Self.isPiPActive = false
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        playerViewController.player = player
        playerViewController.showsPlaybackControls = true
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
        playerViewController.updatesNowPlayingInfoCenter = true
        playerViewController.videoGravity = .resizeAspect
        playerViewController.delegate = self
        
        addChild(playerViewController)
        view.addSubview(playerViewController.view)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        playerViewController.didMove(toParent: self)
    }
    
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willBeginFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
    ) {
        Self.isFullScreenActive = true
        coordinator.animate(alongsideTransition: nil) { context in
            if context.isCancelled {
                Self.isFullScreenActive = false
            }
        }
    }
    
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
    ) {
        coordinator.animate(alongsideTransition: nil) { context in
            if !context.isCancelled {
                Self.isFullScreenActive = false
            }
        }
    }
    
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Self.isPiPActive = true
    }
    
    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Self.isPiPActive = false
    }
}
