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
    /// Normalises a build-time / launch-time configuration string, returning
    /// nil when it carries no usable value.
    ///
    /// Rejects two kinds of placeholder, because both reach us as ordinary
    /// non-empty strings and are otherwise indistinguishable from a real value:
    ///   • `$(FOO)` — an Xcode build setting that was never defined, left
    ///     unexpanded by the "Process Info.plist" phase.
    ///   • `${FOO}` — a shell-style placeholder that xcodegen expands from the
    ///     environment at `xcodegen generate` time. If the variable wasn't
    ///     exported first, the literal `${FOO}` is written into the generated
    ///     scheme and handed to us as a launch environment variable.
    ///
    /// Without this, an unconfigured build sends the placeholder itself as a
    /// credential and the user sees a raw HTTP 401 from the provider instead of
    /// our own "not configured" message (issue: macOS Chat 401).
    /// Trims first, so a value that is only whitespace is treated as absent and
    /// a padded placeholder (`" ${FOO} "`) is still rejected. Returns the
    /// TRIMMED value, which matters because these strings become HTTP header
    /// values: a key sourced from a shell pipeline (`grep … | cut …`) commonly
    /// carries a trailing newline, and an invalid header value fails in a way
    /// that looks nothing like a configuration problem.
    private static func resolved(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("$("), !trimmed.hasPrefix("${") else { return nil }
        return trimmed
    }

    static let apiBaseURL: URL = {
        // 1. Runtime env var override (Xcode scheme or xcodebuild injection).
        if let override = resolved(ProcessInfo.processInfo.environment["API_URL"]),
           let url = URL(string: override) {
            return url
        }
        // 2. Build-time OTA URL embedded in Info.plist by ship.sh.
        if let otaURL = resolved(Bundle.main.object(forInfoDictionaryKey: "OTA_API_URL") as? String),
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
    /// On macOS the env var is the live path: the `DexterMac` scheme injects it
    /// via xcodegen's `${ANTHROPIC_API_KEY}` expansion, so the key is only real
    /// if the variable was exported before `xcodegen generate`. When it wasn't,
    /// the scheme carries the literal `${ANTHROPIC_API_KEY}` and `resolved`
    /// rejects it here rather than letting it reach the `x-api-key` header.
    ///
    /// Returns nil if neither source yields a usable value, in which case AI
    /// features surface a clear "Anthropic API key not configured" error.
    static let anthropicAPIKey: String? = {
        if let env = resolved(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]) {
            return env
        }
        if let plist = resolved(Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String) {
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
    ///
    /// That fallback is the reason this must reject placeholders (#327): an
    /// unexpanded `${OPENAI_API_KEY}` is a non-empty string, so before the
    /// guard it was treated as a real key and the app failed against OpenAI
    /// instead of degrading to the on-device recognizer. Hindi transcription
    /// is OpenAI-only and the on-device fallback is en-US, so accepting a
    /// placeholder silently broke a language the user relies on.
    static let openAIAPIKey: String? = {
        if let env = resolved(ProcessInfo.processInfo.environment["OPENAI_API_KEY"]) {
            return env
        }
        if let plist = resolved(Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String) {
            return plist
        }
        return nil
    }()
}
