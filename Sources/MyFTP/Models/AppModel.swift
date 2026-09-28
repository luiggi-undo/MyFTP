import Foundation
import FTPKit
import Observation

/// Pregunta al usuario si confía en un certificado autofirmado (o en uno que ha cambiado).
struct CertificatePrompt: Identifiable {
    let id = UUID()
    let bookmarkID: ServerBookmark.ID
    let fingerprint: String
    let summary: String
    let changed: Bool
}

@Observable
@MainActor
final class AppModel {
    var bookmarks: [ServerBookmark] = BookmarkStore.load()
    var selection: ServerBookmark.ID?
    var browser: BrowserModel?
    var isConnecting = false
    var errorMessage: String?
    var certificatePrompt: CertificatePrompt?
    /// Servidor FTP sin cifrar pendiente de confirmación antes de enviar la contraseña.
    var plainTextPrompt: ServerBookmark?

    var selectedBookmark: ServerBookmark? {
        bookmarks.first { $0.id == selection }
    }

    func addBookmark() {
        let bookmark = ServerBookmark()
        bookmarks.append(bookmark)
        selection = bookmark.id
        BookmarkStore.save(bookmarks)
    }

    func save(_ bookmark: ServerBookmark, password: String) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            let existing = bookmarks[index]
            var updated = bookmark
            // La huella solo la gestiona el modelo; si cambia el servidor, deja de valer.
            let sameServer = existing.host == bookmark.host && existing.port == bookmark.port
                && existing.security == bookmark.security && bookmark.allowInvalidCertificates
            updated.pinnedFingerprint = sameServer ? existing.pinnedFingerprint : nil
            bookmarks[index] = updated
        } else {
            bookmarks.append(bookmark)
        }
        Keychain.setPassword(password, for: bookmark.id)
        BookmarkStore.save(bookmarks)
    }

    func delete(_ id: ServerBookmark.ID) {
        bookmarks.removeAll { $0.id == id }
        Keychain.deletePassword(for: id)
        if selection == id { selection = nil }
        BookmarkStore.save(bookmarks)
    }

    func forgetCertificate(for id: ServerBookmark.ID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].pinnedFingerprint = nil
        BookmarkStore.save(bookmarks)
    }

    func trustCertificate(_ prompt: CertificatePrompt) {
        guard let index = bookmarks.firstIndex(where: { $0.id == prompt.bookmarkID }) else { return }
        bookmarks[index].pinnedFingerprint = prompt.fingerprint
        BookmarkStore.save(bookmarks)
        connect(bookmarks[index], allowPlainText: true)
    }

    func connect(_ requested: ServerBookmark, allowPlainText: Bool = false) {
        guard !isConnecting else { return }
        // Se usa la versión guardada, que incluye la huella del certificado.
        let bookmark = bookmarks.first { $0.id == requested.id } ?? requested
        let hasCredentials = !bookmark.username.trimmingCharacters(in: .whitespaces).isEmpty
        if bookmark.security == .plain, hasCredentials, !allowPlainText {
            plainTextPrompt = bookmark
            return
        }
        guard !bookmark.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Indica la dirección del servidor."
            return
        }
        let password = Keychain.password(for: bookmark.id) ?? ""
        let browser = BrowserModel(bookmark: bookmark, configuration: bookmark.configuration(password: password))

        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await browser.connect()
                self.browser?.shutdown()
                self.browser = browser
            } catch FTPError.certificateNotPinned(let fingerprint, let summary) {
                browser.shutdown()
                certificatePrompt = CertificatePrompt(bookmarkID: bookmark.id, fingerprint: fingerprint, summary: summary, changed: false)
            } catch FTPError.certificateChanged(_, let fingerprint, let summary) {
                browser.shutdown()
                certificatePrompt = CertificatePrompt(bookmarkID: bookmark.id, fingerprint: fingerprint, summary: summary, changed: true)
            } catch {
                browser.shutdown()
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        browser?.shutdown()
        browser = nil
    }
}
