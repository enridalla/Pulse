import SwiftUI

/// Browsing measurements, plus the native selection mode used for batch export and deletion.
///
/// Two clearly separated states: while browsing, a row opens its detail and nothing else is shown;
/// in selection mode a row toggles its checkmark and the bottom bar carries the only two batch
/// actions, Share and Delete.
struct HistoryView: View {
    let viewModel: HistoryViewModel

    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []
    @State private var shareItem: ShareItem?
    @State private var confirmDelete = false
    @State private var exportFailed = false

    private var isSelecting: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isEmpty {
                    ContentUnavailableView(
                        "history.empty.title",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("history.empty.message")
                    )
                } else {
                    historyList
                }
            }
            .navigationTitle(navigationTitle)
            // The bottom bar replaces the tab bar for as long as the selection lasts, so the two
            // batch actions sit exactly where the system puts them in Mail, Files and Photos.
            // Outside selection the choice is left to the system, so a pushed detail screen can
            // still hide the tab bar over its own content.
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .toolbar { toolbarContent }
            .sheet(item: $shareItem) { ShareSheet(urls: $0.urls) }
            .confirmationDialog(
                "history.deleteSelected.title \(selection.count)",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("action.delete", role: .destructive) { deleteSelected() }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("history.deleteSelected.message")
            }
            .alert("export.error.title", isPresented: $exportFailed) {
                Button("action.ok", role: .cancel) {}
            } message: {
                Text("export.error.message")
            }
        }
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing { selection.removeAll() }
        }
        // Keeps the selection honest when the list changes underneath it (a new measurement, a
        // deletion made from the detail screen, "delete all" from Information).
        .onChange(of: viewModel.summaries) { _, summaries in
            selection.formIntersection(Set(summaries.map(\.id)))
            if summaries.isEmpty { editMode = .inactive }
        }
    }

    private var historyList: some View {
        List(selection: $selection) {
            ForEach(viewModel.summaries) { summary in
                Group {
                    if isSelecting {
                        // While selecting, a row is a selectable item rather than a link: it keeps
                        // full text contrast and cannot compete with navigation for the tap.
                        HistoryRow(summary: summary)
                    } else {
                        NavigationLink {
                            MeasurementDetailView(viewModel: viewModel.makeDetailViewModel(for: summary))
                        } label: {
                            HistoryRow(summary: summary)
                        }
                    }
                }
                .tag(summary.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        withAnimation { viewModel.delete(summary) }
                    } label: {
                        Label("action.delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: viewModel.summaries)
        .environment(\.editMode, $editMode)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !viewModel.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "action.done" : "action.select") {
                    withAnimation { editMode = isSelecting ? .inactive : .active }
                }
                .fontWeight(isSelecting ? .semibold : .regular)
            }
        }

        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEverythingSelected ? "action.deselectAll" : "action.selectAll") {
                    toggleSelectAll()
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    exportSelected()
                } label: {
                    Label("action.export", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("action.delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    /// While selecting, the title reports how much is selected — the same place Mail and Files
    /// put it. The display mode is left alone so the count gets the full title width and never
    /// has to be truncated between the two toolbar buttons.
    private var navigationTitle: LocalizedStringKey {
        isSelecting ? "history.select.count \(selection.count)" : "tab.history"
    }

    private var isEverythingSelected: Bool {
        !viewModel.isEmpty && selection.count == viewModel.summaries.count
    }

    // MARK: Actions

    private func toggleSelectAll() {
        selection = isEverythingSelected ? [] : Set(viewModel.summaries.map(\.id))
    }

    /// Hands every selected session to the system share sheet as its own CSV file.
    private func exportSelected() {
        guard !selection.isEmpty else { return }
        do {
            shareItem = ShareItem(urls: try viewModel.exportCSVs(ids: selection))
        } catch {
            exportFailed = true
        }
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        withAnimation { viewModel.delete(ids: selection) }
        selection.removeAll()
        if viewModel.isEmpty { editMode = .inactive }
    }
}

/// A single measurement: when it happened, and the two rates it produced.
struct HistoryRow: View {
    let summary: MeasurementSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.xs) {
            Text(Format.date(summary.startedAt))
                .font(PulseTypography.subheadlineMedium)

            metricsLayout {
                metric(
                    icon: "lungs.fill",
                    tint: PulseColors.respiration,
                    value: summary.respiratoryRateBPM.map { Format.rate($0) },
                    unit: "unit.bpm.resp"
                )

                metric(
                    icon: "heart.fill",
                    tint: PulseColors.heart,
                    value: summary.heartRateBPM.map { Format.integer($0) },
                    unit: "unit.bpm"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, PulseSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Side by side normally; stacked once the text is large enough that two metrics on one line
    /// would break the numbers across lines.
    private var metricsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PulseSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: PulseSpacing.lg))
    }

    private func metric(icon: String, tint: Color, value: String?, unit: LocalizedStringKey) -> some View {
        HStack(spacing: PulseSpacing.xxs) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(tint)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(PulseTypography.bodySemibold)
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Text(unit)
                    .font(PulseTypography.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }

    /// One spoken sentence instead of four fragments, and it never relies on the metric colours.
    private var accessibilityLabel: Text {
        var label = Text(Format.date(summary.startedAt))
        if let rate = summary.respiratoryRateBPM {
            label = label + Text(verbatim: ", ") + Text("result.respiration")
                + Text(verbatim: " \(Format.rate(rate)) ") + Text("unit.bpm.resp")
        }
        if let rate = summary.heartRateBPM {
            label = label + Text(verbatim: ", ") + Text("result.heart")
                + Text(verbatim: " \(Format.integer(rate)) ") + Text("unit.bpm")
        }
        return label
    }
}
