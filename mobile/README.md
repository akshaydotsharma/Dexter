# Personal Dashboard iOS App

Native SwiftUI iOS app for the personal-dashboard webapp. Talks to the existing Express API.

## Stack
- SwiftUI + Swift 5
- iOS 17+
- URLSession for networking (async/await)
- SwiftData for read-only offline cache
- XcodeGen for project definition (no `.xcodeproj` checked in)

## Prerequisites
- Xcode 26+
- Homebrew + XcodeGen: `brew install xcodegen`
- Apple Developer account (for TestFlight)

## Setup

```bash
cd mobile
xcodegen generate
open PersonalDashboard.xcodeproj
```

Press Cmd+R to run in the simulator.

## Project structure

```
mobile/
├── project.yml                     # XcodeGen config
├── PersonalDashboard/
│   ├── App/                        # @main entry point
│   ├── Models/                     # Codable structs matching API
│   ├── Services/                   # APIClient + per-resource services
│   ├── Cache/                      # SwiftData models (offline cache)
│   ├── ViewModels/                 # @Observable view models
│   ├── Views/
│   │   ├── Dashboard/
│   │   ├── Tasks/
│   │   ├── Notes/
│   │   ├── Lists/
│   │   ├── Chat/
│   │   └── Components/             # Shared UI pieces
│   ├── Theme/                      # Colors, spacing, fonts
│   └── Resources/
│       ├── Assets.xcassets/
│       └── Preview Content/
```

## API base URL

Production: `https://personal-dashboard-g0w8.onrender.com/api`
Local dev: `http://localhost:3001/api` (when running the Express server)

Configured via `APIClient.baseURL`. We can switch via build config later.

## Known issue: AppIcon and Xcode 26.4 SDK / 26.3 simulator runtime mismatch

This machine has Xcode 26 with the iOS 26.4 SDK but only the iOS 26.3 simulator runtime
installed. Adding an `AppIcon.appiconset` or `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`
to `project.yml` triggers asset thinning, which fails with:

```
No simulator runtime version from ["23D8133"] available to use with iphonesimulator SDK version 23E252
```

**Fix when you're ready to add the app icon:**
1. Open Xcode → Settings → Components → install iOS 26.4 simulator runtime
2. Restore the AppIcon.appiconset and `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in
   `project.yml`
3. `xcodegen generate && xcodebuild ... build`

For now, the app runs without an icon (TestFlight builds may need an icon).

## Note on flaky `xcodebuild` destination resolution

After regenerating, the first `xcodebuild` invocation succeeds but subsequent invocations
sometimes fail with "Unable to find a destination matching...". Workaround: re-run
`xcodegen generate` between attempts, or use the Xcode IDE which is more lenient.

## TestFlight

1. Set `DEVELOPMENT_TEAM` in `project.yml` or via Xcode signing UI
2. `xcodegen generate`
3. In Xcode: Product → Archive → Distribute App → App Store Connect → Upload
4. App Store Connect → TestFlight tab → add internal testers

## Capture shortcut: enable the animated Dynamic Island

The Capture flow paints the Dynamic Island with our three-line motif while
the on-device pipeline runs. To get the animation showing during the
Dictate Text step (instead of iOS's default AppIcon thumbnail), add the
preflight intent at the top of your shortcut:

1. Open the Shortcuts app and edit your "Capture to Deks" shortcut.
2. At the very top, add the action **Start Capture Indicator** (search "Deks").
3. Leave Dictate Text and Capture to Deks below it as-is. Save.

From now on the island shows the animated lines through the whole flow.

## Common commands

```bash
# Regenerate project after changing project.yml
xcodegen generate

# Build for simulator
xcodebuild -project PersonalDashboard.xcodeproj -scheme PersonalDashboard \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run tests (when added)
xcodebuild -project PersonalDashboard.xcodeproj -scheme PersonalDashboard \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```
