import SwiftUI

/// Stretches an already drawn waveform vertically while a waveform-scale
/// change is previewed (`ProjectState.waveformScalePreview`). Only this
/// modifier observes the preview, so the waveform is not redrawn.
struct VerticalStretch: ViewModifier {
    @ObservedObject var preview: PreviewScale
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: preview.scale, anchor: anchor)
    }
}
