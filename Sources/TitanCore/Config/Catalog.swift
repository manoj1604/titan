import Foundation

/// Titan's curated defaults: which version of each runtime a new project gets and the
/// image that provides it. Updated with Titan releases so nobody hardcodes "latest".
public enum Catalog {
    public struct Runtime: Sendable, Equatable {
        public var id: String
        public var displayName: String
        /// Recommended version: current LTS / broadly supported stable.
        public var defaultVersion: String
        /// Rough compressed download size, for the plan screen (unpacked is ~3×).
        public var approxDownloadMB: Int
        let imageTemplate: String
        public func image(version: String? = nil) -> String {
            imageTemplate.replacingOccurrences(of: "{v}", with: version ?? defaultVersion)
        }
    }

    public static let node = Runtime(id: "node", displayName: "Node", defaultVersion: "22",
                                     approxDownloadMB: 390, imageTemplate: "node:{v}-bookworm")
    public static let python = Runtime(id: "python", displayName: "Python", defaultVersion: "3.12",
                                       approxDownloadMB: 360, imageTemplate: "python:{v}-bookworm")
    public static let go = Runtime(id: "go", displayName: "Go", defaultVersion: "1.23",
                                   approxDownloadMB: 290, imageTemplate: "golang:{v}-bookworm")
    public static let rust = Runtime(id: "rust", displayName: "Rust", defaultVersion: "1",
                                     approxDownloadMB: 510, imageTemplate: "rust:{v}-bookworm")

    /// Approximate download size of a service image, for the plan screen.
    public static func approxDownloadMB(service image: String) -> Int {
        switch ServicePreset.repository(of: image) {
        case "postgres": 160
        case "redis": 45
        default: 150
        }
    }
}
