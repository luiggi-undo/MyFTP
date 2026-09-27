import FTPKit
import SwiftUI

struct BottomPanel: View {
    let browser: BrowserModel
    @State private var pane = Pane.transfers

    enum Pane: String, CaseIterable {
        case transfers = "Transferencias"
        case log = "Registro"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                switch pane {
                case .transfers:
                    Button("Limpiar finalizadas") { browser.clearFinishedTransfers() }
                        .disabled(!browser.transfers.contains { $0.isFinished })
                case .log:
                    Button("Borrar registro") { browser.clearLog() }
                        .disabled(browser.log.isEmpty)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            switch pane {
            case .transfers:
                TransfersList(browser: browser)
            case .log:
                LogView(entries: browser.log)
            }
        }
    }
}

struct TransfersList: View {
    let browser: BrowserModel

    var body: some View {
        if browser.transfers.isEmpty {
            ContentUnavailableView(
                "Sin transferencias",
                systemImage: "arrow.up.arrow.down",
                description: Text("Haz doble clic en un archivo para descargarlo o arrastra archivos para subirlos.")
            )
        } else {
            List(browser.transfers) { transfer in
                TransferRow(transfer: transfer, browser: browser)
            }
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let browser: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.state == .running {
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }

            Spacer()

            if !transfer.isFinished {
                Button { browser.cancel(transfer) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Cancelar")
            } else if transfer.state == .completed, transfer.direction == .download {
                Button { browser.revealInFinder(transfer) } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Mostrar en el Finder")
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch transfer.state {
        case .queued:
            return "En cola"
        case .running:
            let done = ByteCountFormatter.string(fromByteCount: transfer.transferred, countStyle: .file)
            if let total = transfer.total {
                return "\(done) de \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            }
            return done
        case .completed:
            return "Completado"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelado"
        }
    }

    private var statusColor: Color {
        switch transfer.state {
        case .failed: .red
        case .completed: .green
        default: .secondary
        }
    }
}

struct LogView: View {
    let entries: [FTPLogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: entry.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .onChange(of: entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func color(for kind: FTPLogEntry.Kind) -> Color {
        switch kind {
        case .command: .blue
        case .reply: .primary
        case .info: .green
        case .error: .red
        }
    }
}
