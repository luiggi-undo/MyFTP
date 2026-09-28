import CryptoKit
import Foundation
import Security

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
    /// Se llama una vez, tras la primera lectura o escritura con TLS activo (handshake completado).
    /// Si lanza un error, la operación falla y los datos leídos no se entregan.
    var onTLSEstablished: (() throws -> Void)?
    private var pendingTLSCheck = false

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
                throw Self.describe(error)
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
        var sslSettings: [String: Any] = [
            kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL as String,
            kCFStreamSSLPeerName as String: tls.peerName,
        ]
        if tls.allowInvalidCertificates {
            // Omite la comprobación de la cadena y del nombre: acepta certificados autofirmados.
            sslSettings[kCFStreamSSLValidatesCertificateChain as String] = false
        }
        let key = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
        input.setProperty(sslSettings, forKey: key)
        output.setProperty(sslSettings, forKey: key)
        needsBlockingRead = true
        pendingTLSCheck = true
    }

    private func runTLSCheckIfNeeded() throws {
        guard pendingTLSCheck else { return }
        pendingTLSCheck = false
        try onTLSEstablished?()
    }

    /// Huella SHA-256 y descripción del certificado del servidor (disponible tras el handshake).
    func peerCertificate() -> (fingerprint: String, summary: String)? {
        let key = Stream.PropertyKey(kCFStreamPropertySSLPeerTrust as String)
        guard let value = input.property(forKey: key) else { return nil }
        let object = value as AnyObject
        guard CFGetTypeID(object) == SecTrustGetTypeID() else { return nil }
        let trust = object as! SecTrust
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "sin nombre"
        return (fingerprint, summary)
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
                    throw Self.describe(output.streamError, fallback: "error de escritura")
                }
                if output.streamStatus == .atEnd || output.streamStatus == .closed {
                    throw FTPError.connectionClosed
                }
                if Date() > deadline { throw FTPError.timeout }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        needsBlockingRead = false
        try runTLSCheckIfNeeded()
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
                throw Self.describe(input.streamError, fallback: "error de lectura")
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
            try runTLSCheckIfNeeded()
            buffer.append(readBuffer, count: count)
            return true
        }
        if count == 0 { return false }
        throw Self.describe(input.streamError, fallback: "error de lectura")
    }

    // MARK: Errores

    /// Traduce los errores de socket y de TLS (códigos OSStatus de Secure Transport) a mensajes claros.
    static func describe(_ error: Error?, fallback: String = "error de socket") -> FTPError {
        guard let error else { return .connectionFailed(fallback) }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            switch nsError.code {
            case -9807, -9808, -9812, -9813, -9814, -9815, -9843:
                // errSSLXCertChainInvalid, errSSLBadCert, errSSLUnknownRootCert, errSSLNoRootCert,
                // errSSLCertExpired, errSSLCertNotYetValid, errSSLHostNameMismatch
                return .untrustedCertificate(code: nsError.code)
            case -9806, -9805:
                // errSSLClosedAbort, errSSLClosedGraceful
                return .connectionFailed("el servidor cortó la negociación TLS (\(nsError.code)). Comprueba el tipo de seguridad (FTPS explícito o implícito) y el puerto.")
            case -9800 ... -9899:
                return .connectionFailed("error TLS \(nsError.code)")
            default:
                break
            }
        }
        return .connectionFailed(error.localizedDescription)
    }
}
