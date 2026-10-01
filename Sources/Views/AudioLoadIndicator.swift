import SwiftUI
import AppKit

/// Status bar item: "CPU [bar] 34% ● Dropout".
struct AudioLoadIndicator: View {
    @ObservedObject var monitor: AudioLoadMonitor

    private static let barWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "CPU")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            // Test mode is on (see AudioLoadMonitor.testOffsetDefaultsKey).
            if monitor.testOffsetPercent > 0 {
                Text(verbatim: "TEST +\(monitor.testOffsetPercent)%")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 3)
                    .background(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Self.color(for: monitor.load))
                    .frame(width: Self.barWidth * min(1.0, monitor.load))
            }
            .frame(width: Self.barWidth, height: 7)
            .animation(.linear(duration: 0.1), value: monitor.load)

            Text(verbatim: "\(Int((monitor.load * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 32, alignment: .trailing)

            HStack(spacing: 3) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                Text("Dropout")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
            }
            // Space stays reserved so the status bar does not shift.
            .opacity(monitor.isShowingDropout ? 1 : 0)
        }
        // An AppKit tooltip: its text is asked for when it is shown, and the
        // view redrawing 10 times a second does not keep it from appearing.
        .overlay(DynamicToolTip { [monitor] in Self.toolTip(for: monitor) })
    }

    @MainActor
    private static func toolTip(for monitor: AudioLoadMonitor) -> String {
        func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
        var lines = [
            String(localized: "Audio processing load: \(percent(monitor.averageLoad))% (peak \(percent(monitor.peakLoad))%)"),
            String(localized: "MyDAW CPU usage (all cores): \(percent(monitor.processCPU))%"),
            String(localized: "Dropouts since launch: \(monitor.dropoutCount)")
        ]
        if let last = monitor.lastDropoutDate {
            let time = DateFormatter.localizedString(from: last, dateStyle: .none, timeStyle: .medium)
            lines.append(String(localized: "Last dropout: \(time)"))
        }
        return lines.joined(separator: "\n")
    }

    /// Green while there is room, through yellow and orange to red as the
    /// cycle fills up.
    private static func color(for load: Double) -> Color {
        let stops: [(at: Double, rgb: (Double, Double, Double))] = [
            (0.0, (0.30, 0.82, 0.40)),
            (0.6, (0.95, 0.85, 0.25)),
            (0.8, (1.00, 0.55, 0.15)),
            (1.0, (0.95, 0.22, 0.22))
        ]
        let value = min(1.0, max(0.0, load))
        for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.at {
            let t = (value - lower.at) / (upper.at - lower.at)
            return Color(
                red: lower.rgb.0 + (upper.rgb.0 - lower.rgb.0) * t,
                green: lower.rgb.1 + (upper.rgb.1 - lower.rgb.1) * t,
                blue: lower.rgb.2 + (upper.rgb.2 - lower.rgb.2) * t
            )
        }
        let last = stops[stops.count - 1].rgb
        return Color(red: last.0, green: last.1, blue: last.2)
    }
}

/// Transparent view whose tooltip text is produced when AppKit shows it.
private struct DynamicToolTip: NSViewRepresentable {
    let text: @MainActor () -> String

    func makeNSView(context: Context) -> ToolTipView {
        let view = ToolTipView()
        view.text = text
        return view
    }

    func updateNSView(_ view: ToolTipView, context: Context) {
        view.text = text
    }

    final class ToolTipView: NSView, NSViewToolTipOwner {
        var text: (@MainActor () -> String)?
        private var toolTipTag: NSView.ToolTipTag?

        // Mouse clicks go to the views underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if let toolTipTag { removeToolTip(toolTipTag) }
            toolTipTag = addToolTip(bounds, owner: self, userData: nil)
        }

        func view(
            _ view: NSView,
            stringForToolTip tag: NSView.ToolTipTag,
            point: NSPoint,
            userData data: UnsafeMutableRawPointer?
        ) -> String {
            MainActor.assumeIsolated { text?() ?? "" }
        }
    }
}
