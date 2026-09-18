import SwiftUI
import AVFoundation

@main
struct TubeLiteApp: App {
    init() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[TubeLite] Failed to initialize audio session: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
        }
    }
}
