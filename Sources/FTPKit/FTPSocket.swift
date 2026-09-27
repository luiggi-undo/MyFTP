import Foundation

struct FTPTLSSettings {
    var peerName: String
    var allowInvalidCertificates: Bool
}

/// Conexión TCP bloqueante sobre Foundation Streams.
///
/// Se usan Streams y no Network.framework porque el FTPS explícito necesita
/// activar TLS a mitad de la conexión (tras `AUTH TLS`), y `NWConnection` no
/// permite hacerlo sobre una conexión ya abierta.
/// Todas las llamadas deben hacerse desde una misma cola (la de `FTPSession`).
final class FTPSocket {
    private let input: InputStream
    private let output: OutputStream
    private var buffer = Data()
    private var readBuffer = [UInt8](repeating: 0, count: 65_536)
    /// La primera lectura tras activar TLS se hace bloqueante para que avance el handshake.
    private var needsBlockingRead = false
    private(set) var isClosed = false
    var timeout: TimeInterval

    init(host: String, port: Int, timeout: TimeInterval) throws {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inputStream, outputStream: &outputStream)
        guard let inputStream, let outputStream else {
            throw FTPError.connectionFailed("no se pudo crear el socket hacia \(host):\(port)")
        }
        self.input = inputStream
        self.output = outputStream
        self.timeout = timeout
    }

    deinit {
        close()
    }

    func open(tls: FTPTLSSettings? = nil) throws {
        if let tls { enableTLS(tls) }
        input.open()
        output.open()

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let error = input.streamError ?? output.streamError {
                throw FTPError.connectionFailed(error.localizedDescription)
            }
            let states = [input.streamStatus, output.streamStatus]
            if states.contains(.error) {
                throw FTPError.connectionFailed("error de socket")
            }
            if !states.contains(.notOpen) && !states.contains(.opening) {
                return
            }
            if Date() > deadline { throw FTPError.timeout }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Activa TLS sobre la conexión ya abierta (FTPS explícito).
    func startTLS(_ tls: FTPTLSSettings) {
        buffer.removeAll()
        enableTLS(tls)
    }

    private func enableTLS(_ tls: FTPTLSSettings) {
        var sslSettings: [String: Any] = [kCFStreamSSLPeerName as String: tls.peerName]
        if tls.allowInvalidCertificates {
            sslSettings[kCFStreamSSLValidatesCertificateChain as String] = false
        }
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        input.setProperty(sslSettings, forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
        needsBlockingRead = true
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        input.close()
        output.close()
    }

    // MARK: Escritura

    func write(_ data: Data) throws {
        guard !isClosed else { throw FTPError.connectionClosed }
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = output.write(base + offset, maxLength: raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 {
                    throw FTPError.connectionFailed(output.streamError?.localizedDescription ?? "error de escritura")
                }
                if output.streamStatus == .atEnd || output.streamStatus == .closed {
                    throw FTPError.connectionClosed
                }
                if Date() > deadline { throw FTPError.timeout }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        needsBlockingRead = false
    }

    // MARK: Lectura

    /// Lee una línea terminada en CRLF (o LF) sin el terminador.
    func readLine() throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                if line.last == 0x0D { line.removeLast() }
                return String(data: line, encoding: .utf8)
                    ?? String(data: line, encoding: .isoLatin1)
                    ?? ""
            }
            guard try fillBuffer() else { throw FTPError.connectionClosed }
        }
    }

    /// Devuelve el siguiente bloque de datos, o `nil` al llegar al final del flujo.
    func readChunk() throws -> Data? {
        if buffer.isEmpty {
            guard try fillBuffer() else { return nil }
        }
        let chunk = buffer
        buffer = Data()
        return chunk
    }

    func readToEnd() throws -> Data {
        var all = Data()
        while let chunk = try readChunk() { all.append(chunk) }
        return all
    }

    /// Añade datos al búfer. Devuelve `false` si el otro extremo cerró la conexión.
    private func fillBuffer() throws -> Bool {
        guard !isClosed else { throw FTPError.connectionClosed }

        if needsBlockingRead {
            needsBlockingRead = false
            return try readOnce()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if input.hasBytesAvailable {
                return try readOnce()
            }
            switch input.streamStatus {
            case .atEnd, .closed:
                return false
            case .error:
                throw FTPError.connectionFailed(input.streamError?.localizedDescription ?? "error de lectura")
            default:
                break
            }
            if Date() > deadline { throw FTPError.timeout }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func readOnce() throws -> Bool {
        let count = input.read(&readBuffer, maxLength: readBuffer.count)
        if count > 0 {
            buffer.append(readBuffer, count: count)
            return true
        }
        if count == 0 { return false }
        throw FTPError.connectionFailed(input.streamError?.localizedDescription ?? "error de lectura")
    }
}
