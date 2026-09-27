import Foundation
import FTPKit
import Security

/// Servidor guardado. La contraseña no se guarda aquí sino en el Llavero.
struct ServerBookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "Nuevo servidor"
    var host = ""
    var port = 21
    var username = ""
    var security: FTPConfiguration.Security = .explicitTLS
    var allowInvalidCertificates = false
    var initialPath = ""

    func configuration(password: String) -> FTPConfiguration {
        let anonymous = username.trimmingCharacters(in: .whitespaces).isEmpty
        return FTPConfiguration(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: anonymous ? "anonymous" : username,
            password: anonymous && password.isEmpty ? "anonymous@" : password,
            security: security,
            allowInvalidCertificates: allowInvalidCertificates
        )
    }
}

extension FTPConfiguration.Security {
    var label: String {
        switch self {
        case .plain: "FTP (sin cifrar)"
        case .explicitTLS: "FTPS explícito (AUTH TLS)"
        case .implicitTLS: "FTPS implícito"
        }
    }
}

/// Guarda la lista de servidores en ~/Library/Application Support/MyFTP/servers.json.
enum BookmarkStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MyFTP", isDirectory: true).appendingPathComponent("servers.json")
    }

    static func load() -> [ServerBookmark] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ServerBookmark].self, from: data)) ?? []
    }

    static func save(_ bookmarks: [ServerBookmark]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(bookmarks).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MyFTP: no se pudieron guardar los servidores: \(error)")
        }
    }
}

enum Keychain {
    private static let service = "com.undoestudio.MyFTP"

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for id: UUID) {
        deletePassword(for: id)
        guard !password.isEmpty else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrLabel as String: "MyFTP",
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
