import SwiftUI

/// Shows the real DSP stages as they happen. Progress follows the pipeline (the `processingStage`
/// published by the flow model), never a fake timer.
struct ProcessingAnimationView: View {
    let currentStage: ProcessingStage?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ForEach(ProcessingStage.allCases, id: \.self) { stage in
                row(for: stage)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(for stage: ProcessingStage) -> some View {
        let state = state(for: stage)
        return HStack(spacing: AppSpacing.sm) {
            icon(for: state)
                .frame(width: 26, height: 26)
            Text(title(for: stage))
                .font(state == .active ? AppTypography.bodySemibold : AppTypography.body)
                .foregroundStyle(state == .pending ? .secondary : .primary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(for: state))
    }

    private enum RowState { case done, active, pending }

    private func state(for stage: ProcessingStage) -> RowState {
        guard let currentStage else { return .pending }
        if stage.rawValue < currentStage.rawValue { return .done }
        if stage == currentStage { return .active }
        return .pending
    }

    @ViewBuilder
    private func icon(for state: RowState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColor.good).font(AppTypography.title3)
        case .active:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary).font(AppTypography.title3)
        }
    }

    private func title(for stage: ProcessingStage) -> LocalizedStringKey {
        switch stage {
        case .signalCheck: return "processing.stage.signalCheck"
        case .respiration: return "processing.stage.respiration"
        case .heart: return "processing.stage.heart"
        case .quality: return "processing.stage.quality"
        }
    }

    private func accessibilityValue(for state: RowState) -> LocalizedStringKey {
        switch state {
        case .done: return "processing.state.done"
        case .active: return "processing.state.active"
        case .pending: return "processing.state.pending"
        }
    }
}
