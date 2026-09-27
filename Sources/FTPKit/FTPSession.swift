import Foundation

/// Envoltorio async/await de `FTPClient`. Ejecuta todas las operaciones en una
/// cola serie propia, ya que una conexión FTP solo admite una orden a la vez.
public final class FTPSession: @unchecked Sendable {
    public let configuration: FTPConfiguration
    private let client: FTPClient
    private let queue = DispatchQueue(label: "MyFTP.FTPSession")

    public init(configuration: FTPConfiguration, log: (@Sendable (FTPLogEntry) -> Void)? = nil) {
        self.configuration = configuration
        self.client = FTPClient(configuration: configuration)
        self.client.logHandler = log
    }

    public func connect() async throws {
        try await run { try $0.connect() }
    }

    public func disconnect() async {
        _ = try? await run { $0.disconnect() }
    }

    public var isConnected: Bool {
        get async { (try? await run { $0.isConnected }) ?? false }
    }

    public func currentDirectory() async throws -> String {
        try await run { try $0.currentDirectory() }
    }

    /// Cambia al directorio indicado y devuelve su ruta absoluta y su contenido.
    public func open(_ path: String) async throws -> (path: String, items: [FTPItem]) {
        try await run { client in
            try client.changeDirectory(path)
            let current = try client.currentDirectory()
            return (current, try client.list())
        }
    }

    public func makeDirectory(_ path: String) async throws {
        try await run { try $0.makeDirectory(path) }
    }

    public func delete(_ path: String, isDirectory: Bool) async throws {
        try await run { client in
            if isDirectory {
                try client.removeDirectoryRecursively(path)
            } else {
                try client.deleteFile(path)
            }
        }
    }

    public func rename(_ from: String, to: String) async throws {
        try await run { try $0.rename(from, to: to) }
    }

    public func download(
        _ remotePath: String,
        to localURL: URL,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil
    ) async throws {
        try await run { try $0.download(remotePath, to: localURL, cancellation: cancellation, progress: progress) }
    }

    public func upload(
        _ localURL: URL,
        to remotePath: String,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil
    ) async throws {
        try await run { try $0.upload(localURL, to: remotePath, cancellation: cancellation, progress: progress) }
    }

    private func run<T>(_ work: @escaping (FTPClient) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [client] in
                continuation.resume(with: Result { try work(client) })
            }
        }
    }
}
