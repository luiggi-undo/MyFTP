import Foundation

/// Respuesta del servidor FTP (RFC 959): código de tres cifras y una o varias líneas.
public struct FTPReply: Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    public var isPositivePreliminary: Bool { (100..<200).contains(code) }
    public var isPositiveCompletion: Bool { (200..<300).contains(code) }
    public var isPositiveIntermediate: Bool { (300..<400).contains(code) }

    /// Texto de la respuesta sin el prefijo del código.
    public var message: String {
        let prefix = String(code)
        return lines.map { line -> String in
            if line.hasPrefix(prefix), line.count >= 4 {
                return String(line.dropFirst(4))
            }
            return line.trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
    }

    public var description: String { lines.joined(separator: "\n") }
}

/// Agrupa líneas en respuestas completas, incluidas las multilínea ("211-" ... "211 ").
public struct FTPReplyParser {
    private var pendingCode: Int?
    private var pendingLines: [String] = []

    public init() {}

    public mutating func feed(_ line: String) throws -> FTPReply? {
        if let code = pendingCode {
            pendingLines.append(line)
            let prefix = String(code)
            if line == prefix || line.hasPrefix(prefix + " ") {
                let reply = FTPReply(code: code, lines: pendingLines)
                pendingCode = nil
                pendingLines = []
                return reply
            }
            return nil
        }

        let digits = line.prefix(3)
        guard digits.count == 3,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let code = Int(digits),
              (100...599).contains(code)
        else {
            throw FTPError.malformedReply(line)
        }

        if line.dropFirst(3).first == "-" {
            pendingCode = code
            pendingLines = [line]
            return nil
        }
        return FTPReply(code: code, lines: [line])
    }
}
