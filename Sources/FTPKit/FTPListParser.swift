import Foundation

/// Interpreta las respuestas de MLSD (RFC 3659) y de LIST (formatos Unix y DOS/IIS).
public enum FTPListParser {

    // MARK: MLSD

    public static func parseMLSD(_ text: String) -> [FTPItem] {
        text.split(whereSeparator: \.isNewline).compactMap { parseMLSDLine(String($0)) }
    }

    static func parseMLSDLine(_ line: String) -> FTPItem? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            guard let eq = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<eq].lowercased()] = String(fact[fact.index(after: eq)...])
        }

        let type = facts["type"]?.lowercased() ?? "file"
        if type == "cdir" || type == "pdir" { return nil }

        let kind: FTPItem.Kind
        if type == "dir" {
            kind = .directory
        } else if type.hasPrefix("os.unix=symlink") || type.hasPrefix("os.unix=slink") {
            kind = .symlink
        } else {
            kind = .file
        }

        return FTPItem(
            name: name,
            kind: kind,
            size: (facts["size"] ?? facts["sizd"]).flatMap { Int64($0) },
            modified: facts["modify"].flatMap(parseMLSDTime),
            permissions: facts["unix.mode"] ?? facts["perm"]
        )
    }

    nonisolated(unsafe) private static let mlsdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    static func parseMLSDTime(_ value: String) -> Date? {
        mlsdFormatter.date(from: String(value.prefix(14)))
    }

    // MARK: LIST

    public static func parseLIST(_ text: String, referenceDate: Date = Date()) -> [FTPItem] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            if line.hasPrefix("total ") { return nil }
            return parseUnixLine(line, referenceDate: referenceDate) ?? parseDOSLine(line)
        }
    }

    private struct Token {
        let text: Substring
        let range: Range<String.Index>
    }

    private static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, !line[index].isWhitespace { index = line.index(after: index) }
            tokens.append(Token(text: line[start..<index], range: start..<index))
        }
        return tokens
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                                 "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func month(_ token: Substring) -> Int? {
        months.firstIndex(of: token.lowercased()).map { $0 + 1 }
    }

    /// Ejemplo: `drwxr-xr-x    2 user group     4096 Jan 01 12:00 Mis cosas`
    static func parseUnixLine(_ line: String, referenceDate: Date) -> FTPItem? {
        let tokens = tokenize(line)
        guard tokens.count >= 6,
              let typeChar = tokens[0].text.first,
              "-dlbcps".contains(typeChar),
              tokens[0].text.count >= 10
        else { return nil }

        // Localiza "<tamaño> <mes> <día> <hora|año>"; el número de columnas previas varía entre servidores.
        var monthIndex: Int?
        if tokens.count > 5 {
            for i in 2..<(tokens.count - 3) {
                if month(tokens[i].text) != nil,
                   Int64(tokens[i - 1].text) != nil,
                   Int(tokens[i + 1].text) != nil,
                   tokens[i + 2].text.contains(":") || (tokens[i + 2].text.count == 4 && Int(tokens[i + 2].text) != nil) {
                    monthIndex = i
                    break
                }
            }
        }
        guard let m = monthIndex, tokens.count > m + 3 else { return nil }

        var name = String(line[tokens[m + 3].range.lowerBound...])
        let kind: FTPItem.Kind
        switch typeChar {
        case "d": kind = .directory
        case "l":
            kind = .symlink
            if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        default: kind = .file
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        return FTPItem(
            name: name,
            kind: kind,
            size: Int64(tokens[m - 1].text),
            modified: unixDate(month: month(tokens[m].text)!,
                               day: Int(tokens[m + 1].text)!,
                               timeOrYear: tokens[m + 2].text,
                               referenceDate: referenceDate),
            permissions: String(tokens[0].text)
        )
    }

    private static func unixDate(month: Int, day: Int, timeOrYear: Substring, referenceDate: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents(month: month, day: day)

        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            components.hour = hour
            components.minute = minute
            components.year = calendar.component(.year, from: referenceDate)
            // Sin año significa "últimos seis meses": si la fecha queda en el futuro, es del año anterior.
            if let date = calendar.date(from: components), date > referenceDate.addingTimeInterval(2 * 86_400) {
                components.year! -= 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            components.year = year
        }
        return calendar.date(from: components)
    }

    nonisolated(unsafe) private static let dosFormatters: [DateFormatter] = ["MM-dd-yy hh:mma", "MM-dd-yyyy hh:mma", "MM-dd-yy HH:mm", "MM-dd-yyyy HH:mm"].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// Ejemplo: `01-15-24  03:04PM       <DIR>          Carpeta` o `01-15-24  03:04PM   1234 archivo.txt`
    static func parseDOSLine(_ line: String) -> FTPItem? {
        let tokens = tokenize(line)
        guard tokens.count >= 4 else { return nil }
        let dateParts = tokens[0].text.split(separator: "-")
        guard dateParts.count == 3, dateParts.allSatisfy({ Int($0) != nil }) else { return nil }

        let name = String(line[tokens[3].range.lowerBound...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let stamp = "\(tokens[0].text) \(tokens[1].text)"
        let date = dosFormatters.lazy.compactMap { $0.date(from: stamp) }.first

        if tokens[2].text.uppercased() == "<DIR>" {
            return FTPItem(name: name, kind: .directory, modified: date)
        }
        guard let size = Int64(tokens[2].text) else { return nil }
        return FTPItem(name: name, kind: .file, size: size, modified: date)
    }
}

/// Interpreta las respuestas 227 (PASV) y 229 (EPSV).
public enum FTPPassiveParser {
    /// `229 Entering Extended Passive Mode (|||6446|)` → 6446
    public static func parseEPSV(_ message: String) -> Int? {
        guard let open = message.firstIndex(of: "("),
              let close = message[open...].firstIndex(of: ")")
        else { return nil }
        let inner = message[message.index(after: open)..<close]
        guard let delimiter = inner.first else { return nil }
        let parts = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        guard parts.count >= 4, let port = Int(parts[3]), (1...65_535).contains(port) else { return nil }
        return port
    }

    /// `227 Entering Passive Mode (192,168,1,2,19,137)` → ("192.168.1.2", 5001)
    public static func parsePASV(_ message: String) -> (host: String, port: Int)? {
        let candidates = message.split(whereSeparator: { !($0.isASCII && ($0.isNumber || $0 == ",")) })
        for candidate in candidates {
            let parts = candidate.split(separator: ",", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            guard parts.count == 6, numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { continue }
            let host = numbers[0..<4].map(String.init).joined(separator: ".")
            return (host, numbers[4] * 256 + numbers[5])
        }
        return nil
    }

    /// `257 "/home/a ""b""" is current directory` → `/home/a "b"`
    public static func parseQuotedPath(_ message: String) -> String? {
        guard let first = message.firstIndex(of: "\"") else { return nil }
        var result = ""
        var index = message.index(after: first)
        while index < message.endIndex {
            let char = message[index]
            if char == "\"" {
                let next = message.index(after: index)
                if next < message.endIndex, message[next] == "\"" {
                    result.append("\"")
                    index = message.index(after: next)
                    continue
                }
                return result
            }
            result.append(char)
            index = message.index(after: index)
        }
        return nil
    }
}
