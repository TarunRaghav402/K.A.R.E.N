import Foundation
import Security

/// Secure Keychain & local store for Google Gemini API credentials on macOS.
enum SearchCredentialStore {
    private static let service = "com.karen.assistant.gemini"
    private static let account = "gemini-api-key"

    private static var fallbackFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".karen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("gemini_key")
    }

    // MARK: - Gemini API Key (macOS Keychain with local secure fallback)

    static func loadGeminiKey() -> String? {
        // 1. Try environment variables
        if let envKey = ProcessInfo.processInfo.environment["KAREN_GEMINI_KEY"] ??
                        ProcessInfo.processInfo.environment["KAREN_LLM_KEY"] ??
                        ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
           !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Try macOS Keychain without blocking UI dialogs
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Fallback to user credentials file (~/.karen/gemini_key)
        let fileURL = fallbackFileURL
        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            let key = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }

        return nil
    }

    @discardableResult
    static func saveGeminiKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeGeminiKey() }
        let data = Data(trimmed.utf8)

        // Save to Keychain
        let query = baseQuery
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            _ = SecItemAdd(item as CFDictionary, nil)
        }

        // Also save to user config file with owner-only permissions (0600)
        let fileURL = fallbackFileURL
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        return true
    }

    @discardableResult
    static func removeGeminiKey() -> Bool {
        _ = SecItemDelete(baseQuery as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackFileURL)
        return true
    }

    // MARK: - Live Key Validation

    /// Validates a Google Gemini API key by performing an authenticated request to list models.
    static func validateGeminiKey(_ key: String) async -> (isValid: Bool, message: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "API key cannot be empty.")
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmed)") else {
            return (false, "Invalid endpoint URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Unexpected response from Gemini API.")
            }

            if httpResponse.statusCode == 200 {
                return (true, "Valid Gemini API Key. Google Search grounding is ready.")
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                return (false, message)
            }

            if httpResponse.statusCode == 400 || httpResponse.statusCode == 403 {
                return (false, "Invalid Gemini API key. Check the key at Google AI Studio.")
            } else if httpResponse.statusCode == 429 {
                return (false, "Gemini API rate limit exceeded.")
            } else {
                return (false, "Gemini API returned HTTP \(httpResponse.statusCode).")
            }
        } catch {
            return (false, "Network error: \(error.localizedDescription)")
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
