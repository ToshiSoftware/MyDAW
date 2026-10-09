import AppKit
import AudioToolbox
import SwiftUI

// The editor look shared by MyPlugIn effects: a header, input and output
// meters, and a row of faders, all drawn like MyDAW's mixer. Names start
// with "MyFX" because MyDAW compiles this file into its own module.

// MARK: - Scales and colors

/// MyDAW's mixer meter taper: 0 dB at 84 % of the travel, -96 to +6 dB.
public enum MyFXMeterScale {
    private static let taper: [(db: Double, fraction: Double)] = [
        (-96, 0.0), (-72, 0.04), (-48, 0.126), (-36, 0.231), (-24, 0.391),
        (-12, 0.551), (-6, 0.68), (0, 0.84), (6, 1.0)
    ]
    public static let ticks: [Double] = [-48, -24, -12, -6, 0, 6]

    public static func fraction(forDecibels db: Double) -> Double {
        guard db > taper[0].db else { return 0 }
        guard db < taper[taper.count - 1].db else { return 1 }
        for (lower, upper) in zip(taper, taper.dropFirst()) where db <= upper.db {
            return lower.fraction + (db - lower.db) / (upper.db - lower.db) * (upper.fraction - lower.fraction)
        }
        return 1
    }

    public static func fraction(forLevel level: Float) -> Double {
        level > 0 ? fraction(forDecibels: 20 * log10(Double(level))) : 0
    }

    public static func label(forLevel level: Float) -> String {
        guard level > 0.000_016 else { return "-∞" } // below -96 dB
        let db = 20 * log10(Double(level))
        return String(format: db >= 0.05 ? "+%.1f" : "%.1f", db)
    }
}

/// MyDAW's mixer colors, so the editors look like part of the same desk.
public enum MyFXPalette {
    /// Mixer background.
    public static let background = Color(red: 0.08, green: 0.09, blue: 0.11)
    /// Channel strip.
    public static let panel = Color(red: 0.13, green: 0.14, blue: 0.16)
    public static let border = Color.white.opacity(0.18)
    public static let heading = Color.white.opacity(0.55)
    public static let value = Color.white.opacity(0.9)
    public static let well = Color.black.opacity(0.75)
    /// The track faders' silver.
    public static let faderTint = Color(white: 0.85)

    /// MyDAW's level readout colors.
    public static func level(_ level: Float) -> Color {
        let db = level > 0 ? 20 * log10(Double(level)) : -.infinity
        return db >= -6 ? .red : (db >= -12 ? .yellow : .green)
    }
}

// MARK: - Model

/// One stereo meter: falling level, 1.5 s peak hold (as MyDAW's mixer), the
/// highest peak since the readout was last clicked, and whether a sample
/// reached 0 dBFS since then.
public struct MyFXMeterState: Equatable {
    public var left: Float = 0
    public var right: Float = 0
    public var holdLeft: Float = 0
    public var holdRight: Float = 0
    public var maximum: Float = 0
    public var holdAge = 0.0
    /// A sample at or above 0 dBFS (|x| >= 1) since the last `clearPeaks`.
    public var clipped = false

    /// About 20 dB per second at 30 updates per second.
    private static let fall: Float = 0.926
    private static let holdSeconds = 1.5

    public init(left: Float = 0, right: Float = 0, holdLeft: Float = 0, holdRight: Float = 0,
                maximum: Float = 0, holdAge: Double = 0, clipped: Bool = false) {
        self.left = left
        self.right = right
        self.holdLeft = holdLeft
        self.holdRight = holdRight
        self.maximum = maximum
        self.holdAge = holdAge
        self.clipped = clipped
    }

    public mutating func update(left peakLeft: Float, right peakRight: Float, interval: Double) {
        left = max(peakLeft, left * Self.fall)
        right = max(peakRight, right * Self.fall)
        holdAge += interval
        if holdAge > Self.holdSeconds {
            holdLeft = left
            holdRight = right
            holdAge = 0
        } else if peakLeft >= holdLeft || peakRight >= holdRight {
            holdLeft = max(holdLeft, peakLeft)
            holdRight = max(holdRight, peakRight)
            holdAge = 0
        }
        maximum = max(maximum, peakLeft, peakRight)
        if peakLeft >= 1 || peakRight >= 1 { clipped = true }
    }

    /// What clicking the readout or the CLIP lamp does.
    public mutating func clearPeaks() {
        maximum = 0
        clipped = false
    }
}

/// Bridges an effect's parameter tree and meters to its editor views.
/// Main thread only.
public final class MyFXEditorModel: ObservableObject {
    @Published public private(set) var values: [AUParameterAddress: Float] = [:]
    @Published public var input = MyFXMeterState()
    @Published public var output = MyFXMeterState()
    /// The channel the effect is on, as the host names it (AU contextName:
    /// MyDAW gives the track, FX channel or MASTER); nil when not told.
    @Published public var channelName: String?

    /// Meters are polled only while this says the editor is on screen.
    public var isVisible: () -> Bool = { true }

    private let tree: AUParameterTree?
    private weak var metering: MyFXMetering?
    private var observerToken: AUParameterObserverToken?
    private var channelObservation: NSKeyValueObservation?
    private var timer: Timer?
    private static let meterInterval = 1.0 / 30

    public init(parameterTree: AUParameterTree?, metering: MyFXMetering?) {
        tree = parameterTree
        self.metering = metering
        for parameter in parameterTree?.allParameters ?? [] {
            values[parameter.address] = parameter.value
        }
        // Host automation and state restores move the controls too.
        observerToken = tree?.token(byAddingParameterObserver: { [weak self] address, value in
            DispatchQueue.main.async {
                self?.values[address] = value
            }
        })
    }

    deinit {
        timer?.invalidate()
        channelObservation?.invalidate()
        if let observerToken { tree?.removeParameterObserver(observerToken) }
    }

    /// Shows `unit`'s contextName and follows changes to it (a renamed track).
    public func followChannelName(of unit: AUAudioUnit) {
        channelName = unit.contextName
        channelObservation = unit.observe(\.contextName, options: [.new]) { [weak self] unit, _ in
            let name = unit.contextName
            DispatchQueue.main.async { self?.channelName = name }
        }
    }

    public func value(_ address: AUParameterAddress) -> Float {
        values[address] ?? 0
    }

    /// Clamped to the parameter's range. `event` lets a host record
    /// automation: .touch, .value, .release.
    public func set(_ address: AUParameterAddress, _ value: Float, event: AUParameterAutomationEventType = .value) {
        guard let parameter = tree?.parameter(withAddress: address) else { return }
        let clamped = min(max(value, parameter.minValue), parameter.maxValue)
        values[address] = clamped
        parameter.setValue(clamped, originator: observerToken, atHostTime: 0, eventType: event)
    }

    /// A complete gesture (typed value, menu choice, reset): touch then release.
    public func setOnce(_ address: AUParameterAddress, _ value: Float) {
        set(address, value, event: .touch)
        set(address, value, event: .release)
    }

    public func startMeters() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            self?.pollMeters()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pollMeters() {
        guard isVisible(), let peaks = metering?.takeMeterPeaks() else { return }
        var input = self.input
        var output = self.output
        input.update(left: peaks.inputLeft, right: peaks.inputRight, interval: Self.meterInterval)
        output.update(left: peaks.outputLeft, right: peaks.outputRight, interval: Self.meterInterval)
        // Publish only changes: an idle meter costs no redraw.
        if input != self.input { self.input = input }
        if output != self.output { self.output = output }
    }
}

// MARK: - Editor frame

/// Header, channel name, IN/OUT meters and a fader row, sized 300 x 424
/// or larger.
public struct MyFXEditorView<Accessory: View, Faders: View>: View {
    @ObservedObject var model: MyFXEditorModel
    let title: String
    let accessory: Accessory
    let faders: Faders

    /// `accessory` sits at the right of the header (a subtitle or a menu).
    public init(model: MyFXEditorModel, title: String,
                @ViewBuilder accessory: () -> Accessory,
                @ViewBuilder faders: () -> Faders) {
        self.model = model
        self.title = title
        self.accessory = accessory()
        self.faders = faders()
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
            MyFXChannelLabel(name: model.channelName)
            MyFXStrip {
                VStack(spacing: 6) {
                    MyFXMeterRow(label: "IN", state: model.input) { model.input.maximum = 0 }
                    MyFXMeterRow(label: "OUT", state: model.output) { model.output.maximum = 0 }
                    MyFXMeterTicks()
                        .frame(height: 9)
                        .padding(.leading, MyFXMeterRow.labelWidth + 6)
                        .padding(.trailing, MyFXMeterRow.readoutWidth + 6)
                }
                .padding(8)
            }
            MyFXStrip {
                HStack(spacing: 0) { faders }
                    .padding(.horizontal, 2)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 424, maxHeight: .infinity)
        .background(MyFXPalette.background)
    }
}

/// Small grey caption for the header's right side.
public struct MyFXSubtitle: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white.opacity(0.45))
    }
}

/// The name of the channel the effect is on, framed like the sections
/// below it; "-" when the host gives no name.
public struct MyFXChannelLabel: View {
    public static let height: CGFloat = 20
    let name: String?

    public init(name: String?) {
        self.name = name
    }

    public var body: some View {
        MyFXStrip {
            HStack(spacing: 0) {
                Text(name.flatMap { $0.isEmpty ? nil : $0 } ?? "-")
                    .foregroundColor(MyFXPalette.value)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8)
            .frame(height: Self.height)
        }
        .help("The channel this effect is on")
    }
}

/// A section framed like a MyDAW channel strip.
public struct MyFXStrip<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background(MyFXPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
    }
}

// MARK: - Meters

/// "IN"/"OUT", a horizontal L/R meter, optionally a CLIP lamp that stays
/// lit after a sample reaches 0 dBFS, and the maximum peak in dB. Clicking
/// the readout or the lamp clears both.
public struct MyFXMeterRow: View {
    public static let labelWidth: CGFloat = 26
    public static let readoutWidth: CGFloat = 38
    public static let clipWidth: CGFloat = 8
    let label: String
    let state: MyFXMeterState
    let showsClip: Bool
    let clearMaximum: () -> Void

    public init(label: String, state: MyFXMeterState, showsClip: Bool = false,
                clearMaximum: @escaping () -> Void) {
        self.label = label
        self.state = state
        self.showsClip = showsClip
        self.clearMaximum = clearMaximum
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
                .frame(width: Self.labelWidth, alignment: .leading)
            MyFXHorizontalMeter(state: state)
                .frame(height: 11)
            if showsClip {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(state.clipped ? Color.red : MyFXPalette.well)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(MyFXPalette.border, lineWidth: 1))
                    .shadow(color: state.clipped ? .red.opacity(0.8) : .clear, radius: 2)
                    .frame(width: Self.clipWidth, height: 11)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: clearMaximum)
                    .help("CLIP: a sample reached 0 dBFS (click to clear)")
            }
            Text(MyFXMeterScale.label(forLevel: state.maximum))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(state.maximum >= 1 ? .white : MyFXPalette.level(state.maximum))
                .frame(width: Self.readoutWidth, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(state.maximum >= 1 ? Color.red.opacity(0.85) : MyFXPalette.well)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: clearMaximum)
                .help("Peak since last click")
        }
    }
}

/// MyDAW's meter bars turned sideways: green to -12 dB, yellow to -6 dB,
/// red above, with a white peak-hold line.
public struct MyFXHorizontalMeter: View {
    let state: MyFXMeterState

    public init(state: MyFXMeterState) {
        self.state = state
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 1) {
                bar(level: state.left, hold: state.holdLeft, width: geometry.size.width)
                bar(level: state.right, hold: state.holdRight, width: geometry.size.width)
            }
        }
    }

    private func bar(level: Float, hold: Float, width: CGFloat) -> some View {
        let yellow = MyFXMeterScale.fraction(forDecibels: -12)
        let red = MyFXMeterScale.fraction(forDecibels: -6)
        let length = CGFloat(MyFXMeterScale.fraction(forLevel: level)) * width
        let holdPosition = CGFloat(MyFXMeterScale.fraction(forLevel: hold)) * width
        return ZStack(alignment: .leading) {
            Rectangle().fill(MyFXPalette.well)
            LinearGradient(
                stops: [
                    .init(color: .green, location: 0),
                    .init(color: .green, location: yellow),
                    .init(color: .yellow, location: yellow),
                    .init(color: .yellow, location: red),
                    .init(color: .red, location: red),
                    .init(color: .red, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask(alignment: .leading) { Rectangle().frame(width: length) }
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 1)
                .offset(x: CGFloat(MyFXMeterScale.fraction(forDecibels: 0)) * width)
            if hold > 0.000_016 {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1)
                    .offset(x: max(0, holdPosition - 1))
            }
        }
    }
}

public struct MyFXMeterTicks: View {
    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            ForEach(MyFXMeterScale.ticks, id: \.self) { db in
                Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(db == 0 ? 0.85 : 0.5))
                    .fixedSize()
                    .position(x: CGFloat(MyFXMeterScale.fraction(forDecibels: db)) * geometry.size.width,
                              y: geometry.size.height / 2)
            }
        }
    }
}

// MARK: - Faders

/// Name, value (double-click to type), and fader for one parameter.
/// `fraction` is the fader position (0 bottom, 1 top); the column turns it
/// into values only through the callbacks, so each effect keeps its taper.
public struct MyFXFaderColumn: View {
    let name: String
    let nameColor: Color
    let valueText: String
    let fraction: Double
    let onType: (String) -> Void
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    public init(name: String, nameColor: Color = MyFXPalette.heading, valueText: String, fraction: Double,
                onType: @escaping (String) -> Void,
                onBegin: @escaping () -> Void,
                onChange: @escaping (Double) -> Void,
                onEnd: @escaping () -> Void,
                onReset: @escaping () -> Void) {
        self.name = name
        self.nameColor = nameColor
        self.valueText = valueText
        self.fraction = fraction
        self.onType = onType
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
        self.onReset = onReset
    }

    public var body: some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(nameColor)
                .lineLimit(1)
            MyFXEditableValue(text: valueText, onCommit: onType)
                .frame(height: 16)
                .padding(.horizontal, 3)
            MyFXVerticalFader(fraction: fraction, onBegin: onBegin, onChange: onChange,
                              onEnd: onEnd, onReset: onReset)
                .help("Drag; ⌘-drag for fine steps; ⌥-click for the default")
        }
        .frame(maxWidth: .infinity)
    }
}

extension MyFXFaderColumn {
    /// The fader for `parameter`, through `model`, telling the host when a
    /// gesture starts and ends so it can record automation. `fraction` and
    /// `value` are the effect's taper between value and fader travel.
    public init<Parameter: MyFXParameter>(parameter: Parameter, model: MyFXEditorModel,
                                          nameColor: Color = MyFXPalette.heading,
                                          fraction: @escaping (Float) -> Double,
                                          value: @escaping (Double) -> Float) {
        let address = parameter.address
        let current = model.value(address)
        self.init(
            name: parameter.displayName,
            nameColor: nameColor,
            valueText: parameter.displayString(for: current),
            fraction: fraction(current),
            onType: { text in
                if let typed = parameter.value(fromDisplayString: text) { model.setOnce(address, typed) }
            },
            onBegin: { model.set(address, model.value(address), event: .touch) },
            onChange: { model.set(address, value($0)) },
            onEnd: { model.set(address, model.value(address), event: .release) },
            onReset: { model.setOnce(address, parameter.defaultValue) }
        )
    }
}

/// MyDAW's volume fader: relative drag (a click does not jump), ⌘ for fine
/// steps, ⌥-click resets. Silver cap, as on MyDAW's track faders.
public struct MyFXVerticalFader: View {
    let fraction: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var dragStartFraction: Double?

    private let capHeight: CGFloat = 30

    public init(fraction: Double, onBegin: @escaping () -> Void, onChange: @escaping (Double) -> Void,
                onEnd: @escaping () -> Void, onReset: @escaping () -> Void) {
        self.fraction = fraction
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
        self.onReset = onReset
    }

    public var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - capHeight)
            ZStack(alignment: .top) {
                ticks(travel: travel)
                RoundedRectangle(cornerRadius: 2)
                    .fill(MyFXPalette.well)
                    .frame(width: 4)
                    .padding(.vertical, capHeight / 2)
                cap
                    .frame(height: capHeight)
                    .offset(y: CGFloat(1 - fraction) * travel)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard dragStartFraction != nil || drag.translation.height != 0 else { return }
                        if dragStartFraction == nil {
                            dragStartFraction = fraction
                            onBegin()
                        }
                        let fine = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                        let start = dragStartFraction ?? fraction
                        onChange(min(1, max(0, start - Double(drag.translation.height / travel) * fine)))
                    }
                    .onEnded { _ in
                        if dragStartFraction != nil { onEnd() }
                        dragStartFraction = nil
                    }
            )
            .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onReset))
        }
    }

    private func ticks(travel: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<11, id: \.self) { index in
                if index > 0 { Spacer(minLength: 0) }
                HStack(spacing: 14) {
                    tick(major: index % 5 == 0)
                    tick(major: index % 5 == 0)
                }
            }
        }
        .frame(height: travel)
        .padding(.top, capHeight / 2)
    }

    private func tick(major: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(major ? 0.5 : 0.25))
            .frame(width: major ? 7 : 4, height: 1)
            .frame(width: 7, alignment: .center)
    }

    private var cap: some View {
        let tint = MyFXPalette.faderTint
        return RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.45), tint.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { index in
                        Rectangle()
                            .fill(index == 2 ? Color.white : Color.black.opacity(0.35))
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 22)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

/// A horizontal fader: relative drag (a click does not jump), ⌘ for fine
/// steps, ⌥-click or double-click for the default. A tick marks `mark`;
/// with a `detent` the cap settles on it when dragged within 3 % of it.
public struct MyFXHorizontalFader: View {
    let fraction: Double
    let mark: Double
    let detent: Double?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var dragStart: Double?

    private let capWidth: CGFloat = 12
    private static let detentWidth = 0.03

    public init(fraction: Double, mark: Double = 0.5, detent: Double? = nil,
                onBegin: @escaping () -> Void, onChange: @escaping (Double) -> Void,
                onEnd: @escaping () -> Void, onReset: @escaping () -> Void) {
        self.fraction = fraction
        self.mark = mark
        self.detent = detent
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
        self.onReset = onReset
    }

    public var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - capWidth)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MyFXPalette.well)
                    .frame(height: 4)
                    .padding(.horizontal, capWidth / 2)
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1, height: 10)
                    .offset(x: capWidth / 2 + travel * CGFloat(mark))
                cap
                    .frame(width: capWidth, height: geometry.size.height)
                    .offset(x: CGFloat(fraction) * travel)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard dragStart != nil || drag.translation.width != 0 else { return }
                        if dragStart == nil {
                            dragStart = fraction
                            onBegin()
                        }
                        let fine = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                        let start = dragStart ?? fraction
                        var moved = min(1, max(0, start + Double(drag.translation.width / travel) * fine))
                        if let detent, abs(moved - detent) < Self.detentWidth { moved = detent }
                        onChange(moved)
                    }
                    .onEnded { _ in
                        if dragStart != nil { onEnd() }
                        dragStart = nil
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onReset))
        }
    }

    private var cap: some View {
        let tint = MyFXPalette.faderTint
        return RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.45), tint.opacity(0.95)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(Rectangle().fill(Color.white).frame(width: 1))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.6), lineWidth: 1))
    }
}

/// Text that turns into a field on double-click; Return commits, Esc cancels.
public struct MyFXEditableValue: View {
    let text: String
    let onCommit: (String) -> Void
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let font = Font.system(size: 10, weight: .semibold, design: .monospaced)

    public init(text: String, onCommit: @escaping (String) -> Void) {
        self.text = text
        self.onCommit = onCommit
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(isEditing ? Color.black.opacity(0.6) : Color.clear)
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(font)
                    .focused($focused)
                    .onSubmit { finish(commit: true) }
                    .onExitCommand { finish(commit: false) }
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        draft = text
                        isEditing = true
                        DispatchQueue.main.async { focused = true }
                    }
                    .help("Double-click to type a value")
            }
        }
        .foregroundColor(MyFXPalette.value)
        .onChange(of: focused) { isFocused in
            if !isFocused { finish(commit: true) }
        }
    }

    private func finish(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        if commit { onCommit(draft) }
    }
}

// MARK: - Menu

/// Pull-down for a mode: a dark field like MyDAW's mixer value fields that
/// opens a standard menu (SwiftUI's Menu cannot take a custom look on macOS 13).
public struct MyFXMenuPicker: View {
    let options: [String]
    let selection: Int
    let onSelect: (Int) -> Void
    @State private var anchor = MyFXMenuAnchor()

    public init(options: [String], selection: Int, onSelect: @escaping (Int) -> Void) {
        self.options = options
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(options.indices.contains(selection) ? options[selection] : "")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(MyFXPalette.value)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
        }
        .padding(.horizontal, 8)
        .frame(width: 118, height: 20)
        .background(RoundedRectangle(cornerRadius: 3).fill(MyFXPalette.well))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
        .background(MyFXMenuAnchorView(anchor: anchor))
        .contentShape(Rectangle())
        .onTapGesture {
            anchor.popUp(options: options, selection: selection, onSelect: onSelect)
        }
    }
}

/// Opens the menu under the picker's own view.
final class MyFXMenuAnchor: NSObject {
    weak var view: NSView?
    private var onSelect: ((Int) -> Void)?

    func popUp(options: [String], selection: Int, onSelect: @escaping (Int) -> Void) {
        guard let view else { return }
        self.onSelect = onSelect
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selection ? .on : .off
            menu.addItem(item)
        }
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 2 : -2)
        menu.popUp(positioning: nil, at: below, in: view)
    }

    @objc private func choose(_ item: NSMenuItem) {
        onSelect?(item.tag)
    }
}

private struct MyFXMenuAnchorView: NSViewRepresentable {
    let anchor: MyFXMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - View controller

/// What an effect's `requestViewController` hands the host: a SwiftUI
/// editor (300 x 424 unless the effect asks for another size) whose meters
/// run while its window is visible.
public final class MyFXEditorViewController: NSViewController {
    /// The usual editor size.
    public static let preferredSize = NSSize(width: 300, height: 424)
    public let model: MyFXEditorModel
    public let size: NSSize
    private let rootView: AnyView

    public init<Content: View>(model: MyFXEditorModel, rootView: Content, size: NSSize = preferredSize) {
        self.model = model
        self.rootView = AnyView(rootView)
        self.size = size
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func loadView() {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        view = hostingView
    }

    /// The timer runs until the controller goes; it skips while the window
    /// is hidden (MyDAW hides plug-in windows when it is not active).
    public override func viewDidAppear() {
        super.viewDidAppear()
        model.isVisible = { [weak self] in
            self?.view.window?.occlusionState.contains(.visible) ?? false
        }
        model.startMeters()
    }
}
