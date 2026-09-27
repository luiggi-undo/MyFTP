import AppKit
import FTPKit
import Observation

@Observable
@MainActor
final class Transfer: Identifiable {
    enum Direction {
        case download
        case upload
    }

    enum State: Equatable {
        case queued
        case running
        case completed
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let direction: Direction
    let name: String
    let remotePath: String
    var localURL: URL?
    var transferred: Int64 = 0
    var total: Int64?
    var state: State = .queued
    @ObservationIgnored let token = FTPCancellationToken()

    init(direction: Direction, name: String, remotePath: String, localURL: URL?) {
        self.direction = direction
        self.name = name
        self.remotePath = remotePath
        self.localURL = localURL
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(transferred) / Double(total))
    }

    var isFinished: Bool {
        switch state {
        case .completed, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

/// Estado de una conexión abierta: navegación, operaciones y cola de transferencias.
///
/// Las transferencias usan una segunda conexión para que la navegación no se
/// bloquee mientras se sube o descarga un archivo.
@Observable
@MainActor
final class BrowserModel {
    let bookmark: ServerBookmark
    let configuration: FTPConfiguration

    private(set) var path = "/"
    private(set) var items: [FTPItem] = []
    private(set) var isLoading = false
    private(set) var log: [FTPLogEntry] = []
    private(set) var transfers: [Transfer] = []
    var errorMessage: String?

    @ObservationIgnored private var session: FTPSession!
    @ObservationIgnored private var transferSession: FTPSession?
    @ObservationIgnored private var transferTask: Task<Void, Never>?

    private static let maxLogEntries = 2_000

    init(bookmark: ServerBookmark, configuration: FTPConfiguration) {
        self.bookmark = bookmark
        self.configuration = configuration
        self.session = FTPSession(configuration: configuration, log: makeLogger(prefix: nil))
    }

    var title: String {
        bookmark.name.isEmpty ? configuration.host : bookmark.name
    }

    // MARK: Conexión

    func connect() async throws {
        try await session.connect()
        let initial = bookmark.initialPath.trimmingCharacters(in: .whitespaces)
        let target: String
        if initial.isEmpty {
            target = try await session.currentDirectory()
        } else {
            target = initial
        }
        let result = try await session.open(target)
        path = result.path
        items = result.items
    }

    func shutdown() {
        for transfer in transfers where !transfer.isFinished {
            transfer.token.cancel()
        }
        transferTask?.cancel()
        let session = self.session
        let transferSession = self.transferSession
        Task.detached {
            await transferSession?.disconnect()
            await session?.disconnect()
        }
    }

    // MARK: Navegación

    func open(_ newPath: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await session.open(newPath)
            path = result.path
            items = result.items
        } catch {
            report(error)
        }
    }

    func refresh() {
        Task { await open(path) }
    }

    func goUp() {
        Task { await open(FTPPath.parent(of: path)) }
    }

    func activate(_ item: FTPItem) {
        if item.kind == .file {
            download([item])
        } else {
            Task { await open(FTPPath.join(path, item.name)) }
        }
    }

    // MARK: Operaciones

    func makeDirectory(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let directory = path
        perform { try await $0.makeDirectory(FTPPath.join(directory, name)) }
    }

    func rename(_ item: FTPItem, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.name else { return }
        let directory = path
        perform { try await $0.rename(FTPPath.join(directory, item.name), to: FTPPath.join(directory, newName)) }
    }

    func delete(_ selected: [FTPItem]) {
        guard !selected.isEmpty else { return }
        let directory = path
        perform { session in
            for item in selected {
                try await session.delete(FTPPath.join(directory, item.name), isDirectory: item.isDirectory)
            }
        }
    }

    /// Ejecuta una operación y vuelve a cargar el listado, haya fallado o no.
    private func perform(_ operation: @escaping (FTPSession) async throws -> Void) {
        Task {
            isLoading = true
            do {
                try await operation(session)
            } catch {
                report(error)
            }
            await open(path)
        }
    }

    // MARK: Transferencias

    func download(_ selected: [FTPItem]) {
        let files = selected.filter { $0.kind != .directory }
        if files.count < selected.count {
            errorMessage = "Por ahora solo se pueden descargar archivos, no carpetas."
        }
        for item in files {
            enqueue(Transfer(direction: .download, name: item.name, remotePath: FTPPath.join(path, item.name), localURL: nil))
        }
    }

    func upload(_ urls: [URL]) {
        var skipped = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                skipped = true
                continue
            }
            let name = url.lastPathComponent
            enqueue(Transfer(direction: .upload, name: name, remotePath: FTPPath.join(path, name), localURL: url))
        }
        if skipped {
            errorMessage = "Por ahora solo se pueden subir archivos, no carpetas."
        }
    }

    func cancel(_ transfer: Transfer) {
        transfer.token.cancel()
        if transfer.state == .queued { transfer.state = .cancelled }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.isFinished }
    }

    func revealInFinder(_ transfer: Transfer) {
        guard let url = transfer.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func enqueue(_ transfer: Transfer) {
        transfers.append(transfer)
        if transferTask == nil {
            transferTask = Task { await runTransferQueue() }
        }
    }

    private func runTransferQueue() async {
        while !Task.isCancelled, let next = transfers.first(where: { $0.state == .queued }) {
            await run(next)
        }
        transferTask = nil
    }

    private func run(_ transfer: Transfer) async {
        transfer.state = .running
        let progress: FTPProgressHandler = { done, total in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    transfer.transferred = done
                    transfer.total = total
                }
            }
        }

        do {
            let session = try await connectedTransferSession()
            switch transfer.direction {
            case .download:
                let destination = Self.uniqueDownloadURL(for: transfer.name)
                transfer.localURL = destination
                try await session.download(transfer.remotePath, to: destination, cancellation: transfer.token, progress: progress)
            case .upload:
                guard let source = transfer.localURL else { throw FTPError.localFile("archivo de origen no indicado") }
                try await session.upload(source, to: transfer.remotePath, cancellation: transfer.token, progress: progress)
                if FTPPath.parent(of: transfer.remotePath) == path {
                    refresh()
                }
            }
            transfer.state = .completed
        } catch FTPError.cancelled {
            transfer.state = .cancelled
        } catch {
            transfer.state = .failed(error.localizedDescription)
            // La conexión puede haber quedado en mal estado: se abrirá otra para la siguiente.
            await transferSession?.disconnect()
            transferSession = nil
        }
    }

    private func connectedTransferSession() async throws -> FTPSession {
        if let transferSession, await transferSession.isConnected {
            return transferSession
        }
        let newSession = FTPSession(configuration: configuration, log: makeLogger(prefix: "⇅ "))
        try await newSession.connect()
        transferSession = newSession
        return newSession
    }

    private static func uniqueDownloadURL(for name: String) -> URL {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return url
    }

    // MARK: Registro y errores

    func clearLog() {
        log.removeAll()
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func appendLog(_ entry: FTPLogEntry) {
        log.append(entry)
        if log.count > Self.maxLogEntries {
            log.removeFirst(log.count - Self.maxLogEntries)
        }
    }

    private func makeLogger(prefix: String?) -> @Sendable (FTPLogEntry) -> Void {
        { [weak self] entry in
            let entry = prefix.map { FTPLogEntry(kind: entry.kind, text: $0 + entry.text) } ?? entry
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.appendLog(entry)
                }
            }
        }
    }
}
