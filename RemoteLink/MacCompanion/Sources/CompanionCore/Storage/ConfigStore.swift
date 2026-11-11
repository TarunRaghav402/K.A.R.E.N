import Foundation

public final class ConfigStore: @unchecked Sendable {
    public static let shared = ConfigStore()
    
    private let fileURL: URL
    private let lock = NSLock()
    private var cachedConfig: CompanionConfig?

    public init(customPath: URL? = nil) {
        if let customPath = customPath {
            self.fileURL = customPath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let dir = home.appendingPathComponent(".karen", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("remote_link_cloud_config.json")
        }
    }

    public func load() -> CompanionConfig {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedConfig {
            return cached
        }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let config = try? JSONDecoder().decode(CompanionConfig.self, from: data) {
            self.cachedConfig = config
            return config
        }

        // Return default and save
        let config = CompanionConfig()
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: fileURL, options: .atomic)
        }
        self.cachedConfig = config
        return config
    }

    public func save(_ config: CompanionConfig) throws {
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
        self.cachedConfig = config
    }

    public func update(mutation: (inout CompanionConfig) -> Void) throws {
        var current = load()
        mutation(&current)
        try save(current)
    }
}

