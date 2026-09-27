import Foundation
import Testing
@testable import FTPKit

@Suite("Respuestas del servidor")
struct ReplyParserTests {
    @Test func singleLine() throws {
        var parser = FTPReplyParser()
        let reply = try #require(try parser.feed("220 Bienvenido"))
        #expect(reply.code == 220)
        #expect(reply.message == "Bienvenido")
    }

    @Test func multiLine() throws {
        var parser = FTPReplyParser()
        #expect(try parser.feed("211-Features:") == nil)
        #expect(try parser.feed(" MLST type*;size*;modify*;") == nil)
        #expect(try parser.feed(" UTF8") == nil)
        let reply = try #require(try parser.feed("211 End"))
        #expect(reply.code == 211)
        #expect(reply.lines.count == 4)
    }

    @Test func multiLineIgnoresOtherCodesInside() throws {
        var parser = FTPReplyParser()
        #expect(try parser.feed("230-Hola") == nil)
        #expect(try parser.feed("220 esto no cierra") == nil)
        #expect(try parser.feed("230 Sesión iniciada")?.code == 230)
    }

    @Test func malformed() {
        var parser = FTPReplyParser()
        #expect(throws: FTPError.self) { try parser.feed("hola") }
    }
}

@Suite("Modo pasivo y rutas")
struct PassiveParserTests {
    @Test func epsv() {
        #expect(FTPPassiveParser.parseEPSV("Entering Extended Passive Mode (|||6446|)") == 6446)
        #expect(FTPPassiveParser.parseEPSV("sin paréntesis") == nil)
    }

    @Test func pasv() throws {
        let result = try #require(FTPPassiveParser.parsePASV("Entering Passive Mode (192,168,1,2,19,137)."))
        #expect(result.host == "192.168.1.2")
        #expect(result.port == 19 * 256 + 137)
    }

    @Test func pasvWithoutParentheses() {
        #expect(FTPPassiveParser.parsePASV("Entering Passive Mode 10,0,0,1,4,1")?.port == 1025)
    }

    @Test func quotedPath() {
        #expect(FTPPassiveParser.parseQuotedPath("\"/home/luiggi\" is the current directory") == "/home/luiggi")
        #expect(FTPPassiveParser.parseQuotedPath("\"/a \"\"b\"\"\" es el actual") == "/a \"b\"")
    }

    @Test func paths() {
        #expect(FTPPath.join("/", "web") == "/web")
        #expect(FTPPath.join("/web", "index.html") == "/web/index.html")
        #expect(FTPPath.parent(of: "/web/css") == "/web")
        #expect(FTPPath.parent(of: "/web") == "/")
        #expect(FTPPath.parent(of: "/") == "/")
    }
}

@Suite("Listados")
struct ListParserTests {
    private var reference: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))!
    }

    @Test func mlsd() {
        let text = """
        type=cdir;modify=20260101000000; .
        type=pdir;modify=20260101000000; ..
        type=dir;modify=20260315101500;unix.mode=0755; Mis fotos
        type=file;size=2048;modify=20260102030405;unix.mode=0644; index.html\r
        """
        let items = FTPListParser.parseMLSD(text)
        #expect(items.count == 2)
        #expect(items[0].name == "Mis fotos")
        #expect(items[0].kind == .directory)
        #expect(items[1].name == "index.html")
        #expect(items[1].size == 2048)
        #expect(items[1].permissions == "0644")
        #expect(items[1].modified != nil)
    }

    @Test func unixList() throws {
        let text = """
        total 12
        drwxr-xr-x    2 ftp      ftp          4096 Mar 15 10:15 Mis fotos
        -rw-r--r--    1 ftp      ftp          2048 Jan 02  2025 index.html
        lrwxrwxrwx    1 ftp      ftp             7 Sep 01 08:00 www -> public
        drwxr-xr-x    2 ftp      ftp          4096 Sep 01 08:00 .
        """
        let items = FTPListParser.parseLIST(text, referenceDate: reference)
        #expect(items.map(\.name) == ["Mis fotos", "index.html", "www"])
        #expect(items[0].kind == .directory)
        #expect(items[1].size == 2048)
        #expect(items[2].kind == .symlink)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try #require(items[1].modified)
        #expect(calendar.component(.year, from: date) == 2025)
    }

    @Test func unixListWithoutGroup() {
        let items = FTPListParser.parseLIST("-rw-r--r--   1 owner   1234 Feb 10 12:00 notas.txt", referenceDate: reference)
        #expect(items.first?.name == "notas.txt")
        #expect(items.first?.size == 1234)
    }

    @Test func unixDateInFutureMeansLastYear() throws {
        let items = FTPListParser.parseLIST("-rw-r--r-- 1 a b 1 Dec 24 18:00 regalo.txt", referenceDate: reference)
        let date = try #require(items.first?.modified)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.year, from: date) == 2025)
    }

    @Test func dosList() {
        let text = """
        01-15-24  03:04PM       <DIR>          Carpeta nueva
        01-15-24  03:04PM                 1234 archivo.txt
        """
        let items = FTPListParser.parseLIST(text)
        #expect(items.count == 2)
        #expect(items[0].kind == .directory)
        #expect(items[0].name == "Carpeta nueva")
        #expect(items[1].size == 1234)
        #expect(items[1].modified != nil)
    }
}
