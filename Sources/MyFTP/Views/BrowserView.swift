import FTPKit
import SwiftUI
import UniformTypeIdentifiers

extension FTPItem {
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }

    var systemImage: String {
        switch kind {
        case .directory: "folder.fill"
        case .symlink: "arrowshape.turn.up.right"
        case .file: "doc"
        }
    }
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: BrowserModel

    @State private var selection = Set<FTPItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\FTPItem.name)]
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingItem: FTPItem?
    @State private var renameText = ""
    @State private var pendingDelete: [FTPItem]?

    private var rows: [FTPItem] {
        let sorted = browser.items.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    private var selectedItems: [FTPItem] {
        browser.items.filter { selection.contains($0.id) }
    }

    var body: some View {
        VSplitView {
            fileTable
                .frame(minHeight: 200)
            BottomPanel(browser: browser)
                .frame(minHeight: 120, idealHeight: 190)
        }
        .navigationTitle(browser.title)
        .navigationSubtitle(browser.path)
        .toolbar { toolbarContent }
        .onChange(of: browser.path) { selection.removeAll() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { browser.upload(urls) }
        }
        .alert("Nueva carpeta", isPresented: $showNewFolder) {
            TextField("Nombre", text: $newFolderName)
            Button("Crear") {
                browser.makeDirectory(named: newFolderName)
                newFolderName = ""
            }
            Button("Cancelar", role: .cancel) { newFolderName = "" }
        }
        .alert(
            "Renombrar",
            isPresented: Binding(get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })
        ) {
            TextField("Nombre", text: $renameText)
            Button("Renombrar") {
                if let item = renamingItem { browser.rename(item, to: renameText) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { items in
            Button("Eliminar", role: .destructive) { browser.delete(items) }
        } message: { _ in
            Text("Las carpetas se borrarán con todo su contenido. Esta acción no se puede deshacer.")
        }
        .alert(
            "No se pudo completar la operación",
            isPresented: Binding(get: { browser.errorMessage != nil }, set: { if !$0 { browser.errorMessage = nil } })
        ) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(browser.errorMessage ?? "")
        }
    }

    private var deleteTitle: String {
        guard let items = pendingDelete else { return "" }
        return items.count == 1 ? "¿Eliminar «\(items[0].name)»?" : "¿Eliminar \(items.count) elementos?"
    }

    // MARK: Tabla

    private var fileTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Nombre", value: \.name) { item in
                Label {
                    Text(item.name)
                } icon: {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                }
            }
            .width(min: 200, ideal: 340)

            TableColumn("Tamaño", value: \.sortSize) { item in
                Text(sizeText(item))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Modificado", value: \.sortDate) { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Permisos") { item in
                Text(item.permissions ?? "")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: FTPItem.ID.self) { ids in
            let items = browser.items.filter { ids.contains($0.id) }
            if items.isEmpty {
                Button("Nueva carpeta…") { showNewFolder = true }
                Button("Subir archivos o carpetas…") { showImporter = true }
                Button("Actualizar") { browser.refresh() }
            } else {
                if items.count == 1, items[0].kind != .file {
                    Button("Abrir") { browser.activate(items[0]) }
                }
                Button("Descargar") { browser.download(items) }
                if items.count == 1 {
                    Button("Renombrar…") { startRename(items[0]) }
                }
                Divider()
                Button("Eliminar…", role: .destructive) { pendingDelete = items }
            }
        } primaryAction: { ids in
            let items = browser.items.filter { ids.contains($0.id) }
            if items.count == 1 {
                browser.activate(items[0])
            } else {
                browser.download(items)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            browser.upload(urls)
            return !urls.isEmpty
        }
        .overlay {
            if browser.items.isEmpty && !browser.isLoading {
                ContentUnavailableView(
                    "Carpeta vacía",
                    systemImage: "folder",
                    description: Text("Arrastra archivos desde el Finder para subirlos.")
                )
            }
        }
    }

    private func sizeText(_ item: FTPItem) -> String {
        guard !item.isDirectory, let size = item.size else { return item.isDirectory ? "—" : "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func startRename(_ item: FTPItem) {
        renameText = item.name
        renamingItem = item
    }

    // MARK: Barra de herramientas

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { browser.goUp() } label: {
                Label("Carpeta superior", systemImage: "chevron.up")
            }
            .disabled(browser.path == "/")
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Carpeta superior")
        }

        ToolbarItemGroup {
            if browser.isLoading {
                ProgressView().controlSize(.small)
            }
            Button { browser.refresh() } label: {
                Label("Actualizar", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Actualizar")

            Button { showNewFolder = true } label: {
                Label("Nueva carpeta", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Nueva carpeta")

            Button { showImporter = true } label: {
                Label("Subir", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("u")
            .help("Subir archivos o carpetas")

            Button { browser.download(selectedItems) } label: {
                Label("Descargar", systemImage: "square.and.arrow.down")
            }
            .disabled(selectedItems.isEmpty)
            .help("Descargar a la carpeta Descargas")

            Button { pendingDelete = selectedItems } label: {
                Label("Eliminar", systemImage: "trash")
            }
            .disabled(selectedItems.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Eliminar")

            Button { model.disconnect() } label: {
                Label("Desconectar", systemImage: "eject")
            }
            .help("Desconectar")
        }
    }
}
