import SwiftUI
import UIKit

/// Identifiable wrapper so a set of file URLs can drive a `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Thin wrapper over `UIActivityViewController` for sharing generated files.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
