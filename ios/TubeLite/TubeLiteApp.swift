import SwiftUI
import AVFoundation

@main
struct TubeLiteApp: App {
    init() {
        // 50MB RAM / 200MB Disk persistent URLCache for instant image display across launches
        let memoryCapacity = 50 * 1024 * 1024
        let diskCapacity = 200 * 1024 * 1024
        URLCache.shared = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: "tubelite_image_cache")
        
        Task.detached(priority: .utility) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
            } catch {
                print("[TubeLite] Audio session category configuration error: \(error)")
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
        }
    }
}
