import Foundation
import FTPKit
import Observation

@Observable
@MainActor
final class AppModel {
    var bookmarks: [ServerBookmark] = BookmarkStore.load()
    var selection: ServerBookmark.ID?
    var browser: BrowserModel?
    var isConnecting = false
    var errorMessage: String?

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
            bookmarks[index] = bookmark
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

    func connect(_ bookmark: ServerBookmark) {
        guard !isConnecting else { return }
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
