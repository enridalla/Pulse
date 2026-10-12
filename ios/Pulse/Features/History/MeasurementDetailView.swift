import SwiftUI

struct MeasurementDetailView: View {
    @State private var viewModel: MeasurementDetailViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: MeasurementDetailViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    @State private var confirmDelete = false
    @State private var exportError = false

    var body: some View {
        Group {
            if let result = viewModel.result {
                ScrollView {
                    ResultContentView(result: result)
                        .padding(AppSpacing.md)
                }
                .background(AppColor.groupedBackground)
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColor.groupedBackground)
            } else if viewModel.loadFailed {
                ContentUnavailableView(
                    "history.corrupt.title",
                    systemImage: "doc.questionmark",
                    description: Text("history.corrupt.message")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColor.groupedBackground)
            }
        }
        .navigationTitle(Format.date(viewModel.summary.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbar }
        .alert("export.error.title", isPresented: $exportError) {
            Button("action.ok", role: .cancel) {}
        } message: { Text("export.error.message") }
        .confirmationDialog("history.delete.title", isPresented: $confirmDelete) {
            Button("action.delete", role: .destructive) { viewModel.delete(); dismiss() }
            Button("action.cancel", role: .cancel) {}
        } message: { Text("history.delete.message") }
        .task { await viewModel.load() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let url = viewModel.rawCSVURL() {
                    ShareLink(item: url) {
                        Label("export.csv", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        exportError = true
                    } label: {
                        Label("export.csv", systemImage: "square.and.arrow.up")
                    }
                }

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("action.delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
