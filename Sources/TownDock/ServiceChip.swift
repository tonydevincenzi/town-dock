import SwiftUI
import TownDockCore

struct ServiceChip: View {
    @EnvironmentObject private var store: TownStore

    let service: ServiceSnapshot
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(state: service.state, size: 7)

            VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                Text(service.kind.displayName)
                    .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                    .lineLimit(1)
                Text(":\(service.port)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 3)

            if service.kind.isBrowserTarget, let url = service.url {
                Button {
                    store.openInChrome(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open \(url.absoluteString) in Chrome")
            }
        }
        .padding(.horizontal, compact ? 9 : 10)
        .padding(.vertical, compact ? 7 : 8)
        .background(TownTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(TownTheme.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if service.kind.isBrowserTarget, let url = service.url {
                store.openInChrome(url)
            }
        }
        .contextMenu {
            if let url = service.url {
                Button("Open in Chrome") { store.openInChrome(url) }
                Button("Copy URL") { store.copy(url.absoluteString) }
            }
            Button("Copy Port") { store.copy(String(service.port)) }
            if !service.processIDs.isEmpty {
                Divider()
                Text("PID \(service.processIDs.map(String.init).joined(separator: ", "))")
            }
        }
        .help(service.detail ?? "\(service.kind.displayName) on port \(service.port)")
    }
}

struct ServiceGrid: View {
    let services: [ServiceSnapshot]

    private let columns = [
        GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(services) { service in
                ServiceChip(service: service)
            }
        }
    }
}
