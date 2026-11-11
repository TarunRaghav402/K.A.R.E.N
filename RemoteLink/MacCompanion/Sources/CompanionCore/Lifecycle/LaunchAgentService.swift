import Foundation

public final class LaunchAgentService: Sendable {
    public static let shared = LaunchAgentService()
    public static let label = "com.karen.remote.companion"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    public init() {}

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func generatePlist(binaryPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(home)/.karen/logs/companion.log</string>
            <key>StandardErrorPath</key>
            <string>\(home)/.karen/logs/companion.error.log</string>
        </dict>
        </plist>
        """
    }

    public func install(binaryPath: String? = nil) throws {
        let path: String
        if let explicitPath = binaryPath {
            path = explicitPath
        } else {
            // Default to current running process executable path
            path = CommandLine.arguments[0]
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logDir = home.appendingPathComponent(".karen/logs", isDirectory: true)

        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let plistContent = generatePlist(binaryPath: path)
        try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    public func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

