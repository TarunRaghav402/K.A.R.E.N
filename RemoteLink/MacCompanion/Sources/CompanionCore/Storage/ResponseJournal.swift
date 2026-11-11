import Foundation

public final class ResponseJournal: @unchecked Sendable {
    public static let shared = ResponseJournal()
    
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.karen.remote.companion.journal")

    public init(customPath: URL? = nil) {
        if let customPath = customPath {
            self.fileURL = customPath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let dir = home.appendingPathComponent(".karen", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("remote_responses.jsonl")
        }
    }

    public var journalFileURL: URL {
        fileURL
    }

    public func append(entry: JournalEntry) {
        queue.async {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            var line = data
            line.append(contentsOf: [0x0A]) // Newline \n

            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(line)
                    try? handle.close()
                }
            } else {
                try? line.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    public func readRecent(limit: Int = 50) -> [JournalEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var entries: [JournalEntry] = []
        let decoder = JSONDecoder()

        for line in lines.suffix(limit).reversed() {
            if let data = line.data(using: .utf8),
               let entry = try? decoder.decode(JournalEntry.self, from: data) {
                entries.append(entry)
            }
        }

        return entries
    }
}

