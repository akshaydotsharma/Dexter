import Foundation

/// Where the app's REST + SSE traffic goes.
///
/// Resolution order:
///   1. The `API_URL` environment variable (set in the Xcode scheme's
///      Run > Arguments > Environment Variables for local development,
///      or injected at archive time for OTA builds via xcodebuild).
///   2. The `OTA_API_URL` Info.plist key, injected by `mobile/ota/ship.sh`
///      at archive time via `xcodebuild OTA_API_URL=https://<host>/api`.
///      This makes OTA-installed builds reach the Mac over Tailscale
///      automatically, without any manual configuration on the device.
///   3. The default `http://localhost:3000/api`. This works for the iOS
///      simulator on the same Mac as the dev server; physical devices on a
///      different host need option 1 or 2.
enum AppConfig {
    static let apiBaseURL: URL = {
        // 1. Runtime env var override (Xcode scheme or xcodebuild injection).
        if let override = ProcessInfo.processInfo.environment["API_URL"],
           let url = URL(string: override) {
            return url
        }
        // 2. Build-time OTA URL embedded in Info.plist by ship.sh.
        if let otaURL = Bundle.main.object(forInfoDictionaryKey: "OTA_API_URL") as? String,
           !otaURL.isEmpty,
           !otaURL.hasPrefix("$("),   // guard against unexpanded xcconfig variables
           let url = URL(string: otaURL) {
            return url
        }
        // 3. Local simulator default.
        return URL(string: "http://localhost:3000/api")!
    }()

    /// Anthropic Messages API key. Source order:
    ///   1. `ANTHROPIC_API_KEY` env var (Xcode scheme for local sim runs).
    ///   2. `ANTHROPIC_API_KEY` Info.plist key, baked at archive time by
    ///      `mobile/ota/ship-lan.sh` so OTA-installed builds carry their own
    ///      key without any per-device setup.
    /// Returns nil if neither is set, in which case AI features surface a
    /// clear "Anthropic API key not configured" error to the user.
    static let anthropicAPIKey: String? = {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String,
           !plist.isEmpty,
           !plist.hasPrefix("$(") {
            return plist
        }
        return nil
    }()

    /// OpenAI API key, used for cloud voice transcription (issue #151).
    /// Source order mirrors `anthropicAPIKey` exactly:
    ///   1. `OPENAI_API_KEY` env var (Xcode scheme for local sim runs).
    ///   2. `OPENAI_API_KEY` Info.plist key, baked at archive time by
    ///      `mobile/ota/ship-lan.sh` so OTA-installed builds carry their own
    ///      key without any per-device setup.
    /// Returns nil if neither is set, in which case `VoiceDictation` falls
    /// back to the on-device English recognizer rather than failing.
    static let openAIAPIKey: String? = {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String,
           !plist.isEmpty,
           !plist.hasPrefix("$(") {
            return plist
        }
        return nil
    }()
}
