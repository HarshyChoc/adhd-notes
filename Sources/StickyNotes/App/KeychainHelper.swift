import Foundation
import Security

final class KeychainHelper {
    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func loadString() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveString(_ value: String) {
        let data = Data(value.utf8)
        let status = SecItemCopyMatching(baseQuery() as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes = [kSecValueData as String: data]
            SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
            return
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteValue() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
