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
    /// Huella del certificado del canal de control; los canales de datos deben presentar la misma.
    private var controlFingerprint: String?
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
        socket.onTLSEstablished = { [weak self, unowned socket] in
            try self?.verifyCertificate(of: socket, isControl: true)
        }
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
                // Fuerza el handshake y comprueba el certificado antes de enviar usuario y contraseña.
                _ = try send("NOOP")
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
        controlFingerprint = nil
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
        let items = useMLSD ? FTPListParser.parseMLSD(text) : FTPListParser.parseLIST(text)
        return items.filter { item in
            if FTPPath.isSafeName(item.name) { return true }
            log(.error, "Entrada ignorada por seguridad (nombre no válido): \(item.name.debugDescription)")
            return false
        }
    }

    public func makeDirectory(_ path: String) throws {
        try check(try send("MKD \(path)"), for: "MKD")
    }

    public func removeDirectory(_ path: String) throws {
        try check(try send("RMD \(path)"), for: "RMD")
    }

    /// Lista una carpeta sin cambiar el directorio actual.
    public func listDirectory(_ path: String) throws -> [FTPItem] {
        let previous = try currentDirectory()
        try changeDirectory(path)
        defer { try? changeDirectory(previous) }
        return try list()
    }

    /// Crea la carpeta si no existe.
    public func ensureDirectory(_ path: String) throws {
        let reply = try send("MKD \(path)")
        if reply.isPositiveCompletion { return }
        // MKD falla también cuando la carpeta ya existe: se comprueba entrando en ella.
        let previous = try currentDirectory()
        try changeDirectory(path)
        try changeDirectory(previous)
    }

    /// Borra una carpeta y todo su contenido.
    public func removeDirectoryRecursively(_ path: String) throws {
        for item in try listDirectory(path) {
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
    //
    // Con `resume: true` se continúa donde se quedó una transferencia anterior (REST):
    // en descargas a partir del tamaño del archivo local y en subidas a partir del
    // tamaño del remoto. Si el servidor no admite REST, se empieza desde el principio.
    // Si falla, se conservan los datos parciales para poder reanudar; si se cancela, se borran.

    public var supportsResume: Bool { features.contains("REST") }

    public func download(
        _ remotePath: String,
        to localURL: URL,
        resume: Bool = false,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil
    ) throws {
        let total = try size(of: remotePath)
        let reporter = ProgressReporter(total: total, handler: progress)
        do {
            try downloadFile(remotePath, to: localURL, remoteSize: total, resume: resume, cancellation: cancellation, reporter: reporter)
            reporter.finish()
        } catch FTPError.cancelled {
            try? FileManager.default.removeItem(at: localURL)
            throw FTPError.cancelled
        }
    }

    public func upload(
        _ localURL: URL,
        to remotePath: String,
        resume: Bool = false,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil
    ) throws {
        let total = Self.localSize(of: localURL)
        let reporter = ProgressReporter(total: total, handler: progress)
        try uploadFile(localURL, to: remotePath, localSize: total ?? 0, resume: resume, cancellation: cancellation, reporter: reporter)
        reporter.finish()
    }

    /// Descarga una carpeta remota con todo su contenido en `localURL`.
    /// `onFile` recibe la ruta relativa del archivo en curso, su posición y el total de archivos.
    public func downloadDirectory(
        _ remotePath: String,
        to localURL: URL,
        resume: Bool = false,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil,
        onFile: FTPFileHandler? = nil
    ) throws {
        do {
            var directories: [String] = []
            var files: [(relative: String, size: Int64?)] = []
            try collectRemote(remotePath, relative: "", directories: &directories, files: &files, cancellation: cancellation)

            let reporter = ProgressReporter(total: files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }, handler: progress)
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            for directory in directories {
                let destination = localURL.appendingPathComponent(directory)
                guard FTPPath.isContained(destination, in: localURL) else { throw FTPError.unsafeName(directory) }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            for (index, file) in files.enumerated() {
                if cancellation?.isCancelled == true { throw FTPError.cancelled }
                let destination = localURL.appendingPathComponent(file.relative)
                guard FTPPath.isContained(destination, in: localURL) else { throw FTPError.unsafeName(file.relative) }
                onFile?(file.relative, index + 1, files.count)
                try downloadFile(
                    FTPPath.join(remotePath, file.relative),
                    to: destination,
                    remoteSize: file.size,
                    resume: resume,
                    cancellation: cancellation,
                    reporter: reporter
                )
            }
            reporter.finish()
        } catch FTPError.cancelled {
            try? FileManager.default.removeItem(at: localURL)
            throw FTPError.cancelled
        }
    }

    /// Sube una carpeta local con todo su contenido a `remotePath` (se crea si no existe).
    public func uploadDirectory(
        _ localURL: URL,
        to remotePath: String,
        resume: Bool = false,
        cancellation: FTPCancellationToken? = nil,
        progress: FTPProgressHandler? = nil,
        onFile: FTPFileHandler? = nil
    ) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: keys) else {
            throw FTPError.localFile("no se puede leer \(localURL.path)")
        }

        let base = localURL.standardizedFileURL.pathComponents
        var directories: [String] = []
        var files: [(url: URL, relative: String, size: Int64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if url.lastPathComponent == ".DS_Store" || values.isSymbolicLink == true { continue }
            if !FTPPath.isSafeName(url.lastPathComponent) {
                log(.error, "Omitido por contener caracteres no permitidos: \(url.lastPathComponent.debugDescription)")
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let relative = url.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
            if values.isDirectory == true {
                directories.append(relative)
            } else {
                files.append((url, relative, Int64(values.fileSize ?? 0)))
            }
        }

        let reporter = ProgressReporter(total: files.reduce(Int64(0)) { $0 + $1.size }, handler: progress)
        try ensureDirectory(remotePath)
        for directory in directories {
            if cancellation?.isCancelled == true { throw FTPError.cancelled }
            try ensureDirectory(FTPPath.join(remotePath, directory))
        }
        for (index, file) in files.enumerated() {
            if cancellation?.isCancelled == true { throw FTPError.cancelled }
            onFile?(file.relative, index + 1, files.count)
            try uploadFile(file.url, to: FTPPath.join(remotePath, file.relative), localSize: file.size,
                           resume: resume, cancellation: cancellation, reporter: reporter)
        }
        reporter.finish()
    }

    /// Recorre una carpeta remota. Los enlaces simbólicos se omiten para evitar bucles.
    private func collectRemote(
        _ path: String,
        relative: String,
        directories: inout [String],
        files: inout [(relative: String, size: Int64?)],
        cancellation: FTPCancellationToken?
    ) throws {
        for item in try listDirectory(path) {
            if cancellation?.isCancelled == true { throw FTPError.cancelled }
            let childRelative = relative.isEmpty ? item.name : relative + "/" + item.name
            switch item.kind {
            case .directory:
                directories.append(childRelative)
                try collectRemote(FTPPath.join(path, item.name), relative: childRelative,
                                  directories: &directories, files: &files, cancellation: cancellation)
            case .file:
                files.append((childRelative, item.size))
            case .symlink:
                log(.info, "Enlace simbólico omitido: \(childRelative)")
            }
        }
    }

    private func downloadFile(
        _ remotePath: String,
        to localURL: URL,
        remoteSize: Int64?,
        resume: Bool,
        cancellation: FTPCancellationToken?,
        reporter: ProgressReporter
    ) throws {
        var offset: Int64 = 0
        if resume, supportsResume, let existing = Self.localSize(of: localURL) {
            offset = existing
        }
        if let remoteSize, offset > remoteSize { offset = 0 }
        if let remoteSize, offset > 0, offset == remoteSize {
            reporter.add(offset)
            return
        }

        let handle: FileHandle
        if offset > 0 {
            handle = try FileHandle(forWritingTo: localURL)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seekToEnd()
            reporter.add(offset)
            log(.info, "Reanudando \(remotePath) desde \(offset) bytes.")
        } else {
            guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
                throw FTPError.localFile("no se pudo crear \(localURL.path)")
            }
            handle = try FileHandle(forWritingTo: localURL)
        }
        defer { try? handle.close() }

        try withDataConnection(command: "RETR \(remotePath)", restartAt: offset) { data in
            while let chunk = try data.readChunk() {
                if cancellation?.isCancelled == true { throw FTPError.cancelled }
                try handle.write(contentsOf: chunk)
                reporter.add(Int64(chunk.count))
            }
        }
    }

    private func uploadFile(
        _ localURL: URL,
        to remotePath: String,
        localSize: Int64,
        resume: Bool,
        cancellation: FTPCancellationToken?,
        reporter: ProgressReporter
    ) throws {
        var offset: Int64 = 0
        if resume, supportsResume, let remoteSize = try size(of: remotePath) {
            offset = remoteSize
        }
        if offset > localSize { offset = 0 }
        if offset > 0, offset == localSize {
            reporter.add(offset)
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw FTPError.localFile(error.localizedDescription)
        }
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
            reporter.add(offset)
            log(.info, "Reanudando \(remotePath) desde \(offset) bytes.")
        }

        try withDataConnection(command: "STOR \(remotePath)", restartAt: offset) { data in
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                if cancellation?.isCancelled == true { throw FTPError.cancelled }
                try data.write(chunk)
                reporter.add(Int64(chunk.count))
            }
        }
    }

    private static func localSize(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
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
        socket.onTLSEstablished = { [weak self, unowned socket] in
            try self?.verifyCertificate(of: socket, isControl: false)
        }
        try socket.open(tls: protectData ? tlsSettings : nil)
        return socket
    }

    private func withDataConnection<T>(command: String, restartAt offset: Int64 = 0, _ body: (FTPSocket) throws -> T) throws -> T {
        let data = try openDataSocket()
        defer { data.close() }

        if offset > 0 {
            // REST debe ir justo antes de RETR/STOR.
            let reply = try send("REST \(offset)")
            guard reply.code == 350 else { throw FTPError.unexpectedReply(command: "REST", reply: reply) }
        }

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
        // Un salto de línea dentro de un nombre permitiría colar órdenes FTP adicionales.
        if command.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw FTPError.invalidCharacters(command)
        }
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

    /// Con certificados autofirmados (validación del sistema desactivada) se exige que el
    /// certificado coincida con la huella que el usuario aceptó, tanto en el canal de control
    /// como en los de datos. Con validación del sistema no hace falta comprobar nada más.
    private func verifyCertificate(of socket: FTPSocket, isControl: Bool) throws {
        guard configuration.allowInvalidCertificates else { return }
        guard let certificate = socket.peerCertificate() else {
            throw FTPError.connectionFailed("no se pudo leer el certificado del servidor")
        }

        if isControl {
            guard let pinned = configuration.pinnedFingerprint else {
                throw FTPError.certificateNotPinned(fingerprint: certificate.fingerprint, summary: certificate.summary)
            }
            guard pinned == certificate.fingerprint else {
                throw FTPError.certificateChanged(expected: pinned, received: certificate.fingerprint, summary: certificate.summary)
            }
            controlFingerprint = certificate.fingerprint
            log(.info, "Certificado verificado (huella fijada).")
        } else if certificate.fingerprint != controlFingerprint {
            throw FTPError.certificateChanged(
                expected: controlFingerprint ?? "",
                received: certificate.fingerprint,
                summary: certificate.summary
            )
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
