import SwiftUI

struct InformationView: View {
    let viewModel: InformationViewModel
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("disclaimer.full")
                    Text("info.important.practical")
                        .foregroundStyle(.secondary)
                } header: {
                    Label("info.disclaimer.title", systemImage: "exclamationmark.shield")
                }

                Section {
                    InfoParagraph(
                        icon: "lungs.fill",
                        tint: AppColor.respiration,
                        title: "info.meaning.respiration.title",
                        message: "info.meaning.respiration.body"
                    )

                    InfoParagraph(
                        icon: "heart.fill",
                        tint: AppColor.heart,
                        title: "info.meaning.heart.title",
                        message: "info.meaning.heart.body"
                    )
                } header: {
                    Label("info.meaning.title", systemImage: "book")
                }

                Section {
                    Text("info.privacy.body")
                    Text("info.data.body")
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Label("privacy.deleteAll.title", systemImage: "trash")
                            // Without this the symbol keeps the app tint while the title turns
                            // red, so the row reads as two different colours.
                            .foregroundStyle(Color.red)
                    }
                } header: {
                    Label("info.privacy.title", systemImage: "lock.shield")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("tab.info")
            .alert("privacy.deleteAll.title", isPresented: $confirmDeleteAll) {
                Button("privacy.deleteAll.confirm", role: .destructive) { viewModel.deleteAllData() }
                Button("action.cancel", role: .cancel) {}
            } message: { Text("privacy.deleteAll.message") }
        }
    }
}

private struct InfoParagraph: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(title).font(AppTypography.subheadlineSemibold)
                Text(message).font(AppTypography.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.xxs)
    }
}
