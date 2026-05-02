import Foundation

/// Where the app's REST + SSE traffic goes.
///
/// Resolution order:
///   1. The `API_URL` environment variable (set in the Xcode scheme's
///      Run > Arguments > Environment Variables for local development,
///      or injected at archive time for OTA builds).
///   2. The default below: `http://localhost:3000/api`. This works for the
///      iOS simulator running on the same Mac as the dev server; physical
///      devices cannot reach Mac localhost and need either the env var
///      override or a public tunnel URL substituted here.
enum AppConfig {
    static let apiBaseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["API_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3000/api")!
    }()
}
