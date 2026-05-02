import Foundation

enum AppConfig {
    static let apiBaseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["API_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://economies-ebook-organize-proxy.trycloudflare.com/api")!
    }()
}
