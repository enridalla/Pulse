import SwiftUI

/// Abstract, low-frequency visualisation of the live chest signal during recording. Fed by the
/// decimated waveform from the recorder (~25 Hz of data, redrawn ~12 Hz) — never per raw sample.
struct LiveSignalView: View {
    let samples: [Double]
    var tint: Color = AppColor.brand

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let maxAbs = max(samples.map(abs).max() ?? 1, 0.0001)
            let midY = size.height / 2
            var path = Path()
            for (i, value) in samples.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(samples.count - 1)
                let y = midY - CGFloat(value / maxAbs) * (size.height * 0.42)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 90)
        .accessibilityHidden(true)
    }
}
