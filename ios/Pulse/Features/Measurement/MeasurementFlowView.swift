import Combine
import SwiftUI

/// Guided measurement experience presented modally. Views render state exposed by MeasurementViewModel;
/// acquisition, persistence and processing remain outside the View layer.
struct MeasurementFlowView: View {
    @Bindable var viewModel: MeasurementViewModel
    let onFinish: () -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()
            content
                .transition(.opacity)
                .animation(reduceMotion ? nil : AppAnimation.standard, value: viewModel.phase)
        }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .configuration:
            ConfigurationStepView(viewModel: viewModel) { viewModel.advanceToPositioning() }
        case .preparation:
            PreparationStepView(onContinue: { viewModel.advanceToPositioning() })
        case .positioning:
            PositioningStepView(reduceMotion: reduceMotion, onContinue: { viewModel.advanceToSignalCheck() })
        case .signalCheck:
            SignalCheckStepView(
                viewModel: viewModel,
                reduceMotion: reduceMotion,
                onBack: { viewModel.returnToPositioning() }
            )
        case .countdown:
            CountdownStepView(value: viewModel.countdownValue)
        case .recording:
            RecordingStepView(viewModel: viewModel, reduceMotion: reduceMotion)
        case .processing:
            ProcessingStepView(stage: viewModel.processingStage, onCancel: onCancel)
        case .completed:
            if let result = viewModel.completedResult {
                ResultView(result: result, onDone: onFinish)
            }
        case .failed:
            FailedStepView(
                error: viewModel.error ?? .processingFailed,
                onRetry: { viewModel.acknowledgeErrorAndRetry() },
                onClose: onCancel
            )
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if [.configuration, .preparation, .positioning, .signalCheck].contains(viewModel.phase) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(AppColor.surface.opacity(0.94), in: Circle())
                    .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
                    .padding(AppSpacing.md)
            }
            .accessibilityLabel("action.close")
        }
    }
}

// MARK: - Configuration

private struct ConfigurationStepView: View {
    @Bindable var viewModel: MeasurementViewModel
    let onContinue: () -> Void

    @State private var durationSeconds = 90.0
    @State private var notes = ""
    private let durations: [Double] = [60, 90, 120]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    FlowHeader(title: "config.title", subtitle: "config.subtitle")

                    VStack(alignment: .leading, spacing: AppSpacing.lg) {
                        SettingBlock(title: "config.duration.title", icon: "timer") {
                            ChipRow(values: durations, selection: $durationSeconds) { "\(Int($0))s" }
                        }

                        Divider().overlay(AppColor.hairline)

                        SettingBlock(title: "config.notes.title", icon: "square.and.pencil") {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                TextField("config.notes.placeholder", text: $notes, axis: .vertical)
                                    .lineLimit(1...4)
                                    .padding(AppSpacing.sm)
                                    .background(AppColor.surfaceMuted, in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                                Text("config.notes.hint")
                                    .font(AppTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider().overlay(AppColor.hairline)

                        SettingBlock(title: "config.feedback.title", icon: "hand.tap") {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Toggle("config.feedback.toggle", isOn: $viewModel.feedbackEnabled)
                                    .tint(AppColor.brand)
                                Text("config.feedback.hint")
                                    .font(AppTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(AppSpacing.md)
                    .appSurface()
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.lg)
            }

            BottomActionBar(title: "action.continue", systemImage: "arrow.right", action: applyAndContinue)
        }
        .onAppear(perform: seed)
    }

    private func seed() {
        durationSeconds = viewModel.configuration.plannedDurationSeconds
    }

    private func applyAndContinue() {
        viewModel.configuration = MeasurementConfiguration(
            subjectIdentifier: nil,
            breathingMode: .free,
            plannedDurationSeconds: durationSeconds,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        onContinue()
    }
}

private struct SettingBlock<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            SectionLabel(title: title, systemImage: icon)
            content
        }
    }
}

private struct ChipRow: View {
    let values: [Double]
    @Binding var selection: Double
    let label: (Double) -> String

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(values, id: \.self) { value in
                let selected = abs(value - selection) < 0.001
                Button {
                    selection = value
                } label: {
                    Text(label(value))
                        .font(AppTypography.subheadlineSemibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selected ? AppColor.brand : AppColor.surfaceMuted,
                            in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        )
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Preparation

private struct PreparationStepView: View {
    let onContinue: () -> Void

    var body: some View {
        StepScaffold(
            title: "prep.title",
            subtitle: "prep.subtitle",
            continueTitle: "action.continue",
            onContinue: onContinue
        ) {
            PreparationInstructionList()
                .padding(AppSpacing.md)
                .appSurface()
        }
    }
}

private struct PreparationInstructionList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InstructionRow(icon: "figure.flexibility", text: "prep.lieDown")
            InstructionDivider()
            InstructionRow(icon: "iphone.gen3", text: "prep.center")
            InstructionDivider()
            InstructionRow(icon: "arrow.up", text: "prep.screenUp")
            InstructionDivider()
            InstructionRow(icon: "hand.raised.slash", text: "prep.noHand")
            InstructionDivider()
            InstructionRow(icon: "figure.stand", text: "prep.stayStill")
            InstructionDivider()
            InstructionRow(icon: "lungs", text: "prep.breatheNormally")
            InstructionDivider()
            InstructionRow(icon: "hand.tap", text: "prep.autoStart")
            InstructionDivider()
            InstructionRow(icon: "bandage", text: "prep.strap")
        }
    }
}

private struct PreparationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    Text("prep.subtitle")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(.secondary)
                    PreparationInstructionList()
                        .padding(AppSpacing.md)
                        .appSurface()
                }
                .padding(AppSpacing.md)
            }
            .background(AppColor.canvas)
            .navigationTitle("prep.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("action.done") { dismiss() }
                }
            }
        }
    }
}

private struct InstructionRow: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            IconBadge(systemImage: icon, tint: AppColor.brand, size: 34)
            Text(text)
                .font(AppTypography.body)
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
    }
}

private struct InstructionDivider: View {
    var body: some View {
        Divider()
            .overlay(AppColor.hairline)
            .padding(.leading, 46)
    }
}

// MARK: - Positioning

private struct PositioningStepView: View {
    let reduceMotion: Bool
    let onContinue: () -> Void
    @State private var showPreparation = false

    var body: some View {
        StepScaffold(
            title: "positioning.title",
            subtitle: "positioning.subtitle",
            continueTitle: "positioning.ready",
            onContinue: onContinue
        ) {
            VStack(spacing: AppSpacing.md) {
                PositioningAnimationView(isPlaced: false, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.sm)

                Divider().overlay(AppColor.hairline)

                Button { showPreparation = true } label: {
                    HStack(spacing: AppSpacing.sm) {
                        IconBadge(systemImage: "info.circle", tint: AppColor.brand, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("positioning.prepare.title")
                                .font(AppTypography.subheadlineSemibold)
                                .foregroundStyle(.primary)
                            Text("positioning.prepare.hint")
                                .font(AppTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(AppSpacing.md)
            .appSurface()
        }
        .sheet(isPresented: $showPreparation) { PreparationSheet() }
    }
}

// MARK: - Signal check

private struct SignalCheckStepView: View {
    let viewModel: MeasurementViewModel
    let reduceMotion: Bool
    let onBack: () -> Void

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private var quality: PositioningQuality { viewModel.positioningQuality }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AppSpacing.xl)

            VStack(spacing: AppSpacing.lg) {
                PositioningAnimationView(isPlaced: quality.isStable, reduceMotion: reduceMotion)

                VStack(spacing: AppSpacing.sm) {
                    IconBadge(systemImage: symbol, tint: tint, size: 44)
                    Text(LocalizedStringKey(statusKey))
                        .font(AppTypography.title)
                        .multilineTextAlignment(.center)

                    if viewModel.autoStartProgress > 0 {
                        ProgressView(value: viewModel.autoStartProgress)
                            .tint(AppColor.good)
                            .animation(reduceMotion ? nil : .linear(duration: 0.2), value: viewModel.autoStartProgress)
                    }

                    Text("signalCheck.handsFree")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(AppSpacing.lg)
            .appSurface()
            .padding(.horizontal, AppSpacing.md)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)

            Spacer()

            Button(action: onBack) {
                Text("action.back")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(AppColor.brand)
            }
            .padding(.bottom, AppSpacing.xl)
        }
        .onReceive(tick) { _ in viewModel.evaluateAutoStart() }
    }

    private var statusKey: String {
        viewModel.autoStartProgress > 0 ? "signalCheck.holdingStill" : quality.messageKey
    }

    private var tint: Color {
        switch quality.level {
        case .stable: return AppColor.good
        case .waiting: return AppColor.brand
        default: return AppColor.poor
        }
    }

    private var symbol: String {
        switch quality.level {
        case .stable: return "checkmark"
        case .waiting: return "hourglass"
        case .moving: return "waveform.path"
        case .adjust: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

// MARK: - Countdown

private struct CountdownStepView: View {
    let value: Int

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            VStack(spacing: AppSpacing.sm) {
                Text("countdown.title")
                    .font(AppTypography.title)
                    .multilineTextAlignment(.center)
                Text("\(value)")
                    .font(AppTypography.metricXL)
                    .foregroundStyle(AppColor.brand)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: value)
                Text("countdown.stayStill")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity)
            .appSurface()
            .padding(.horizontal, AppSpacing.md)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("countdown.title")
        .accessibilityValue("\(value)")
    }
}

// MARK: - Recording

private struct RecordingStepView: View {
    let viewModel: MeasurementViewModel
    let reduceMotion: Bool

    private var elapsed: Double { viewModel.liveSnapshot.elapsedSeconds }
    private var planned: Double { viewModel.plannedDurationSeconds }
    private var progress: Double { planned > 0 ? min(1, elapsed / planned) : 0 }
    private var needsAttention: Bool {
        switch viewModel.positioningQuality.level {
        case .moving, .adjust: return true
        case .stable, .waiting: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    HStack(spacing: AppSpacing.xs) {
                        Circle()
                            .fill(AppColor.heart)
                            .frame(width: 8, height: 8)
                        Text("recording.inProgress")
                            .font(AppTypography.subheadlineSemibold)
                        Spacer()
                    }

                    VStack(spacing: AppSpacing.lg) {
                        ZStack {
                            Circle()
                                .stroke(AppColor.surfaceMuted, lineWidth: 11)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(AppColor.brand, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)

                            VStack(spacing: 3) {
                                Text(Format.clock(max(0, planned - elapsed)))
                                    .font(.system(size: 39, weight: .semibold, design: .default))
                                    .monospacedDigit()
                                Text("recording.remaining")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 190, height: 190)

                        VStack(spacing: AppSpacing.xs) {
                            LiveSignalView(samples: viewModel.liveSnapshot.waveform)
                            Text("recording.free.hint")
                                .font(AppTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(AppSpacing.lg)
                    .appSurface()

                    if needsAttention {
                        MovementWarning(level: viewModel.positioningQuality.level)
                    }
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.lg)
            }

            VStack(spacing: 0) {
                Divider().opacity(0.5)
                Button(role: .destructive) {
                    viewModel.stopRecording(completed: elapsed >= planned - 1.0)
                } label: {
                    Label("recording.stop", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle(tint: AppColor.heart))
                .padding(AppSpacing.md)
            }
            .background(AppColor.surface)
        }
    }
}

private struct MovementWarning: View {
    let level: PositioningQuality.Level

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            IconBadge(systemImage: "waveform.path", tint: AppColor.poor, size: 36)
            Text(title)
                .font(AppTypography.subheadlineMedium)
            Spacer()
        }
        .padding(AppSpacing.md)
        .appSurface()
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch level {
        case .moving: return "recording.stability.moving"
        case .adjust: return "recording.stability.adjust"
        case .stable, .waiting: return "recording.stability.stable"
        }
    }
}

// MARK: - Processing

private struct ProcessingStepView: View {
    let stage: ProcessingStage?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: AppSpacing.lg) {
                FlowHeader(title: "processing.title", subtitle: "processing.subtitle")
                ProcessingAnimationView(currentStage: stage)
            }
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity)
            .appSurface()
            .padding(.horizontal, AppSpacing.md)
            Spacer()
            Button(action: onCancel) {
                Text("action.cancel")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, AppSpacing.xl)
        }
    }
}

// MARK: - Failed

private struct FailedStepView: View {
    let error: MeasurementError
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: AppSpacing.lg) {
                IconBadge(systemImage: "exclamationmark.triangle.fill", tint: AppColor.poor, size: 52)
                VStack(spacing: AppSpacing.xs) {
                    Text(LocalizedStringKey(error.titleKey))
                        .font(AppTypography.title)
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey(error.messageKey))
                        .font(AppTypography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if error.dataWasSaved {
                    Label("error.dataSaved", systemImage: "checkmark.circle")
                        .font(AppTypography.footnote)
                        .foregroundStyle(AppColor.good)
                }
            }
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity)
            .appSurface()
            .padding(.horizontal, AppSpacing.md)

            Spacer()

            VStack(spacing: AppSpacing.sm) {
                if error.isRetryable {
                    Button(action: onRetry) {
                        Label("action.retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Button(action: onClose) { Text("action.close") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(AppSpacing.md)
        }
    }
}

// MARK: - Shared flow components

private struct FlowHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            Text(title)
                .font(.system(.title, design: .default, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(AppTypography.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BottomActionBar: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            Button(action: action) {
                // The glyph trails the label, like the button on Home: a forward arrow placed
                // before the text reads as "back".
                HStack(spacing: AppSpacing.sm) {
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)

                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: systemImage)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(AppSpacing.md)
        }
        .background(AppColor.surface)
    }
}

private struct StepScaffold<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let continueTitle: LocalizedStringKey
    let onContinue: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    FlowHeader(title: title, subtitle: subtitle)
                    content
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.xl)
                .padding(.bottom, AppSpacing.lg)
            }
            BottomActionBar(title: continueTitle, systemImage: "arrow.right", action: onContinue)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
