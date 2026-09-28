import Foundation

public enum FTPError: LocalizedError, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case untrustedCertificate(code: Int)
    /// Certificado sin fijar todavía: hay que preguntar al usuario si confía en él.
    case certificateNotPinned(fingerprint: String, summary: String)
    /// El certificado no coincide con el fijado: posible suplantación.
    case certificateChanged(expected: String, received: String, summary: String)
    /// La orden contiene saltos de línea u otros caracteres de control.
    case invalidCharacters(String)
    /// Nombre remoto peligroso (contiene "/", ".." o caracteres de control).
    case unsafeName(String)
    case timeout
    case malformedReply(String)
    case unexpectedReply(command: String, reply: FTPReply)
    case invalidPassiveReply(String)
    case notConnected
    case cancelled
    case localFile(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "No se pudo conectar: \(reason)"
        case .connectionClosed:
            return "El servidor cerró la conexión."
        case .untrustedCertificate(let code):
            return "El certificado TLS del servidor no es de confianza (\(code)): es autofirmado, ha caducado o pertenece a otro dominio. Conéctate usando el nombre de servidor que figura en el certificado o, si confías en él, activa «Aceptar certificados no válidos o autofirmados»."
        case .certificateNotPinned(let fingerprint, let summary):
            return "El servidor presenta un certificado que aún no has aceptado (\(summary)). Huella SHA-256: \(fingerprint)"
        case .certificateChanged(_, let received, let summary):
            return "¡Atención! El certificado del servidor ha cambiado (\(summary)). Puede tratarse de una suplantación. Nueva huella SHA-256: \(received)"
        case .invalidCharacters(let text):
            return "El nombre contiene caracteres no permitidos (saltos de línea o de control): \(text.debugDescription)"
        case .unsafeName(let name):
            return "Nombre de archivo no permitido por seguridad: \(name.debugDescription)"
        case .timeout:
            return "Se agotó el tiempo de espera."
        case .malformedReply(let line):
            return "Respuesta del servidor no válida: \(line)"
        case .unexpectedReply(let command, let reply):
            return "\(command) falló (\(reply.code)): \(reply.message)"
        case .invalidPassiveReply(let text):
            return "No se pudo interpretar la respuesta de modo pasivo: \(text)"
        case .notConnected:
            return "No hay conexión con el servidor."
        case .cancelled:
            return "Operación cancelada."
        case .localFile(let reason):
            return "Error con el archivo local: \(reason)"
        }
    }
}
