import SwiftUI
import TownDockCore

enum TownTheme {
    static let canvas = Color(red: 0.055, green: 0.057, blue: 0.064)
    static let sidebar = Color(red: 0.035, green: 0.037, blue: 0.043)
    static let surface = Color(red: 0.082, green: 0.085, blue: 0.094)
    static let surfaceRaised = Color(red: 0.105, green: 0.109, blue: 0.120)
    static let selection = Color.white.opacity(0.095)
    static let border = Color.white.opacity(0.075)
    static let strongBorder = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.48)
    static let accent = Color(red: 0.55, green: 0.49, blue: 0.98)
}

struct LinearButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed ? Color.white.opacity(0.10) : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(TownTheme.border, lineWidth: 1)
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
            .shadow(color: state == .running ? state.tint.opacity(0.45) : .clear, radius: 2)
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
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    if let count {
                        Text("\(count)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(TownTheme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.06), in: Capsule())
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
        .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(TownTheme.border, lineWidth: 1)
        }
    }
}

struct InsetCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(15)
            .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(TownTheme.border, lineWidth: 1)
            }
    }
}
