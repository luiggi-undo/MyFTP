import Foundation

/// Entrada de un listado remoto.
public struct FTPItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        case symlink
    }

    public var name: String
    public var kind: Kind
    public var size: Int64?
    public var modified: Date?
    public var permissions: String?

    public init(name: String, kind: Kind, size: Int64? = nil, modified: Date? = nil, permissions: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    public var id: String { name }
    public var isDirectory: Bool { kind == .directory }
}

/// Utilidades para rutas remotas (siempre separadas por "/").
public enum FTPPath {
    /// Un nombre recibido del servidor es seguro si no puede salirse de la carpeta de destino
    /// ni colar órdenes FTP: sin "/", sin "." o "..", y sin caracteres de control.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        return !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Indica si `url` queda dentro de `directory` una vez resueltos los "..".
    public static func isContained(_ url: URL, in directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    public static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(of path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
