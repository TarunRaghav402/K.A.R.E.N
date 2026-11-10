import Foundation
import Security

/// Secure Keychain store for Google Gemini API credentials on macOS.
enum SearchCredentialStore {
    private static let service = "com.karen.assistant.gemini"
    private static let account = "gemini-api-key"

    // MARK: - Gemini API Key (macOS Keychain)

    static func loadGeminiKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    static func saveGeminiKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        guard !data.isEmpty else { return removeGeminiKey() }

        let query = baseQuery
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func removeGeminiKey() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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
