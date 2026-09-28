import Foundation

/// Cliente FTP/FTPS síncrono. Cada llamada bloquea hasta completarse, así que
/// debe usarse desde un hilo de fondo; `FTPSession` lo envuelve con async/await.
///
/// No es seguro usarlo desde varios hilos a la vez. Es `@unchecked Sendable`
/// porque `FTPSession` serializa todos los accesos en su propia cola.
public final class FTPClient: @unchecked Sendable {
    public let configuration: FTPConfiguration
    public var logHandler: (@Sendable (FTPLogEntry) -> Void)?
    public private(set) var features: Set<String> = []
    public var isConnected: Bool { control.map { !$0.isClosed } ?? false }

    private var control: FTPSocket?
    private var protectData = false
    private var epsvUnsupported = false

    public init(configuration: FTPConfiguration) {
        self.configuration = configuration
    }

    private var tlsSettings: FTPTLSSettings {
        FTPTLSSettings(peerName: configuration.host, allowInvalidCertificates: configuration.allowInvalidCertificates)
    }

    // MARK: Conexión

    public func connect() throws {
        disconnect()
        log(.info, "Conectando a \(configuration.host):\(configuration.port)…")

        let socket = try FTPSocket(host: configuration.host, port: configuration.port, timeout: configuration.timeout)
        control = socket
        do {
            try socket.open(tls: configuration.security == .implicitTLS ? tlsSettings : nil)

            var greeting = try readReply()
            while greeting.code == 120 { greeting = try readReply() }
            try check(greeting, for: "Conexión")

            if configuration.security == .explicitTLS {
                let reply = try send("AUTH TLS")
                guard reply.code == 234 else { throw FTPError.unexpectedReply(command: "AUTH TLS", reply: reply) }
                socket.startTLS(tlsSettings)
                log(.info, "TLS activado en el canal de control.")
            }

            try login()

            if configuration.security != .plain {
                try check(try send("PBSZ 0"), for: "PBSZ")
                try check(try send("PROT P"), for: "PROT")
                protectData = true
            }

            features = try loadFeatures()
            if features.contains("UTF8") {
                _ = try send("OPTS UTF8 ON")
            }
            try check(try send("TYPE I"), for: "TYPE I")
            log(.info, "Conectado.")
        } catch {
            log(.error, error.localizedDescription)
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        guard let socket = control else { return }
        if !socket.isClosed {
            socket.timeout = 3
            _ = try? send("QUIT")
        }
        socket.close()
        control = nil
        protectData = false
        epsvUnsupported = false
        features = []
    }

    private func login() throws {
        var reply = try send("USER \(configuration.username)")
        if reply.code == 331 {
            reply = try send("PASS \(configuration.password)", logAs: "PASS ••••••")
        }
        if reply.code == 332 {
            throw FTPError.unexpectedReply(command: "ACCT", reply: reply)
        }
        try check(reply, for: "Inicio de sesión")
    }

    private func loadFeatures() throws -> Set<String> {
        let reply = try send("FEAT")
        guard reply.code == 211 else { return [] }
        var result: Set<String> = []
        for line in reply.lines.dropFirst().dropLast() {
            if let word = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first {
                result.insert(word.uppercased())
            }
        }
        return result
    }

    // MARK: Directorios

    public func currentDirectory() throws -> String {
        let reply = try send("PWD")
        guard reply.code == 257, let path = FTPPassiveParser.parseQuotedPath(reply.message) else {
            throw FTPError.unexpectedReply(command: "PWD", reply: reply)
        }
        return path
    }

    public func changeDirectory(_ path: String) throws {
        try check(try send("CWD \(path)"), for: "CWD")
    }

    /// Lista el directorio actual (usa MLSD si el servidor lo admite).
    public func list() throws -> [FTPItem] {
        let useMLSD = features.contains("MLST")
        let data = try withDataConnection(command: useMLSD ? "MLSD" : "LIST") { try $0.readToEnd() }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return useMLSD ? FTPListParser.parseMLSD(text) : FTPListParser.parseLIST(text)
    }

    public func makeDirectory(_ path: String) throws {
        try check(try send("MKD \(path)"), for: "MKD")
    }

    public func removeDirectory(_ path: String) throws {
        try check(try send("RMD \(path)"), for: "RMD")
    }

    /// Borra una carpeta y todo su contenido.
    public func removeDirectoryRecursively(_ path: String) throws {
        let previous = try currentDirectory()
        try changeDirectory(path)
        let items: [FTPItem]
        do {
            items = try list()
        } catch {
            try? changeDirectory(previous)
            throw error
        }
        try changeDirectory(previous)

        for item in items {
            let child = FTPPath.join(path, item.name)
            if item.isDirectory {
                try removeDirectoryRecursively(child)
            } else {
                try deleteFile(child)
            }
        }
        try removeDirectory(path)
    }

    public func deleteFile(_ path: String) throws {
        try check(try send("DELE \(path)"), for: "DELE")
    }

    public func rename(_ from: String, to: String) throws {
        let reply = try send("RNFR \(from)")
        guard reply.code == 350 else { throw FTPError.unexpectedReply(command: "RNFR", reply: reply) }
        try check(try send("RNTO \(to)"), for: "RNTO")
    }

    public func size(of path: String) throws -> Int64? {
        let reply = try send("SIZE \(path)")
        guard reply.code == 213 else { return nil }
        return Int64(reply.message.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Transferencias

    public func download(
        _ remotePath: String,
        to localURL: URL,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil
    ) throws {
        let total = try size(of: remotePath)
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw FTPError.localFile("no se pudo crear \(localURL.path)")
        }

        do {
            let handle = try FileHandle(forWritingTo: localURL)
            defer { try? handle.close() }
            let reporter = ProgressReporter(total: total, handler: progress)

            try withDataConnection(command: "RETR \(remotePath)") { data in
                while let chunk = try data.readChunk() {
                    if cancellation?.isCancelled == true { throw FTPError.cancelled }
                    try handle.write(contentsOf: chunk)
                    reporter.add(Int64(chunk.count))
                }
                reporter.finish()
            }
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    public func upload(
        _ localURL: URL,
        to remotePath: String,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw FTPError.localFile(error.localizedDescription)
        }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attributes?[.size] as? NSNumber)?.int64Value
        let reporter = ProgressReporter(total: total, handler: progress)

        try withDataConnection(command: "STOR \(remotePath)") { data in
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                if cancellation?.isCancelled == true { throw FTPError.cancelled }
                try data.write(chunk)
                reporter.add(Int64(chunk.count))
            }
            reporter.finish()
        }
    }

    // MARK: Canal de datos (modo pasivo)

    private func openDataSocket() throws -> FTPSocket {
        var port: Int?
        if !epsvUnsupported {
            let reply = try send("EPSV")
            if reply.code == 229 {
                port = FTPPassiveParser.parseEPSV(reply.message)
            } else {
                epsvUnsupported = true
            }
        }
        if port == nil {
            let reply = try send("PASV")
            guard reply.code == 227, let passive = FTPPassiveParser.parsePASV(reply.message) else {
                throw FTPError.invalidPassiveReply(reply.description)
            }
            // Se ignora la IP anunciada: detrás de NAT suele ser una dirección privada inalcanzable.
            port = passive.port
        }
        guard let port else { throw FTPError.invalidPassiveReply("sin puerto") }

        let socket = try FTPSocket(host: configuration.host, port: port, timeout: configuration.timeout)
        try socket.open(tls: protectData ? tlsSettings : nil)
        return socket
    }

    private func withDataConnection<T>(command: String, _ body: (FTPSocket) throws -> T) throws -> T {
        let data = try openDataSocket()
        defer { data.close() }

        let preliminary = try send(command)
        if preliminary.isPositiveCompletion {
            // Algunos servidores responden directamente 226 cuando no hay nada que enviar.
            return try body(data)
        }
        guard preliminary.code == 125 || preliminary.code == 150 else {
            throw FTPError.unexpectedReply(command: command, reply: preliminary)
        }

        let result: T
        do {
            result = try body(data)
        } catch {
            data.close()
            // Tras cortar el canal de datos el servidor envía 426/451 (o 226 si ya había terminado).
            control?.timeout = 5
            _ = try? readReply()
            control?.timeout = configuration.timeout
            throw error
        }
        data.close()
        try check(try readReply(), for: command)
        return result
    }

    // MARK: Canal de control

    @discardableResult
    private func send(_ command: String, logAs: String? = nil) throws -> FTPReply {
        guard let control, !control.isClosed else { throw FTPError.notConnected }
        log(.command, logAs ?? command)
        try control.write(Data((command + "\r\n").utf8))
        return try readReply()
    }

    private func readReply() throws -> FTPReply {
        guard let control else { throw FTPError.notConnected }
        var parser = FTPReplyParser()
        while true {
            let line = try control.readLine()
            if let reply = try parser.feed(line) {
                log(.reply, reply.description)
                if reply.code == 421 { control.close() }
                return reply
            }
        }
    }

    private func check(_ reply: FTPReply, for command: String) throws {
        guard reply.isPositiveCompletion else {
            throw FTPError.unexpectedReply(command: command, reply: reply)
        }
    }

    private func log(_ kind: FTPLogEntry.Kind, _ text: String) {
        logHandler?(FTPLogEntry(kind: kind, text: text))
    }
}

/// Limita las notificaciones de progreso a unas diez por segundo.
private final class ProgressReporter {
    private let total: Int64?
    private let handler: FTPProgressHandler?
    private var transferred: Int64 = 0
    private var lastReport = Date.distantPast

    init(total: Int64?, handler: FTPProgressHandler?) {
        self.total = total
        self.handler = handler
    }

    func add(_ bytes: Int64) {
        transferred += bytes
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.1 {
            lastReport = now
            handler?(transferred, total)
        }
    }

    func finish() {
        handler?(transferred, total)
    }
}
