import AppKit
import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// Small controls of MyChannelStrip's editor: knobs, switches, the output
// fader, and a mouse surface for the graphs. Written to move into
// MyPlugInCore later if other effects want them.

// MARK: - Colors

enum ChannelStripColors {
    static let curve = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let compCurve = Color(red: 0.45, green: 0.75, blue: 0.98)
    static let selection = Color(red: 1, green: 0.8, blue: 0.2)
    static let reduction = Color(red: 1, green: 0.55, blue: 0.15)
    static let switchOn = Color(red: 0.3, green: 0.8, blue: 0.45)
    static let grid = Color.white.opacity(0.10)
    static let gridLabel = Color.white.opacity(0.38)

    static func band(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.75, green: 0.45, blue: 1)
        case 1: return Color(red: 0.25, green: 0.82, blue: 0.95)
        case 2: return Color(red: 0.45, green: 0.88, blue: 0.45)
        default: return Color(red: 1, green: 0.62, blue: 0.2)
        }
    }
}

// MARK: - Tapers

/// Knob travel (0 ... 1) for each parameter: logarithmic for frequencies,
/// Q, ratio and times; linear for the rest.
enum ChannelStripTaper {
    static func isLogarithmic(_ parameter: ChannelStripParameter) -> Bool {
        if let (_, field) = parameter.bandField { return field == .frequency || field == .q }
        return [.compRatio, .compAttack, .compRelease].contains(parameter)
    }

    static func fraction(_ parameter: ChannelStripParameter, _ value: Float) -> Double {
        let range = parameter.range
        let value = Double(parameter.clamped(value))
        let low = Double(range.lowerBound)
        let high = Double(range.upperBound)
        if isLogarithmic(parameter) { return log(value / low) / log(high / low) }
        return (value - low) / (high - low)
    }

    static func value(_ parameter: ChannelStripParameter, _ fraction: Double) -> Float {
        let fraction = min(max(fraction, 0), 1)
        let low = Double(parameter.range.lowerBound)
        let high = Double(parameter.range.upperBound)
        let value = isLogarithmic(parameter) ? low * pow(high / low, fraction) : low + fraction * (high - low)
        return parameter.clamped(Float(value))
    }
}

// MARK: - Knob

/// Name, a small knob and its value (double-click to type). Vertical drag,
/// ⌘ for fine steps, ⌥-click for the default.
struct ChannelStripKnob: View {
    let name: String
    let valueText: String
    let fraction: Double
    var tint: Color = ChannelStripColors.compCurve
    var isEnabled = true
    let onType: (String) -> Void
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var dragStart: Double?

    static let diameter: CGFloat = 18

    var body: some View {
        VStack(spacing: 1) {
            Text(name)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
                .lineLimit(1)
                .frame(height: 8)
            dial
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Rectangle().inset(by: -6))
                .gesture(drag)
                .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onReset))
                .help("Drag; ⌘-drag for fine steps; ⌥-click for the default")
            MyFXEditableValue(text: valueText, onCommit: onType)
                .frame(height: 10)
                .scaleEffect(0.85)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var dial: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(3)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(MyFXPalette.well, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: 1.5, height: Self.diameter * 0.3)
                .offset(y: -Self.diameter * 0.2)
                .rotationEffect(.degrees(-135 + 270 * min(max(fraction, 0), 1)))
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard dragStart != nil || drag.translation.height != 0 else { return }
                if dragStart == nil {
                    dragStart = fraction
                    onBegin()
                }
                let fine = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                onChange(min(1, max(0, (dragStart ?? fraction) - Double(drag.translation.height) / 140 * fine)))
            }
            .onEnded { _ in
                if dragStart != nil { onEnd() }
                dragStart = nil
            }
    }
}

extension ChannelStripKnob {
    /// The knob for `parameter`, through `model`, telling the host when a
    /// gesture starts and ends.
    init(_ parameter: ChannelStripParameter, model: MyFXEditorModel, name: String? = nil,
         tint: Color = ChannelStripColors.compCurve, isEnabled: Bool = true) {
        let address = parameter.address
        let current = model.value(address)
        self.init(
            name: name ?? parameter.displayName,
            valueText: parameter.displayString(for: current),
            fraction: ChannelStripTaper.fraction(parameter, current),
            tint: tint,
            isEnabled: isEnabled,
            onType: { text in
                if let typed = parameter.value(fromDisplayString: text) { model.setOnce(address, typed) }
            },
            onBegin: { model.set(address, model.value(address), event: .touch) },
            onChange: { model.set(address, ChannelStripTaper.value(parameter, $0)) },
            onEnd: { model.set(address, model.value(address), event: .release) },
            onReset: { model.setOnce(address, parameter.defaultValue) }
        )
    }
}

// MARK: - Switches

/// A small lit push button.
struct ChannelStripButton<Label: View>: View {
    let isOn: Bool
    var tint: Color = ChannelStripColors.switchOn
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(isOn ? .black.opacity(0.85) : MyFXPalette.heading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? tint : MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

extension ChannelStripButton where Label == Text {
    /// An on/off parameter as a text button.
    init(_ parameter: ChannelStripParameter, model: MyFXEditorModel, title: String? = nil,
         tint: Color = ChannelStripColors.switchOn) {
        let isOn = model.value(parameter.address) >= 0.5
        self.init(isOn: isOn, tint: tint, action: {
            model.setOnce(parameter.address, isOn ? 0 : 1)
        }, label: { Text(title ?? parameter.displayName) })
    }
}

/// A filter type's outline, drawn in a 14 x 10 box.
struct ChannelStripTypeIcon: Shape {
    let type: ChannelStripFilterType

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY
        var path = Path()
        switch type {
        case .lowCut:
            path.move(to: CGPoint(x: x, y: y + h))
            path.addQuadCurve(to: CGPoint(x: x + w * 0.45, y: y + h * 0.3), control: CGPoint(x: x + w * 0.3, y: y + h * 0.3))
            path.addLine(to: CGPoint(x: x + w, y: y + h * 0.3))
        case .highCut:
            path.move(to: CGPoint(x: x, y: y + h * 0.3))
            path.addLine(to: CGPoint(x: x + w * 0.55, y: y + h * 0.3))
            path.addQuadCurve(to: CGPoint(x: x + w, y: y + h), control: CGPoint(x: x + w * 0.7, y: y + h * 0.3))
        case .lowShelf:
            path.move(to: CGPoint(x: x, y: y + h * 0.15))
            path.addLine(to: CGPoint(x: x + w * 0.3, y: y + h * 0.15))
            path.addLine(to: CGPoint(x: x + w * 0.65, y: y + h * 0.75))
            path.addLine(to: CGPoint(x: x + w, y: y + h * 0.75))
        case .highShelf:
            path.move(to: CGPoint(x: x, y: y + h * 0.75))
            path.addLine(to: CGPoint(x: x + w * 0.35, y: y + h * 0.75))
            path.addLine(to: CGPoint(x: x + w * 0.7, y: y + h * 0.15))
            path.addLine(to: CGPoint(x: x + w, y: y + h * 0.15))
        case .bell:
            path.move(to: CGPoint(x: x, y: y + h * 0.8))
            path.addLine(to: CGPoint(x: x + w * 0.2, y: y + h * 0.8))
            path.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.1), control: CGPoint(x: x + w * 0.38, y: y + h * 0.1))
            path.addQuadCurve(to: CGPoint(x: x + w * 0.8, y: y + h * 0.8), control: CGPoint(x: x + w * 0.62, y: y + h * 0.1))
            path.addLine(to: CGPoint(x: x + w, y: y + h * 0.8))
        }
        return path
    }
}

// MARK: - Mouse surface

/// Mouse events of a graph, in the view's top-left coordinates.
final class ChannelStripMouseHandler {
    var down: (CGPoint, Int, NSEvent.ModifierFlags) -> Void = { _, _, _ in }
    var dragged: (CGPoint, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var up: () -> Void = {}
    var scrolled: (CGPoint, CGFloat) -> Void = { _, _ in }
}

/// A transparent AppKit view laid over a graph: SwiftUI gestures give no
/// click counts, modifier keys at mouse-down or scroll wheels.
struct ChannelStripMouseSurface: NSViewRepresentable {
    let handler: ChannelStripMouseHandler

    func makeNSView(context: Context) -> ChannelStripMouseView {
        let view = ChannelStripMouseView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: ChannelStripMouseView, context: Context) {
        view.handler = handler
    }
}

final class ChannelStripMouseView: NSView {
    var handler: ChannelStripMouseHandler?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        handler?.down(location(event), event.clickCount, event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        handler?.dragged(location(event), event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        handler?.up()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
        guard delta != 0 else { return }
        handler?.scrolled(location(event), delta)
    }
}
