import AppKit
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

@MainActor
private final class TownTooltipController {
    static let shared = TownTooltipController()

    private let panel: NSPanel
    private let host: NSHostingController<TownTooltipBubble>
    private var activeOwner: UUID?

    private init() {
        host = NSHostingController(rootView: TownTooltipBubble(text: "", width: 228))
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(_ text: String, owner: UUID) {
        activeOwner = owner
        let width = tooltipWidth(for: text)
        host.rootView = TownTooltipBubble(text: text, width: width)

        // Ask SwiftUI to lay out every wrapped line before sizing the AppKit
        // panel. `fittingSize` can report the previous hosting-view height and
        // clip the final line while the root view is being replaced.
        let measured = host.sizeThatFits(
            in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let size = NSSize(width: ceil(width), height: max(30, ceil(measured.height) + 2))
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero

        var origin = NSPoint(x: cursor.x + 12, y: cursor.y - size.height - 14)
        if origin.x + size.width > visibleFrame.maxX - 8 {
            origin.x = cursor.x - size.width - 12
        }
        if origin.y < visibleFrame.minY + 8 {
            origin.y = cursor.y + 18
        }
        origin.x = max(visibleFrame.minX + 8, origin.x)
        origin.y = min(visibleFrame.maxY - size.height - 8, origin.y)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func tooltipWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        let naturalWidth = (text as NSString).size(withAttributes: [.font: font]).width + 24
        return min(360, max(180, ceil(naturalWidth)))
    }

    func hide(owner: UUID) {
        guard activeOwner == owner else { return }
        activeOwner = nil
        panel.orderOut(nil)
    }
}

private struct TownTooltipBubble: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.90))
            .multilineTextAlignment(.leading)
            .lineSpacing(1.5)
            .lineLimit(nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                TownTheme.surfaceRaised,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TownTheme.strongBorder, lineWidth: 1)
            }
            .preferredColorScheme(.dark)
    }
}

@MainActor
private struct TownTooltipModifier: ViewModifier {
    let text: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    TownTooltipController.shared.show(text, owner: owner)
                case .ended:
                    TownTooltipController.shared.hide(owner: owner)
                }
            }
            .onDisappear {
                TownTooltipController.shared.hide(owner: owner)
            }
    }
}

extension View {
    /// An immediate, app-styled explanation for UI that benefits from context.
    /// Unlike macOS `.help`, this has no system hover delay.
    func townTooltip(_ text: String) -> some View {
        modifier(TownTooltipModifier(text: text))
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

    var helpText: String {
        switch self {
        case .running: "Running and accepting connections."
        case .degraded: "Running, but one or more health checks are failing or incomplete."
        case .stopped: "Not currently running or listening on its expected port."
        case .unknown: "Town Sheriff could not determine the current service state."
        }
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

    var helpText: String {
        switch self {
        case .certain: "Ownership is verified by exact process, path, or registry evidence."
        case .high: "Ownership is supported by multiple strong signals and is safe to act on."
        case .inferred: "Ownership is likely but based on indirect evidence; destructive actions are restricted."
        case .ambiguous: "Ownership cannot be established safely; Town Sheriff will not delete or kill it automatically."
        }
    }
}

extension OrphanKind {
    var helpText: String {
        switch self {
        case .deletedWorktree: "Processes or resources still reference a worktree directory that no longer exists."
        case .detachedFromLiveStack: "A resource no longer belongs to the live process stack that originally created it."
        case .unclaimedInstance: "A Town instance is running without a matching registered worktree."
        case .dormantState: "Local state remains on disk but no running Town stack currently uses it."
        case .staleDocker: "A stopped container or volume remains after its Town stack ended."
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
