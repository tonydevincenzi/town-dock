import SwiftUI
import TownDockCore

struct BulkNukeSheet: View {
    @EnvironmentObject private var store: TownStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .criteria
    @State private var criteria = BulkNukeCriteria()
    @State private var selectedIDs: Set<String> = []
    @State private var deleteLocalBranches = false
    @State private var deletionAcknowledged = false
    @State private var showingFinalConfirmation = false

    private enum Step {
        case criteria
        case review
    }

    private var candidates: [WorktreeSnapshot] {
        store.snapshot.worktrees
            .filter { !$0.isPrimary }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var matchingWorktrees: [WorktreeSnapshot] {
        criteria.matchingWorktrees(in: candidates)
    }

    private var selectedWorktrees: [WorktreeSnapshot] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    private var executableReviews: [BulkNukeReview] {
        store.bulkNukeReviews.filter(\.canExecute)
    }

    private var blockedReviews: [BulkNukeReview] {
        store.bulkNukeReviews.filter { !$0.canExecute }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                Group {
                    switch step {
                    case .criteria:
                        criteriaContent
                    case .review:
                        reviewContent
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 720)
        .background(TownTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(TownTheme.accent)
        .interactiveDismissDisabled(store.isExecutingBulkNuke)
        .onAppear { selectAllMatches() }
        .onChange(of: criteria) { _, _ in
            deletionAcknowledged = false
            selectAllMatches()
        }
        .alert(
            "Nuke \(executableReviews.count) Worktree\(executableReviews.count == 1 ? "" : "s")?",
            isPresented: $showingFinalConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Nuke Worktrees", role: .destructive) {
                Task {
                    if await store.executeBulkNuke(deleteLocalBranches: deleteLocalBranches) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This permanently deletes every Ready checkout, all untracked files beneath them, attributed processes, and verified local storage. Operations stop on the first safety failure.")
        }
        .onDisappear {
            if !store.isExecutingBulkNuke { store.dismissBulkNuke() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.13))
                Image(systemName: "trash.slash.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bulk Nuke Worktrees")
                    .font(.title2.weight(.semibold))
                Text(step == .criteria
                    ? "Choose which non-primary worktrees qualify"
                    : "Review the exact deletion set before confirming")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(step == .criteria ? "1 of 2" : "2 of 2")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                store.dismissBulkNuke()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isExecutingBulkNuke)
        }
        .padding(18)
    }

    private var criteriaContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            InsetCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Selection criteria")
                        .font(.headline)

                    criteriaGroup("Runtime") {
                        criterionToggle("Running", isOn: $criteria.includeRunning)
                        criterionToggle("Stopped", isOn: $criteria.includeStopped)
                    }

                    Divider()

                    criteriaGroup("Git changes") {
                        criterionToggle("Clean", isOn: $criteria.includeClean)
                        criterionToggle("Dirty", isOn: $criteria.includeDirty)
                    }

                    Divider()

                    criteriaGroup("Setup") {
                        criterionToggle("Complete", isOn: $criteria.includeSetupComplete)
                        criterionToggle("Incomplete", isOn: $criteria.includeSetupIncomplete)
                    }

                    Text("The primary checkout and locked worktrees are always excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Matched worktrees")
                        .font(.headline)
                    Text("\(selectedIDs.count) selected · \(matchingWorktrees.count) matched")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All Matches") { selectAllMatches() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                    if !selectedIDs.isEmpty {
                        Button("Clear") { selectedIDs.removeAll() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                    }
                }

                if matchingWorktrees.isEmpty {
                    InsetCard {
                        Text("No worktrees match these criteria.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(matchingWorktrees) { worktree in
                            worktreeSelectionRow(worktree)
                            if worktree.id != matchingWorktrees.last?.id { Divider() }
                        }
                    }
                    .background(TownTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(TownTheme.border, lineWidth: 1)
                    }
                }
            }

            InsetCard {
                Toggle(isOn: $deleteLocalBranches) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Also delete each selected local Git branch")
                            .font(.subheadline.weight(.medium))
                        Text("Branches are preserved by default. Detached worktrees have no branch to delete.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.isPreparingBulkNuke {
                InsetCard {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Building fresh deletion manifests for \(selectedWorktrees.count) worktrees…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                InsetCard {
                    HStack(spacing: 20) {
                        reviewMetric("Selected", value: store.bulkNukeReviews.count, color: .primary)
                        reviewMetric("Ready", value: executableReviews.count, color: .red)
                        reviewMetric("Blocked", value: blockedReviews.count, color: blockedReviews.isEmpty ? .secondary : .orange)
                        Spacer()
                        if deleteLocalBranches {
                            Label("Delete branches", systemImage: "arrow.triangle.branch")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Deletion review")
                        .font(.headline)

                    ForEach(store.bulkNukeReviews) { review in
                        reviewCard(review)
                    }
                }

                if !blockedReviews.isEmpty {
                    Label(
                        "Blocked worktrees are excluded automatically; Town Dock will only delete the \(executableReviews.count) worktrees marked Ready.",
                        systemImage: "shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }

                if !executableReviews.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Final confirmation")
                            .font(.headline)
                        Text("This permanently deletes each Ready worktree, its untracked files, attributed processes, and verified local storage. Operations run one at a time and stop on the first safety failure.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle(isOn: $deletionAcknowledged) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("I understand these deletions are permanent")
                                    .font(.subheadline.weight(.medium))
                                Text("You will see one final confirmation before anything is deleted.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                            .toggleStyle(.checkbox)
                            .disabled(store.isExecutingBulkNuke)
                    }
                    .padding(14)
                    .background(.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.red.opacity(0.2), lineWidth: 1)
                    }
                }

                if let error = store.bulkNukeError {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step == .review, !store.isExecutingBulkNuke {
                Button("Back") {
                    deletionAcknowledged = false
                    step = .criteria
                }
            }

            if let progress = store.bulkNukeProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(step == .criteria
                    ? "Nothing is deleted until the review is confirmed."
                    : "This cannot be undone.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(step == .criteria ? Color.secondary : Color.red)
            }

            Spacer()

            Button("Cancel") {
                store.dismissBulkNuke()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(store.isExecutingBulkNuke)

            if step == .criteria {
                Button("Review \(selectedIDs.count) Worktree\(selectedIDs.count == 1 ? "" : "s")") {
                    let selected = selectedWorktrees
                    step = .review
                    deletionAcknowledged = false
                    Task {
                        await store.prepareBulkNuke(
                            worktrees: selected,
                            deleteLocalBranches: deleteLocalBranches
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            } else {
                Button(role: .destructive) {
                    showingFinalConfirmation = true
                } label: {
                    if store.isExecutingBulkNuke {
                        Text("Nuking…")
                    } else {
                        Label(
                            "Nuke \(executableReviews.count) Worktree\(executableReviews.count == 1 ? "" : "s")",
                            systemImage: "trash.slash.fill"
                        )
                    }
                }
                .disabled(
                    store.isPreparingBulkNuke
                        || store.isExecutingBulkNuke
                        || executableReviews.isEmpty
                        || !deletionAcknowledged
                )
            }
        }
        .padding(16)
    }

    private func criteriaGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(width: 92, alignment: .leading)
            HStack(spacing: 20) { content() }
        }
    }

    private func criterionToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.subheadline)
            .frame(minWidth: 100, alignment: .leading)
    }

    private func worktreeSelectionRow(_ worktree: WorktreeSnapshot) -> some View {
        Toggle(isOn: Binding(
            get: { selectedIDs.contains(worktree.id) },
            set: { isSelected in
                if isSelected { selectedIDs.insert(worktree.id) }
                else { selectedIDs.remove(worktree.id) }
            }
        )) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(worktree.displayName)
                            .font(.subheadline.weight(.medium))
                        if worktree.instance?.isRunning == true {
                            Text("RUNNING")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if worktree.gitStatus.isDirty {
                            Text("DIRTY")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.gray)
                        }
                        if !worktree.setupComplete {
                            Text("INCOMPLETE")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(worktree.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let number = worktree.instance?.number {
                    Text("Instance \(number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(11)
    }

    private func reviewMetric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewCard(_ review: BulkNukeReview) -> some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: review.canExecute ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(review.canExecute ? .red : .orange)
                    Text(review.worktree.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(review.canExecute ? "READY" : "BLOCKED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(review.canExecute ? .red : .orange)
                    Spacer()
                    if let manifest = review.manifest {
                        Text("\(manifest.targets.filter { $0.actionable && $0.selectedByDefault }.count) actions")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(review.worktree.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let error = review.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if let warnings = review.manifest?.warnings, !warnings.isEmpty {
                    ForEach(warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Ownership and Git identity checks passed for this manifest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectAllMatches() {
        selectedIDs = Set(matchingWorktrees.map(\.id))
    }
}
