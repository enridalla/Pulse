import SwiftUI

/// Stylised, top-down illustration of a supine person with the iPhone resting on the sternum.
/// Built entirely from SwiftUI shapes and SF Symbols — no remote or bundled images. The phone
/// eases into place, gentle breathing waves emanate from the chest, and a checkmark confirms the
/// position. Under Reduce Motion everything is shown in its settled state without looping motion.
struct PositioningAnimationView: View {
    var isPlaced: Bool
    var reduceMotion: Bool

    @State private var phoneDrop = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            // Body: head + torso seen from above.
            VStack(spacing: -8) {
                Circle()
                    .fill(bodyColor)
                    .frame(width: 54, height: 54)
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(bodyColor)
                    .frame(width: 120, height: 210)
                    .scaleEffect(breathe && !reduceMotion ? 1.03 : 1.0, anchor: .center)
            }

            // Breathing waves from the chest.
            if !reduceMotion {
                ForEach(0..<3, id: \.self) { index in
                    BreathingWave(index: index, breathe: breathe)
                }
            }

            // Phone on the sternum.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppColor.brandDeep)
                .frame(width: 46, height: 92)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AppColor.brand.opacity(0.5))
                        .padding(4)
                )
                .offset(y: (phoneDrop || reduceMotion) ? -20 : -120)
                .opacity((phoneDrop || reduceMotion) ? 1 : 0.2)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            // Confirmation badge.
            if isPlaced {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, AppColor.good)
                    .offset(x: 44, y: -24)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 300)
        .animation(reduceMotion ? nil : AppAnimation.gentleSpring, value: isPlaced)
        .onAppear {
            if reduceMotion { phoneDrop = true; return }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.2)) { phoneDrop = true }
            breathe = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("positioning.illustration.accessibility")
    }

    private var bodyColor: Color { AppColor.surfaceMuted }
}

/// One expanding, fading ring emanating from the chest.
private struct BreathingWave: View {
    let index: Int
    let breathe: Bool

    var body: some View {
        Circle()
            .stroke(AppColor.respiration.opacity(0.30), lineWidth: 2)
            .frame(width: 70, height: 70)
            .scaleEffect(breathe ? 2.1 : 0.6)
            .opacity(breathe ? 0 : 0.6)
            .offset(y: -20)
            .animation(
                .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(index) * 0.8),
                value: breathe
            )
    }
}
