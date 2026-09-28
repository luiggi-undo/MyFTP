import Foundation

public struct FTPConfiguration: Sendable, Hashable {
    public enum Security: String, Sendable, Codable, CaseIterable, Hashable {
        /// FTP sin cifrar.
        case plain
        /// FTPS explícito: conexión al puerto 21 y `AUTH TLS`.
        case explicitTLS
        /// FTPS implícito: TLS desde el primer byte, normalmente en el puerto 990.
        case implicitTLS

        public var defaultPort: Int { self == .implicitTLS ? 990 : 21 }
    }

    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var security: Security
    public var allowInvalidCertificates: Bool
    public var timeout: TimeInterval

    public init(
        host: String,
        port: Int? = nil,
        username: String = "anonymous",
        password: String = "anonymous@",
        security: Security = .explicitTLS,
        allowInvalidCertificates: Bool = false,
        timeout: TimeInterval = 30
    ) {
        self.host = host
        self.port = port ?? security.defaultPort
        self.username = username
        self.password = password
        self.security = security
        self.allowInvalidCertificates = allowInvalidCertificates
        self.timeout = timeout
    }
}

public struct FTPLogEntry: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        case command
        case reply
        case info
        case error
    }

    public let id = UUID()
    public let date = Date()
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Permite cancelar una transferencia desde otro hilo.
public final class FTPCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public typealias FTPProgressHandler = @Sendable (_ transferred: Int64, _ total: Int64?) -> Void

/// Archivo en curso dentro de una transferencia de carpeta: ruta relativa, posición y total.
public typealias FTPFileHandler = @Sendable (_ relativePath: String, _ index: Int, _ count: Int) -> Void
