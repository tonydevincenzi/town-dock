import SwiftUI
import TownDockCore

enum TownTheme {
    // Codex-inspired neutral hierarchy: a charcoal navigation rail, a darker
    // working canvas, and quiet elevated surfaces without a colored cast.
    static let canvas = Color(red: 0.090, green: 0.090, blue: 0.090)
    static let sidebar = Color(red: 0.180, green: 0.180, blue: 0.180)
    static let surface = Color(red: 0.140, green: 0.140, blue: 0.140)
    static let surfaceRaised = Color(red: 0.185, green: 0.185, blue: 0.185)
    static let selection = Color(red: 0.250, green: 0.250, blue: 0.250)
    static let border = Color.white.opacity(0.085)
    static let strongBorder = Color.white.opacity(0.145)
    static let muted = Color.white.opacity(0.58)
    static let accent = Color.white.opacity(0.80)
}

struct LinearButtonStyle: ButtonStyle {
    var destructive = false
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(destructive ? Color.red : Color.white.opacity(0.88))
            .padding(.horizontal, 11)
            .padding(.vertical, 6.5)
            .background(
                configuration.isPressed
                    ? Color.white.opacity(0.16)
                    : (emphasized ? Color.white.opacity(0.13) : TownTheme.surfaceRaised),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(emphasized ? TownTheme.strongBorder : TownTheme.border, lineWidth: 1)
            }
    }
}

/// A disclosure control whose content is inserted and removed immediately.
/// SwiftUI's DisclosureGroup applies a built-in layout animation even when its
/// surrounding view does not request one, which feels sluggish in this dense UI.
struct SnapDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        _isExpanded = isExpanded
        self.content = content()
        self.label = label()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
    }
}

extension WorktreeSnapshot {
    var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var secondaryLabel: String {
        if isDetached { return "Detached at \(String(head.prefix(8)))" }
        if isPrimary { return "Primary checkout" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var frontendURL: URL? {
        instance?.services.first { $0.kind == .frontend && $0.url != nil }?.url
    }
}

extension ServiceState {
    var tint: Color {
        switch self {
        case .running: .green
        case .degraded: .orange
        case .stopped: .secondary
        case .unknown: .secondary
        }
    }

    var displayName: String {
        rawValue.capitalized
    }
}

extension AttributionConfidence {
    var tint: Color {
        switch self {
        case .certain: .green
        case .high: .blue
        case .inferred: .orange
        case .ambiguous: .red
        }
    }
}

extension UInt64 {
    var byteCountLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: self), countStyle: .file)
    }
}

extension Double {
    var cpuPercentLabel: String {
        if self > 0, self < 0.1 { return "<0.1%" }
        if self >= 100 { return formatted(.number.precision(.fractionLength(0))) + "%" }
        return formatted(.number.precision(.fractionLength(1))) + "%"
    }
}

extension ServiceSnapshot {
    var resourceSummary: String? {
        var parts: [String] = []
        if let cpuPercent {
            parts.append("\(cpuPercent.cpuPercentLabel) CPU")
        }
        if let residentBytes {
            parts.append(residentBytes.byteCountLabel)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var compactResourceSummary: String? {
        var parts: [String] = []
        if let cpuPercent {
            parts.append(cpuPercent.cpuPercentLabel)
        }
        if let residentBytes {
            parts.append(residentBytes.byteCountLabel)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Date {
    var relativeLabel: String {
        formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

struct StatusDot: View {
    let state: ServiceState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: size, height: size)
            .accessibilityLabel(state.displayName)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let count: Int?

    init(_ title: String, subtitle: String? = nil, symbol: String, count: Int? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.count = count
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TownTheme.muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 17, weight: .medium))
                    if let count {
                        Text("\(count)")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(TownTheme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(TownTheme.surfaceRaised, in: Capsule())
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(TownTheme.muted)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptySectionView: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TownTheme.border, lineWidth: 1)
        }
    }
}

struct InsetCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(TownTheme.border, lineWidth: 1)
            }
    }
}
