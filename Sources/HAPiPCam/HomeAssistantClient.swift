import Foundation
import Security

enum HomeAssistantError: LocalizedError, Equatable {
    case missingToken
    case invalidURL
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Missing Home Assistant access token"
        case .invalidURL:
            "Invalid Home Assistant URL"
        case let .httpStatus(code):
            "Home Assistant returned HTTP \(code)"
        case .invalidResponse:
            "Unexpected response from Home Assistant"
        }
    }
}

struct HomeAssistantClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func entity(_ entityID: String) async throws -> HAEntityState {
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("states")
                .appendingPathComponent(entityID)
        )
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HomeAssistantError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw HomeAssistantError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(HAEntityState.self, from: data)
    }
}

enum HomeAssistantToken {
    static let keychainService = "io.github.hapipcam.HAPiPCam"
    static let keychainAccount = "home-assistant-token"

    static func read(fallbackFileURL: URL?) throws -> String {
        if let keychainToken = readKeychain(), !keychainToken.isEmpty {
            return keychainToken
        }
        if let fallbackFileURL,
           let data = try? Data(contentsOf: fallbackFileURL),
           let text = String(data: data, encoding: .utf8) {
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }
        throw HomeAssistantError.missingToken
    }

    static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveKeychain(_ rawToken: String) {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasKeychainToken() -> Bool {
        readKeychain() != nil
    }
}
