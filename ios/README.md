# TubeLite for iOS (iPhone & iPad)

A native **SwiftUI iOS application** for TubeLite designed specifically for mobile touch interactions and OLED displays.

- **100% Native SwiftUI UI**: Built from the ground up for iOS, replacing 10-foot remote focus engines with touch-first interactions, smooth drag gestures, and pull-to-refresh.
- **Mobile-Optimized Layouts**:
  - **Single-Column Feed**: Edge-to-edge 16:9 thumbnail video cards with duration badge overlays, 38pt channel avatars, 2-line title clamping, and compact stats line.
  - **Dedicated Mobile Watch Screen**: Top 16:9 inline player that auto-plays immediately upon selection, full video title, channel row with subscriber counts, collapsible description ("more / less"), and vertical "Up Next" related video rows with 1-tap seamless switching.
  - **Native Search**: Integrated search bar with instant submit and infinite-scroll pagination.
  - **1-Tap Google Pairing**: Mobile device pairing with 1-tap clipboard copying and direct Safari launch to `google.com/device` for instant sign-in without a second screen.
- **Hardware-Accelerated Playback**:
  - Primary: Native VisionOS HLS master manifest with RFC 8216 synthesis and clean schema normalization.
  - Sole Verified Fallback: Android progressive MP4 (itag 18, verified >60s).
  - Background audio playback capability (`AVAudioSession.setCategory(.playback)`).
  - Native Picture-in-Picture (`AVPictureInPictureController` / `VideoPlayer`).
- **Integrated SponsorBlock Engine**: Automatically skips sponsor segments in real time with an animated visual toast badge.
- **Cloudflare Worker Gateway Backend**: Connects directly to `https://litetube-gateway.anirudhkumar.workers.dev` with strict schema validation and telemetry hygiene.

---

## Project Structure

```
ios/
├── TubeLite.xcodeproj/          # Xcode Project (Open directly in Xcode)
│   └── project.pbxproj
└── TubeLite/
    ├── TubeLiteApp.swift        # App entry point with dark mode & audio session
    ├── Info.plist               # iOS configuration, background audio & permissions
    ├── Assets.xcassets/         # AppIcon & AccentColor catalog
    ├── Models/
    │   └── VideoItem.swift      # FeedResponse & WatchNextResponse models
    ├── Services/
    │   ├── TubeLiteGatewayClient.swift # Gateway API Client (Browse, Search, Next, SponsorBlock)
    │   ├── TubeLiteHLSBuilder.swift    # RFC 8216 HLS master & media playlist builder
    │   ├── TubeLiteResourceLoader.swift# Custom URL scheme resource loader
    │   ├── PlaybackPreloadCache.swift  # Stream preloading & LRU cache
    │   └── DeviceAuthService.swift     # Google device pairing & token manager
    └── Views/
        ├── Theme.swift          # Mobile design system, glowing TLBrandMark & tokens
        ├── RemoteImage.swift    # Multi-tier high-res thumbnail loader with memory cache
        ├── VideoCardView.swift  # Mobile video cards & compact RelatedVideoRow
        ├── PlayerView.swift     # AVPlayer with Picture-in-Picture & SponsorBlock toast
        ├── WatchView.swift      # Top sticky player, metadata & Up Next related list
        ├── HomeFeedView.swift   # Single-column feed with pull-to-refresh
        ├── SearchView.swift     # Search screen with pull-to-refresh & pagination
        ├── AccountView.swift    # 1-tap Google device pairing screen
        └── MainView.swift       # TabView navigation container & WatchView presenter
```

---

## Step-by-Step Setup & Running

### 1. Prerequisites
- **Xcode** (version 15.0 or later) installed on your Mac.
- An Apple ID (free or paid developer account) for running on physical iPhones/iPads.

### 2. Open the Project in Xcode
From your terminal:
```bash
open ios/TubeLite.xcodeproj
```
Or open Xcode, click **Open Existing Project**, and select `ios/TubeLite.xcodeproj`.

---

## Running in Dev Mode

### Option A: iOS Simulator
1. In Xcode, at the top toolbar next to `TubeLite`, click the destination device dropdown.
2. Select any **iPhone** or **iPad** simulator (e.g., iPhone 15 Pro, iPhone 16).
3. Press **Cmd + R** (or click the **Play** button).

### Option B: Physical iPhone or iPad
1. Connect your iPhone/iPad to your Mac via USB or over local Wi-Fi.
2. On your iPhone: Go to **Settings** → **Privacy & Security** → scroll to the bottom and enable **Developer Mode**.
3. In Xcode's project navigator, select the root **TubeLite** project → select the **TubeLite** target under "Targets" → **Signing & Capabilities**.
4. Check **Automatically manage signing** and choose your Personal Team.
5. Select your device from the device dropdown at the top and press **Cmd + R**.
