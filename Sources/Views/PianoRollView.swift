import SwiftUI
import AppKit

/// The piano roll in the bottom panel (switched with the mixer): an
/// inspector, a toolbar and the canvas with keyboard, ruler, notes and
/// velocity lane.
struct PianoRollView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var controller: PianoRollController

    init(projectState: ProjectState) {
        self.projectState = projectState
        self.controller = projectState.pianoRoll
    }

    var body: some View {
        if let track = controller.track, let clip = controller.clip {
            HStack(spacing: 0) {
                PianoRollInspector(controller: controller, track: track)
                    .frame(width: 170)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                VStack(spacing: 0) {
                    PianoRollToolbar(controller: controller, projectState: projectState)
                    PianoRollCanvasHost(controller: controller, projectState: projectState, track: track, clip: clip)
                    // Starts at the grid, as the arranger's starts at the tracks.
                    PianoRollScrollBar(controller: controller, track: track)
                }
            }
        } else {
            Text("Double-click a MIDI clip to edit it here.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The key column's width depends on the track's instrument.
private struct PianoRollScrollBar: View {
    @ObservedObject var controller: PianoRollController
    @ObservedObject var track: AudioTrack

    var body: some View {
        PanelScrollBar(position: controller.scrollPosition,
                       leading: controller.drumKit == nil ? PianoRollCanvas.keyboardWidth : PianoRollCanvas.drumKeyWidth)
    }
}

private struct PianoRollInspector: View {
    @ObservedObject var controller: PianoRollController
    @ObservedObject var track: AudioTrack

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
        }
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }

    private var content: some View {
        // Everything below the default velocity changes the selected notes
        // (nothing without a selection).
        let enabled = controller.hasSelection
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Rectangle().fill(track.color).frame(width: 4, height: 16)
                Text(track.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
            }

            section("Default Values")
            caption("Velocity")
            NumberField(value: $controller.defaultVelocity, range: 1...127)
            // Also the grid for quantize, the pencil and snapping.
            caption("Note Length / Quantize")
            HStack(spacing: 4) {
                Picker("", selection: $controller.gridDivision) {
                    ForEach(PianoRollController.divisions, id: \.self) { division in
                        Text(verbatim: "1/\(division)").tag(division)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
                Picker("", selection: $controller.isTripletGrid) {
                    Text("Straight").tag(false)
                    Text("Triplet").tag(true)
                }
                .labelsHidden()
                .frame(width: 84)
            }

            Divider()
            section("Note Length Adjustment")
            HStack(spacing: 4) {
                Picker("", selection: $controller.fixedLengthDivision) {
                    ForEach(PianoRollController.divisions, id: \.self) { division in
                        Text(verbatim: "1/\(division)").tag(division)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
                Picker("", selection: $controller.fixedLengthIsTriplet) {
                    Text("Straight").tag(false)
                    Text("Triplet").tag(true)
                }
                .labelsHidden()
                .frame(width: 84)
            }
            HStack(spacing: 4) {
                applyButton("Fixed Length", enabled: enabled) { controller.applyFixedLength() }
                applyButton("Remove Overlaps", enabled: enabled) { controller.removeOverlaps() }
            }

            Divider()
            section("Velocity Adjustment")
            valueRow(value: $controller.fixedVelocity, range: 1...127, suffix: "",
                     button: "Fixed", enabled: enabled) { controller.applyFixedVelocity() }
            valueRow(value: $controller.velocityScalePercent, range: 1...400, suffix: "%",
                     button: "Scale", enabled: enabled) { controller.applyVelocityScale() }
            valueRow(value: $controller.velocityOffset, range: -127...127, suffix: "", signed: true,
                     button: "Offset", enabled: enabled) { controller.applyVelocityOffset() }

            // On a drum kit a pitch is a kind of hit, so there is nothing to transpose.
            if controller.drumKit == nil {
                Divider()
                section("Transpose")
                valueRow(value: $controller.transposeSemitones, range: -48...48, suffix: "", signed: true,
                         button: "Apply Transpose", enabled: enabled) {
                    controller.transposeSelection(by: controller.transposeSemitones)
                }

                Divider()
                section("Octave Shift")
                HStack(spacing: 4) {
                    applyButton("-12", enabled: enabled) { controller.transposeSelection(by: -12) }
                    applyButton("+12", enabled: enabled) { controller.transposeSelection(by: 12) }
                }
            }

            Divider()
            section("Swing Adjustment")
            rangeRow("Velocity", down: $controller.swingVelocityDown, up: $controller.swingVelocityUp, limit: 127)
            rangeRow("Start", down: $controller.swingStartEarlier, up: $controller.swingStartLater, limit: 128)
                .help("In 1/128 of a bar")
            applyButton("Apply Swing", enabled: enabled) { controller.applySwing() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
    }

    private func section(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white.opacity(0.85))
    }

    /// A label and "−[10] 〜 +[10]" below it.
    private func rangeRow(_ label: LocalizedStringKey, down: Binding<Int>, up: Binding<Int>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caption(label)
            HStack(spacing: 2) {
                Text(verbatim: "−").font(.system(size: 11, weight: .semibold))
                NumberField(value: down, range: 0...limit)
                Text(verbatim: "〜").font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                Text(verbatim: "+").font(.system(size: 11, weight: .semibold))
                NumberField(value: up, range: 0...limit)
            }
        }
    }

    /// Buttons as large as the pull-downs.
    private func applyButton(_ key: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key).font(.system(size: 12))
        }
        .controlSize(.regular)
        .disabled(!enabled)
    }

    private func valueRow(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String,
        signed: Bool = false,
        button: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            NumberField(value: value, range: range, signed: signed, suffix: suffix)
            applyButton(button, enabled: enabled, action: action)
        }
    }
}

/// A number typed in and confirmed with Return (or by leaving the field).
/// Values outside `range` go to its nearest end; text that is no number
/// goes back to the value.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var signed = false
    var suffix = ""
    @State private var text = ""
    @FocusState private var isFocused: Bool

    static let width: CGFloat = 58

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { focused in
                    if !focused { commit() }
                }
            Text(verbatim: suffix)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 10, alignment: .leading)
        }
        .frame(width: Self.width)
        .onAppear { text = formatted(value) }
        .onChange(of: value) { text = formatted($0) }
    }

    private func formatted(_ number: Int) -> String {
        (signed && number > 0 ? "+" : "") + "\(number)"
    }

    private func commit() {
        let digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        if let number = Int(digits) {
            value = min(range.upperBound, max(range.lowerBound, number))
        }
        text = formatted(value)
    }
}

private struct PianoRollToolbar: View {
    @ObservedObject var controller: PianoRollController
    @ObservedObject var projectState: ProjectState

    private static let tools: [(PianoRollController.Tool, String, LocalizedStringKey)] = [
        (.arrow, "cursorarrow", "Arrow Tool"),
        (.pencil, "pencil", "Pencil Tool"),
        (.eraser, "eraser", "Eraser Tool"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.tools, id: \.0) { tool, symbol, help in
                Button {
                    controller.tool = tool
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(controller.tool == tool ? .white : .white.opacity(0.6))
                        .frame(width: 26, height: 20)
                        .background(controller.tool == tool ? Color.accentColor : Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(PlainButtonStyle())
                .help(help)
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            // Quantize: [Q] runs it; the three modes beside it say what moves.
            Button {
                controller.quantize()
            } label: {
                Text(verbatim: "Qtz")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.white.opacity(controller.canQuantize ? 0.9 : 0.35))
                    .frame(width: 52, height: 20)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(3)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!controller.canQuantize)
            .help("Quantize the selected notes (Q)")
            QuantizeModeButton(label: "|←", isOn: controller.quantizesStart,
                               help: "Quantize Note Starts") { controller.toggleQuantizeStart() }
            QuantizeModeButton(label: "→|", isOn: controller.quantizesEnd,
                               help: "Quantize Note Ends") { controller.toggleQuantizeEnd() }
            QuantizeModeButton(label: "|←|", isOn: controller.quantizeKeepsLength,
                               help: "Quantize Note Starts, Keeping Their Length") { controller.toggleQuantizeKeepsLength() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            // Audition on or off (not a tool): notes sound as they are
            // picked or moved.
            Button {
                controller.auditionsNotes.toggle()
            } label: {
                Image(systemName: controller.auditionsNotes ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(controller.auditionsNotes ? .white : .white.opacity(0.6))
                    .frame(width: 26, height: 20)
                    .background(controller.auditionsNotes ? Color.orange.opacity(0.8) : Color.white.opacity(0.08))
                    .cornerRadius(3)
            }
            .buttonStyle(PlainButtonStyle())
            .help(controller.auditionsNotes ? "Audition Notes: On" : "Audition Notes: Off")
            Divider().frame(height: 16).padding(.horizontal, 4)
            Toggle(isOn: $projectState.snapToGrid) {
                Image(systemName: "squareshape.split.3x3")
                    .font(.system(size: 11))
            }
            .toggleStyle(.button)
            .help("Snap to Grid")
            Toggle(isOn: $controller.followsArranger) {
                Image(systemName: "arrow.left.and.right.square")
                    .font(.system(size: 11))
            }
            .toggleStyle(.button)
            .help("Follow the Track View (scrolls with the playhead)")
            Spacer()
            Button { controller.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(PlainButtonStyle())
                .help("Zoom Out")
            Button { controller.zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(PlainButtonStyle())
                .help("Zoom In")
        }
        .foregroundColor(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(red: 0.15, green: 0.16, blue: 0.18))
    }
}

/// One of the quantize mode switches.
private struct QuantizeModeButton: View {
    let label: String
    let isOn: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isOn ? .black : .white.opacity(0.6))
                .frame(width: 30, height: 20)
                .background(isOn ? Color.cyan.opacity(0.85) : Color.white.opacity(0.08))
                .cornerRadius(3)
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
    }
}

/// Hosts the AppKit canvas; redrawn whenever the clip, the track or the
/// editor's settings change.
private struct PianoRollCanvasHost: NSViewRepresentable {
    @ObservedObject var controller: PianoRollController
    @ObservedObject var projectState: ProjectState
    @ObservedObject var track: AudioTrack
    @ObservedObject var clip: MIDIClip

    func makeNSView(context: Context) -> PianoRollCanvas {
        PianoRollCanvas(controller: controller, projectState: projectState)
    }

    func updateNSView(_ canvas: PianoRollCanvas, context: Context) {
        canvas.contentDidChange()
    }

    static func dismantleNSView(_ canvas: PianoRollCanvas, coordinator: ()) {
        canvas.stopPlayheadTimer()
    }
}

// MARK: - Canvas

/// Keyboard (left), ruler (top), note grid and velocity lane (bottom) in
/// one view that scrolls itself: the wheel scrolls, Cmd-wheel zooms in
/// time and Option-wheel zooms the rows; the scroll bar under it
/// (`PianoRollController.scrollPosition`) scrolls in time. C3 is MIDI note 60.
final class PianoRollCanvas: NSView {
    private let controller: PianoRollController
    private weak var projectState: ProjectState?

    static let keyboardWidth: CGFloat = 52
    /// A drum instrument's column: the drum's name, then its hits.
    static let drumKeyWidth: CGFloat = 164
    private static let drumNameWidth: CGFloat = 66
    private static let rulerHeight: CGFloat = 22
    private static let velocityHeight: CGFloat = 80
    /// The row of lane tabs (Velocity, Pitch Bend, ...) above the lane.
    private static let laneTabHeight: CGFloat = 18
    private static let laneTabFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    private static let edgeZone: CGFloat = 5

    /// Left edge of the grid in timeline ticks, and the grid's vertical
    /// scroll in points (0: pitch 127 at the top).
    private var scrollTick: Double = 0
    private var scrollY: CGFloat = 0
    private var handledScrollRequest = -1
    private var playheadTimer: Timer?
    private var lastPlayheadX: CGFloat = -1
    private var outsideClickMonitor: Any?
    private var needsFit = false
    /// The note under the pointer and where the pointer is, for the
    /// key / velocity tip drawn beside it.
    private var hoveredNote: Int?
    private var hoverPoint: NSPoint = .zero

    /// The rows when the track's instrument is a drum instrument; nil for
    /// the keyboard (one row per pitch).
    private var drumLayout: DrumRollLayout?

    private enum Drag {
        case none
        /// `lastPitchDelta`: in rows on a drum instrument.
        case move(anchor: Int, originals: [Int: MIDINote], startTick: Int, startPitch: Int, startRow: Int, lastPitchDelta: Int)
        case resizeEnd(anchor: Int, originals: [Int: MIDINote], startTick: Int)
        case resizeStart(anchor: Int, originals: [Int: MIDINote], startTick: Int)
        case rubberBand(start: NSPoint, current: NSPoint, base: Set<Int>)
        case erase
        case keyboard(pitch: Int)
        case velocity(lastX: CGFloat, lastValue: Int)
        /// One note's velocity dot dragged up or down (relative to the press),
        /// sounding the note every half second at the velocity reached.
        case velocityNote(index: Int, startY: CGFloat, startVelocity: Int)
        /// Option-drag in the velocity lane: a straight line from the press.
        case velocityLine(startX: CGFloat, startValue: Int, current: NSPoint, originals: [Int: UInt8])
        case ruler
        /// Controller lanes (pitch bend, modulation, aftertouch), in content
        /// ticks: pencil freehand, Option-pencil straight line (over the
        /// events at the press), eraser, and the arrow dragging one point.
        case laneDraw(last: (tick: Int, value: Int))
        case laneLine(start: (tick: Int, value: Int), originals: [MIDIChannelEvent])
        case laneErase(lastX: CGFloat)
        case lanePoint(index: Int)
    }
    private var drag: Drag = .none
    /// Repeats the dragged velocity dot's note (one at a time).
    private var velocityAuditionTimer: Timer?
    private var velocityAuditionPitch: Int?
    private static let velocityAuditionInterval: TimeInterval = 0.5
    /// How near the pointer must be to a velocity dot to grab it.
    private static let velocityDotGrabRadius: CGFloat = 5

    init(controller: PianoRollController, projectState: ProjectState) {
        self.controller = controller
        self.projectState = projectState
        super.init(frame: .zero)
        wantsLayer = true
        controller.scrollPosition.scroll = { [weak self] tick in self?.scrollFromBar(to: tick) }
        startPlayheadTimer()
        // A click elsewhere in the window (the arranger's SwiftUI views take
        // no keyboard focus) gives the edit keys back to the arranger.
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            onMainThread {
                guard let self, let window = self.window, event.window === window,
                      window.firstResponder === self,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        controller.hasKeyFocus = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        controller.hasKeyFocus = false
        return true
    }

    func contentDidChange() {
        if handledScrollRequest != controller.scrollRequest {
            handledScrollRequest = controller.scrollRequest
            // After this SwiftUI update (the fit changes the zoom it shows),
            // and once the view has its size.
            needsFit = true
            DispatchQueue.main.async { [weak self] in self?.fitIfNeeded() }
        }
        refreshDrumLayout()
        clampScroll()
        needsDisplay = true
    }

    /// Remakes the drum rows when they changed. Not during a move: the rows
    /// must stay as they were at the press, even if the last note of an
    /// "Other" row leaves it.
    private func refreshDrumLayout() {
        if case .move = drag { return }
        guard let kit = controller.drumKit else {
            drumLayout = nil
            return
        }
        let pitches = Set((clip?.notes ?? []).map { Int($0.pitch) })
        if let drumLayout, drumLayout.folded == controller.foldedDrums,
           drumLayout.otherPitches == DrumRollLayout.otherPitches(of: pitches, drums: kit) {
            return
        }
        drumLayout = controller.makeDrumLayout()
    }

    // MARK: Geometry

    private var keyWidth: CGFloat { drumLayout == nil ? Self.keyboardWidth : Self.drumKeyWidth }
    private var rowCount: Int { drumLayout?.rows.count ?? 128 }
    private var clip: MIDIClip? { controller.clip }
    private var ppt: CGFloat { CGFloat(controller.pixelsPerTick) }
    private var rowHeight: CGFloat { CGFloat(controller.rowHeight) }

    private var gridRect: NSRect {
        NSRect(
            x: keyWidth,
            y: Self.rulerHeight,
            width: max(0, bounds.width - keyWidth),
            height: max(0, bounds.height - Self.rulerHeight - Self.velocityHeight - Self.laneTabHeight)
        )
    }

    private var velocityRect: NSRect {
        NSRect(x: keyWidth, y: bounds.height - Self.velocityHeight,
               width: max(0, bounds.width - keyWidth), height: Self.velocityHeight)
    }

    private func x(ofTick tick: Int) -> CGFloat {
        keyWidth + CGFloat(Double(tick) - scrollTick) * ppt
    }

    private func tick(atX x: CGFloat) -> Int {
        Int((scrollTick + Double((x - keyWidth) / ppt)).rounded(.down))
    }

    private func row(ofPitch pitch: Int) -> Int {
        drumLayout?.row(ofPitch: pitch) ?? 127 - pitch
    }

    private func y(ofPitch pitch: Int) -> CGFloat {
        y(ofRow: row(ofPitch: pitch))
    }

    private func y(ofRow row: Int) -> CGFloat {
        Self.rulerHeight + CGFloat(row) * rowHeight - scrollY
    }

    private func row(atY y: CGFloat) -> Int {
        max(0, min(rowCount - 1, Int(floor((y - Self.rulerHeight + scrollY) / rowHeight))))
    }

    private func pitch(atY y: CGFloat) -> Int {
        let row = row(atY: y)
        guard let drumLayout else { return 127 - row }
        return drumLayout.rows.indices.contains(row) ? drumLayout.rows[row].pitch : 0
    }

    /// Whether `y` is on a row: the drum rows can end above the grid's bottom.
    private func isOnRow(y: CGFloat) -> Bool {
        y - Self.rulerHeight + scrollY < CGFloat(rowCount) * rowHeight
    }

    private func rect(ofNote index: Int, in clip: MIDIClip) -> NSRect {
        let note = clip.notes[index]
        let start = clip.timelineTick(ofContentTick: note.startTick)
        let left = x(ofTick: start)
        let width = max(3, CGFloat(note.lengthTicks) * ppt)
        return NSRect(x: left, y: y(ofPitch: Int(note.pitch)) + 1, width: width, height: max(2, rowHeight - 1))
    }

    private func clampScroll() {
        let contentHeight = CGFloat(rowCount) * rowHeight
        scrollY = max(0, min(max(0, contentHeight - gridRect.height), scrollY))
        scrollTick = max(0, scrollTick)
        updateScroller()
    }

    // MARK: Scroll bar

    /// Ticks the grid shows across its width.
    private var visibleTicks: Double { Double(gridRect.width / max(ppt, 1e-9)) }

    /// Ticks the scroll bar spans: from the start to past the clip's end
    /// (half a view more), or to the view's right edge when scrolled further.
    private var scrollableTicks: Double {
        let clipEnd = Double(clip?.endTick ?? 0)
        return max(clipEnd + visibleTicks / 2, scrollTick + visibleTicks)
    }

    private func updateScroller() {
        controller.scrollPosition.report(offset: scrollTick, maximum: scrollableTicks - visibleTicks)
    }

    private func scrollFromBar(to tick: Double) {
        guard abs(tick - scrollTick) >= 0.5 else { return }
        controller.followsArranger = false
        scrollTick = tick
        clampScroll()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScroller()
        fitIfNeeded()
    }

    private func fitIfNeeded() {
        guard needsFit, gridRect.width > 40, gridRect.height > 20 else { return }
        needsFit = false
        scrollToClip()
        needsDisplay = true
    }

    /// Fits the whole clip in the width (a small margin either side), its
    /// notes centred in height.
    private func scrollToClip() {
        guard let clip else { return }
        let margin: CGFloat = 24
        let fitted = Double(max(40, gridRect.width - 2 * margin)) / Double(max(1, clip.lengthTicks))
        controller.pixelsPerTick = min(PianoRollController.zoomRange.upperBound,
                                       max(PianoRollController.zoomRange.lowerBound, fitted))
        controller.followsArranger = false
        scrollTick = max(0, Double(clip.startTick) - Double(margin / ppt))
        let rows = clip.audibleNotes.map { row(ofPitch: Int($0.pitch)) }
        let emptyMiddle = drumLayout == nil ? row(ofPitch: 60) : 0
        let middle = rows.isEmpty ? emptyMiddle : (rows.min()! + rows.max()!) / 2
        scrollY = CGFloat(middle) * rowHeight - gridRect.height / 2
        clampScroll()
    }

    /// The topmost note under `point` and whether the point is on its left
    /// or right edge.
    private func note(at point: NSPoint) -> (index: Int, edge: Int)? {
        guard let clip, gridRect.contains(point) else { return nil }
        for index in clip.notes.indices.reversed() {
            let noteRect = rect(ofNote: index, in: clip)
            guard noteRect.contains(point) else { continue }
            let zone = min(Self.edgeZone, noteRect.width / 3)
            if point.x >= noteRect.maxX - zone { return (index, 1) }
            if point.x <= noteRect.minX + zone { return (index, -1) }
            return (index, 0)
        }
        return nil
    }

    // MARK: Drawing

    private static func velocityColor(_ velocity: UInt8, muted: Bool) -> NSColor {
        if muted { return NSColor(white: 0.45, alpha: 1) }
        let amount = CGFloat(velocity) / 127
        return NSColor(hue: 0.33 * (1 - amount), saturation: 0.7, brightness: 0.85, alpha: 1)
    }

    private static func isBlackKey(_ pitch: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(pitch % 12)
    }

    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[pitch % 12])\(pitch / 12 - 2)"
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1).setFill()
        bounds.fill()
        refreshDrumLayout()
        guard let clip, let projectState else { return }
        let grid = gridRect
        let meter = projectState.audioEngine.meter
        drawnMeter = meter

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: grid).addClip()
        if let drumLayout {
            drawDrumRows(drumLayout, in: grid)
        } else {
            // Rows: black keys darker, a line under each C.
            let firstPitch = pitch(atY: grid.maxY)
            let lastPitch = pitch(atY: grid.minY)
            for pitch in firstPitch...lastPitch {
                let rowY = y(ofPitch: pitch)
                (Self.isBlackKey(pitch) ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.14, alpha: 1)).setFill()
                NSRect(x: grid.minX, y: rowY, width: grid.width, height: rowHeight).fill()
                if pitch % 12 == 0 {
                    NSColor(white: 0.28, alpha: 1).setFill()
                    NSRect(x: grid.minX, y: rowY + rowHeight - 1, width: grid.width, height: 1).fill()
                }
            }
        }
        // Outside the clip is shaded.
        NSColor(white: 0, alpha: 0.28).setFill()
        let clipLeft = x(ofTick: clip.startTick)
        let clipRight = x(ofTick: clip.endTick)
        NSRect(x: grid.minX, y: grid.minY, width: max(0, clipLeft - grid.minX), height: grid.height).fill()
        NSRect(x: clipRight, y: grid.minY, width: max(0, grid.maxX - clipRight), height: grid.height).fill()
        drawTimeLines(in: grid, meter: meter)

        let selection = controller.selection
        let font = NSFont.systemFont(ofSize: max(7, min(10, rowHeight - 3)), weight: .semibold)
        for index in clip.notes.indices {
            let noteRect = rect(ofNote: index, in: clip)
            guard noteRect.intersects(grid) else { continue }
            let note = clip.notes[index]
            let inside = clip.audibleNotes.contains(note)
            let color = Self.velocityColor(note.velocity, muted: note.isMuted || !inside)
            let path = NSBezierPath(roundedRect: noteRect, xRadius: 2, yRadius: 2)
            (note.isMuted ? color.withAlphaComponent(0.25) : color.withAlphaComponent(inside ? 0.9 : 0.35)).setFill()
            path.fill()
            (selection.contains(index) ? NSColor.white : color.shadow(withLevel: 0.4) ?? color).setStroke()
            path.lineWidth = selection.contains(index) ? 1.5 : 1
            path.stroke()
            if noteRect.width > 28 && rowHeight >= 10 {
                let name = (drumLayout?.hitName(ofPitch: Int(note.pitch)) ?? Self.noteName(Int(note.pitch))) as NSString
                name.draw(at: NSPoint(x: noteRect.minX + 3, y: noteRect.minY + (noteRect.height - font.pointSize) / 2 - 2),
                          withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.8)])
            }
        }
        if case .rubberBand(let start, let current, _) = drag {
            let band = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            NSColor(white: 1, alpha: 0.08).setFill()
            band.fill()
            NSColor(white: 1, alpha: 0.7).setStroke()
            NSBezierPath(rect: band).stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        drawRuler(meter: meter, clip: clip)
        if let drumLayout {
            drawDrumKeys(drumLayout, in: grid)
        } else {
            drawKeyboard(in: grid)
        }
        drawVelocityLane(clip: clip, meter: meter)
        drawPlayhead(projectState: projectState)
        drawNoteTip(clip: clip)
    }

    /// "F#2  Velocity 76" beside the pointer over a note (not while dragging;
    /// the dragged notes show their own changes).
    private func drawNoteTip(clip: MIDIClip) {
        guard case .none = drag, let index = hoveredNote, clip.notes.indices.contains(index) else { return }
        let note = clip.notes[index]
        let noteName = drumLayout?.fullName(ofPitch: Int(note.pitch)) ?? Self.noteName(Int(note.pitch))
        let text = String(localized: "\(noteName)  Velocity \(Int(note.velocity))") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var box = NSRect(x: hoverPoint.x + 12, y: hoverPoint.y + 14, width: size.width + 10, height: size.height + 4)
        // Kept inside the view.
        if box.maxX > bounds.maxX { box.origin.x = hoverPoint.x - box.width - 8 }
        if box.maxY > bounds.maxY { box.origin.y = hoverPoint.y - box.height - 8 }
        NSColor(white: 0.05, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attributes)
    }

    /// Bar, beat and grid lines across `rect`.
    private func drawTimeLines(in rect: NSRect, meter: MusicalMeter) {
        let firstTick = max(0, tick(atX: rect.minX))
        let lastTick = tick(atX: rect.maxX) + 1
        let step = controller.gridTicks
        let showsGrid = CGFloat(step) * ppt >= 6
        var lineTick = firstTick / step * step
        while lineTick <= lastTick {
            let lineX = x(ofTick: lineTick)
            let shade: CGFloat
            if lineTick % meter.ticksPerBar == 0 {
                shade = 0.42
            } else if lineTick % meter.ticksPerBeat == 0 {
                shade = 0.27
            } else if showsGrid {
                shade = 0.19
            } else {
                lineTick += step
                continue
            }
            NSColor(white: shade, alpha: 1).setFill()
            NSRect(x: lineX, y: rect.minY, width: 1, height: rect.height).fill()
            lineTick += step
        }
    }

    private func drawRuler(meter: MusicalMeter, clip: MIDIClip) {
        let ruler = NSRect(x: keyWidth, y: 0, width: bounds.width - keyWidth, height: Self.rulerHeight)
        NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.18, alpha: 1).setFill()
        ruler.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: ruler).addClip()
        // The clip's span.
        NSColor(white: 1, alpha: 0.1).setFill()
        NSRect(x: x(ofTick: clip.startTick), y: Self.rulerHeight - 5,
               width: CGFloat(clip.lengthTicks) * ppt, height: 5).fill()
        let pixelsPerBeat = CGFloat(meter.ticksPerBeat) * ppt
        let labelsBeats = pixelsPerBeat >= 40
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let firstBeat = max(0, tick(atX: ruler.minX) / meter.ticksPerBeat)
        let lastBeat = tick(atX: ruler.maxX) / meter.ticksPerBeat + 1
        for beat in firstBeat...max(firstBeat, lastBeat) {
            let beatTick = beat * meter.ticksPerBeat
            let lineX = x(ofTick: beatTick)
            let position = meter.position(ofTick: beatTick)
            let isBar = position.beat == 0
            guard isBar || pixelsPerBeat >= 8 else { continue }
            NSColor(white: isBar ? 0.6 : 0.35, alpha: 1).setFill()
            NSRect(x: lineX, y: isBar ? 4 : 12, width: 1, height: Self.rulerHeight - (isBar ? 4 : 12)).fill()
            if isBar || labelsBeats {
                let label = isBar ? "\(position.bar + 1)" : "\(position.bar + 1).\(position.beat + 1)"
                (label as NSString).draw(at: NSPoint(x: lineX + 3, y: 3), withAttributes: [
                    .font: isBar ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold) : font,
                    .foregroundColor: NSColor(white: isBar ? 0.9 : 0.55, alpha: 1),
                ])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: keyWidth, height: Self.rulerHeight).fill()
    }

    private func drawKeyboard(in grid: NSRect) {
        let keys = NSRect(x: 0, y: grid.minY, width: keyWidth, height: grid.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: keys).addClip()
        let font = NSFont.systemFont(ofSize: 8, weight: .medium)
        for pitch in pitch(atY: grid.maxY)...pitch(atY: grid.minY) {
            let rowY = y(ofPitch: pitch)
            let isBlack = Self.isBlackKey(pitch)
            let held: Bool = {
                if case .keyboard(let heldPitch) = drag { return heldPitch == pitch }
                return false
            }()
            (held ? NSColor.systemOrange : isBlack ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSRect(x: 0, y: rowY, width: isBlack ? keyWidth * 0.62 : keyWidth, height: rowHeight).fill()
            if !isBlack {
                NSColor(white: 0.55, alpha: 1).setFill()
                NSRect(x: 0, y: rowY + rowHeight - 0.5, width: keyWidth, height: 0.5).fill()
            }
            if pitch % 12 == 0 && rowHeight >= 8 {
                (Self.noteName(pitch) as NSString).draw(
                    at: NSPoint(x: keyWidth - 20, y: rowY + (rowHeight - 10) / 2),
                    withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.25, alpha: 1)]
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.3, alpha: 1).setFill()
        NSRect(x: keyWidth - 1, y: grid.minY, width: 1, height: grid.height).fill()
    }

    /// The rows on screen, or nil when none is.
    private func visibleRows(of layout: DrumRollLayout, in grid: NSRect) -> ClosedRange<Int>? {
        guard !layout.rows.isEmpty, isOnRow(y: grid.minY) else { return nil }
        return row(atY: grid.minY)...row(atY: grid.maxY)
    }

    /// The grid behind the notes: each drum in its own shade, a line between drums.
    private func drawDrumRows(_ layout: DrumRollLayout, in grid: NSRect) {
        guard let visible = visibleRows(of: layout, in: grid) else { return }
        for index in visible {
            let row = layout.rows[index]
            let rowY = y(ofRow: index)
            NSColor(white: row.group % 2 == 0 ? 0.15 : 0.115, alpha: 1).setFill()
            NSRect(x: grid.minX, y: rowY, width: grid.width, height: rowHeight).fill()
            NSColor(white: 0.19, alpha: 1).setFill()
            NSRect(x: grid.minX, y: rowY + rowHeight - 0.5, width: grid.width, height: 0.5).fill()
            if layout.groups[row.group].firstRow == index {
                NSColor(white: 0.38, alpha: 1).setFill()
                NSRect(x: grid.minX, y: rowY, width: grid.width, height: 1).fill()
            }
        }
    }

    /// The key column on a drum instrument: the drum's name (click: fold),
    /// then its hits with their note numbers (click: play).
    private func drawDrumKeys(_ layout: DrumRollLayout, in grid: NSRect) {
        let keys = NSRect(x: 0, y: grid.minY, width: keyWidth, height: grid.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: keys).addClip()
        NSColor(white: 0.1, alpha: 1).setFill()
        keys.fill()
        if let visible = visibleRows(of: layout, in: grid) {
            let heldPitch: Int? = {
                if case .keyboard(let pitch) = drag { return pitch }
                return nil
            }()
            let nameFont = NSFont.systemFont(ofSize: min(9, max(7, rowHeight - 3)), weight: .medium)
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: min(8, max(7, rowHeight - 3)), weight: .regular)
            let textTop = (rowHeight - nameFont.pointSize) / 2 - 2
            for index in visible {
                let row = layout.rows[index]
                let rowY = y(ofRow: index)
                let isHeld = heldPitch == row.pitch
                let shade: CGFloat = row.group % 2 == 0 ? 0.25 : 0.21
                (isHeld ? NSColor.systemOrange : NSColor(white: shade, alpha: 1)).setFill()
                NSRect(x: Self.drumNameWidth, y: rowY, width: keyWidth - Self.drumNameWidth, height: rowHeight).fill()
                NSColor(white: 0.13, alpha: 1).setFill()
                NSRect(x: Self.drumNameWidth, y: rowY + rowHeight - 0.5, width: keyWidth - Self.drumNameWidth, height: 0.5).fill()
                guard rowHeight >= 8 else { continue }
                let textWhite: CGFloat = isHeld ? 0.05 : row.isVariation ? 0.92 : 0.58
                (row.name as NSString).draw(
                    at: NSPoint(x: Self.drumNameWidth + 5, y: rowY + textTop),
                    withAttributes: [.font: nameFont, .foregroundColor: NSColor(white: textWhite, alpha: 1)]
                )
                let number = "\(row.pitch)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: numberFont, .foregroundColor: NSColor(white: isHeld ? 0.05 : 0.55, alpha: 1),
                ]
                number.draw(at: NSPoint(x: keyWidth - 5 - number.size(withAttributes: attributes).width, y: rowY + textTop + 0.5),
                            withAttributes: attributes)
            }
            let drumFont = NSFont.systemFont(ofSize: 10, weight: .bold)
            for (index, group) in layout.groups.enumerated()
            where group.firstRow <= visible.upperBound && group.firstRow + group.rowCount > visible.lowerBound {
                let top = y(ofRow: group.firstRow)
                let height = CGFloat(group.rowCount) * rowHeight
                NSColor(white: index % 2 == 0 ? 0.32 : 0.27, alpha: 1).setFill()
                NSRect(x: 0, y: top, width: Self.drumNameWidth, height: height).fill()
                NSColor(white: 0.45, alpha: 1).setFill()
                NSRect(x: 0, y: top, width: keyWidth, height: 1).fill()
                // The name stays in view while its drum is partly scrolled off.
                let lineHeight: CGFloat = 13
                let nameY = max(top, min(grid.minY, top + height - lineHeight))
                let title = "\(group.isFolded ? "▶" : "▼") \(group.name)" as NSString
                title.draw(in: NSRect(x: 4, y: nameY, width: Self.drumNameWidth - 5, height: lineHeight),
                           withAttributes: [.font: drumFont, .foregroundColor: NSColor(white: 0.95, alpha: 1)])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.3, alpha: 1).setFill()
        NSRect(x: keyWidth - 1, y: grid.minY, width: 1, height: grid.height).fill()
    }

    private func drawVelocityLane(clip: MIDIClip, meter: MusicalMeter) {
        let lane = velocityRect
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: lane.minY - Self.laneTabHeight, width: bounds.width, height: Self.laneTabHeight).fill()
        drawLaneTabs()
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.09, alpha: 1).setFill()
        lane.fill()
        guard controller.lane == .velocity else {
            drawControllerLane(clip: clip, meter: meter)
            return
        }
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        for (value, label) in [(127, "127"), (64, "64"), (0, "0")] {
            let lineY = lane.maxY - CGFloat(value) / 127 * (lane.height - 4) - 2
            (label as NSString).draw(at: NSPoint(x: keyWidth - 22, y: lineY - 5),
                                     withAttributes: [.font: labelFont, .foregroundColor: NSColor(white: 0.5, alpha: 1)])
            NSColor(white: 0.18, alpha: 1).setFill()
            NSRect(x: lane.minX, y: lineY, width: lane.width, height: 0.5).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lane).addClip()
        drawTimeLines(in: lane, meter: meter)
        let selection = controller.selection
        for index in clip.notes.indices {
            let note = clip.notes[index]
            let barX = x(ofTick: clip.timelineTick(ofContentTick: note.startTick))
            guard barX >= lane.minX - 4, barX <= lane.maxX + 4 else { continue }
            let height = CGFloat(note.velocity) / 127 * (lane.height - 4)
            let color = Self.velocityColor(note.velocity, muted: note.isMuted)
            (selection.contains(index) ? NSColor.white : color).setFill()
            NSRect(x: barX, y: lane.maxY - 2 - height, width: 2, height: height).fill()
            NSBezierPath(ovalIn: NSRect(x: barX - 2, y: lane.maxY - 2 - height - 2, width: 6, height: 4)).fill()
        }
        if case .velocityNote(let index, _, _) = drag, clip.notes.indices.contains(index) {
            let note = clip.notes[index]
            let dot = velocityDotCenter(of: note, in: clip)
            let text = String(localized: "Velocity \(Int(note.velocity))") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attributes)
            var origin = NSPoint(x: dot.x + 8, y: dot.y - size.height / 2)
            if origin.x + size.width > lane.maxX - 2 { origin.x = dot.x - 8 - size.width }
            origin.y = max(lane.minY + 1, min(lane.maxY - size.height - 1, origin.y))
            NSColor(white: 0, alpha: 0.7).setFill()
            NSBezierPath(roundedRect: NSRect(origin: origin, size: size).insetBy(dx: -3, dy: -1),
                         xRadius: 3, yRadius: 3).fill()
            text.draw(at: origin, withAttributes: attributes)
        }
        if case .velocityLine(let startX, let startValue, let current, _) = drag {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: startX, y: lane.maxY - 2 - CGFloat(startValue) / 127 * (lane.height - 4)))
            line.line(to: NSPoint(x: current.x, y: lane.maxY - 2 - CGFloat(velocity(atY: current.y)) / 127 * (lane.height - 4)))
            NSColor.white.setStroke()
            line.lineWidth = 1.5
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Controller lanes

    /// The tabs over the lane, left to right.
    private var laneTabRects: [(lane: PianoRollController.Lane, rect: NSRect)] {
        var left = keyWidth + 4
        let top = velocityRect.minY - Self.laneTabHeight + 2
        return PianoRollController.Lane.allCases.map { lane in
            let width = (lane.title as NSString).size(withAttributes: [.font: Self.laneTabFont]).width + 14
            defer { left += width + 2 }
            return (lane, NSRect(x: left, y: top, width: width, height: Self.laneTabHeight - 4))
        }
    }

    /// Drawn like the bottom panel's Mixer / Piano Roll tabs.
    private func drawLaneTabs() {
        for (lane, rect) in laneTabRects {
            let isSelected = lane == controller.lane
            if isSelected {
                NSColor(white: 1, alpha: 0.14).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
            let title = lane.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.laneTabFont,
                .foregroundColor: NSColor(white: 1, alpha: isSelected ? 0.95 : 0.45),
            ]
            let size = title.size(withAttributes: attributes)
            title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private static func laneColor(_ lane: PianoRollController.Lane) -> NSColor {
        switch lane {
        case .velocity, .pitchBend: return .systemOrange
        case .modulation: return .systemTeal
        case .aftertouch: return .systemGreen
        }
    }

    private func laneY(ofValue value: Int) -> CGFloat {
        let lane = velocityRect
        return lane.maxY - 2 - CGFloat(value) / CGFloat(controller.lane.maximum) * (lane.height - 4)
    }

    /// The value at `y`; pitch bend snaps to the centre near it.
    private func laneValue(atY y: CGFloat) -> Int {
        let lane = velocityRect
        let kind = controller.lane
        if kind == .pitchBend, abs(y - laneY(ofValue: kind.restingValue)) <= 3 { return kind.restingValue }
        let value = Int(((lane.maxY - 2 - y) / (lane.height - 4) * CGFloat(kind.maximum)).rounded())
        return max(0, min(kind.maximum, value))
    }

    /// Content tick at `x`, kept inside the clip's visible part.
    private func contentTick(atX x: CGFloat, in clip: MIDIClip) -> Int {
        let tick = self.tick(atX: x) - clip.startTick + clip.contentOffsetTicks
        return max(clip.contentOffsetTicks, min(clip.contentOffsetTicks + clip.lengthTicks - 1, tick))
    }

    /// The lane's events in the clip's visible part, in time order, with
    /// their index in `clip.events`.
    private func laneEvents(in clip: MIDIClip) -> [(index: Int, event: MIDIChannelEvent)] {
        let range = clip.contentOffsetTicks..<(clip.contentOffsetTicks + clip.lengthTicks)
        let kind = controller.lane
        return clip.events.enumerated()
            .filter { kind.shows($0.element) && range.contains($0.element.tick) }
            .map { (index: $0.offset, event: $0.element) }
            .sorted { ($0.event.tick, $0.index) < ($1.event.tick, $1.index) }
    }

    /// Channel of new events: the lane's existing ones, else the notes'.
    private func laneChannel(in clip: MIDIClip) -> UInt8 {
        clip.events.first(where: controller.lane.shows)?.channel ?? clip.notes.first?.channel ?? 0
    }

    /// A dot at each event joined by lines; after the last, a fainter line
    /// holds its value to the clip's end.
    private func drawControllerLane(clip: MIDIClip, meter: MusicalMeter) {
        let lane = velocityRect
        let kind = controller.lane
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        let marks: [(Int, String)] = kind == .pitchBend
            ? [(kind.maximum, "+8191"), (kind.restingValue, "0"), (0, "−8192")]
            : [(127, "127"), (64, "64"), (0, "0")]
        for (value, label) in marks {
            let lineY = laneY(ofValue: value)
            let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor(white: 0.5, alpha: 1)]
            let width = (label as NSString).size(withAttributes: attributes).width
            (label as NSString).draw(at: NSPoint(x: keyWidth - 4 - width, y: lineY - 5), withAttributes: attributes)
            let isCentre = kind == .pitchBend && value == kind.restingValue
            NSColor(white: isCentre ? 0.32 : 0.18, alpha: 1).setFill()
            NSRect(x: lane.minX, y: lineY, width: lane.width, height: isCentre ? 1 : 0.5).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lane).addClip()
        drawTimeLines(in: lane, meter: meter)
        let points = laneEvents(in: clip).map { item in
            NSPoint(x: x(ofTick: clip.timelineTick(ofContentTick: item.event.tick)), y: laneY(ofValue: kind.value(of: item.event)))
        }
        let color = Self.laneColor(kind)
        if let first = points.first, let last = points.last {
            let line = NSBezierPath()
            line.move(to: first)
            points.dropFirst().forEach(line.line)
            line.lineWidth = 1.5
            color.setStroke()
            line.stroke()
            let hold = NSBezierPath()
            hold.move(to: last)
            hold.line(to: NSPoint(x: x(ofTick: clip.endTick), y: last.y))
            hold.lineWidth = 1
            color.withAlphaComponent(0.4).setStroke()
            hold.stroke()
        }
        color.setFill()
        for point in points where point.x >= lane.minX - 4 && point.x <= lane.maxX + 4 {
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func controllerLaneMouseDown(at point: NSPoint, option: Bool, in clip: MIDIClip) {
        let start = (tick: contentTick(atX: point.x, in: clip), value: laneValue(atY: point.y))
        switch controller.tool {
        case .arrow:
            guard let index = laneEvent(near: point, in: clip) else { return }
            controller.beginEdit()
            drag = .lanePoint(index: index)
        case .pencil:
            controller.beginEdit()
            let originals = clip.events
            setLaneLine(from: start, to: start, over: originals, in: clip)
            drag = option ? .laneLine(start: start, originals: originals) : .laneDraw(last: start)
        case .eraser:
            controller.beginEdit()
            eraseLaneEvents(fromX: point.x, toX: point.x, in: clip)
            drag = .laneErase(lastX: point.x)
        }
        needsDisplay = true
    }

    /// The lane's event whose dot is under `point`, nearest first.
    private func laneEvent(near point: NSPoint, in clip: MIDIClip) -> Int? {
        let kind = controller.lane
        return laneEvents(in: clip)
            .map { item -> (index: Int, distance: CGFloat) in
                let dx = x(ofTick: clip.timelineTick(ofContentTick: item.event.tick)) - point.x
                let dy = laneY(ofValue: kind.value(of: item.event)) - point.y
                return (item.index, abs(dx) <= 5 && abs(dy) <= 6 ? hypot(dx, dy) : .infinity)
            }
            .filter { $0.distance.isFinite }
            .min { $0.distance < $1.distance }?.index
    }

    /// Replaces the lane's events (of its channel) between the two content
    /// ticks with a straight line, an event every 3 points of width.
    private func setLaneLine(from: (tick: Int, value: Int), to: (tick: Int, value: Int),
                             over events: [MIDIChannelEvent], in clip: MIDIClip) {
        let kind = controller.lane
        let channel = laneChannel(in: clip)
        let low = min(from.tick, to.tick)
        let high = max(from.tick, to.tick)
        var result = events.filter { !(kind.shows($0) && $0.channel == channel && (low...high).contains($0.tick)) }
        let step = max(1, Int((3 / ppt).rounded()))
        var tick = low
        while true {
            let amount = to.tick == from.tick ? 1 : Double(tick - from.tick) / Double(to.tick - from.tick)
            let value = Double(from.value) + Double(to.value - from.value) * max(0, min(1, amount))
            if let event = kind.event(tick: tick, value: Int(value.rounded()), channel: channel) {
                result.append(event)
            }
            guard tick < high else { break }
            tick = min(high, tick + step)
        }
        // Stable, so events at the same tick keep their order.
        clip.events = result.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)
    }

    /// Removes the lane's events whose dots lie between the two x positions.
    private func eraseLaneEvents(fromX: CGFloat, toX: CGFloat, in clip: MIDIClip) {
        let low = min(fromX, toX) - 3
        let high = max(fromX, toX) + 3
        let removed = Set(laneEvents(in: clip).filter { item in
            let eventX = x(ofTick: clip.timelineTick(ofContentTick: item.event.tick))
            return eventX >= low && eventX <= high
        }.map(\.index))
        guard !removed.isEmpty else { return }
        clip.events = clip.events.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }

    private var playheadTick: Int? {
        guard let engine = projectState?.audioEngine else { return nil }
        return MIDITiming.ticks(seconds: engine.currentTime, bpm: engine.bpm)
    }

    private func drawPlayhead(projectState: ProjectState) {
        guard let tick = playheadTick else { return }
        let lineX = x(ofTick: tick)
        lastPlayheadX = lineX
        guard lineX >= keyWidth, lineX <= bounds.maxX else { return }
        let color = projectState.audioEngine.isRecording ? NSColor.systemRed
            : projectState.audioEngine.isPlaying ? NSColor.systemGreen : NSColor.systemOrange
        color.setFill()
        NSRect(x: lineX, y: 0, width: 1, height: bounds.height).fill()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: lineX - 5, y: 0))
        marker.line(to: NSPoint(x: lineX + 5, y: 0))
        marker.line(to: NSPoint(x: lineX, y: 7))
        marker.close()
        marker.fill()
    }

    /// The meter of the last drawing: a change in the transport bar redraws.
    private var drawnMeter: MusicalMeter?

    func startPlayheadTimer() {
        playheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            onMainThread {
                guard let self, let tick = self.playheadTick else { return }
                if self.followArranger() || self.drawnMeter != self.projectState?.audioEngine.meter {
                    self.needsDisplay = true
                } else if abs(self.x(ofTick: tick) - self.lastPlayheadX) >= 0.5 {
                    self.needsDisplay = true
                }
            }
        }
    }

    /// While following: the arranger's visible span across the grid's
    /// width. True when the view moved.
    private func followArranger() -> Bool {
        guard controller.followsArranger, let projectState else { return false }
        let bpm = projectState.audioEngine.bpm
        let visibleSeconds = Double(projectState.timelineViewportWidth) / Double(max(0.001, projectState.pixelsPerSecond))
        let visibleTicks = Double(max(1, MIDITiming.ticks(seconds: visibleSeconds, bpm: bpm)))
        let newPPT = min(PianoRollController.zoomRange.upperBound,
                         max(PianoRollController.zoomRange.lowerBound, Double(gridRect.width) / visibleTicks))
        let newScroll = MIDITiming.seconds(ticks: 1, bpm: bpm) > 0
            ? projectState.timelineScrollTime / MIDITiming.seconds(ticks: 1, bpm: bpm)
            : 0
        guard abs(newPPT - controller.pixelsPerTick) > 1e-9 || abs(newScroll - scrollTick) >= 0.5 else { return false }
        if abs(newPPT - controller.pixelsPerTick) > 1e-9 {
            controller.pixelsPerTick = newPPT
        }
        scrollTick = newScroll
        updateScroller()
        return true
    }

    func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        controller.hasKeyFocus = false
    }

    // MARK: Mouse

    private var isLocked: Bool { projectState?.audioEngine.isRecording ?? true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
        updateHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    private func updateHover(at point: NSPoint?) {
        let index = point.flatMap { note(at: $0)?.index }
        guard index != hoveredNote || (index != nil && point != hoverPoint) else { return }
        hoveredNote = index
        if let point { hoverPoint = point }
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: NSPoint) {
        if controller.lane == .velocity, velocityRect.contains(point) {
            if let clip, !isLocked, velocityDot(at: point, in: clip) != nil {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }
        if controller.lane != .velocity, velocityRect.contains(point) {
            switch controller.tool {
            case .arrow: NSCursor.arrow.set()
            case .pencil: NSCursor.crosshair.set()
            case .eraser: NSCursor.pointingHand.set()
            }
            return
        }
        guard gridRect.contains(point) else {
            NSCursor.arrow.set()
            return
        }
        switch controller.tool {
        case .arrow:
            if let hit = note(at: point), hit.edge != 0 {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        case .pencil:
            NSCursor.crosshair.set()
        case .eraser:
            NSCursor.pointingHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if controller.clip != nil, let tab = laneTabRects.first(where: { $0.rect.contains(point) }) {
            controller.lane = tab.lane
            needsDisplay = true
            return
        }
        // Folding changes the view only, so it also works on a locked track.
        if let drumLayout, controller.clip != nil, point.x < Self.drumNameWidth, gridRect.minY...gridRect.maxY ~= point.y {
            if isOnRow(y: point.y) {
                let group = drumLayout.groups[drumLayout.rows[row(atY: point.y)].group]
                controller.toggleDrumFolded(group.id)
                refreshDrumLayout()
                clampScroll()
                needsDisplay = true
            }
            return
        }
        guard let clip, !isLocked else { return }
        let shift = event.modifierFlags.contains(.shift)

        if point.y < Self.rulerHeight, point.x >= keyWidth {
            drag = .ruler
            locatePlayhead(atX: point.x)
            return
        }
        if point.x < keyWidth, gridRect.minY...gridRect.maxY ~= point.y {
            guard isOnRow(y: point.y) else { return }
            let pitch = pitch(atY: point.y)
            drag = .keyboard(pitch: pitch)
            controller.startAudition(pitch: pitch, velocity: controller.defaultVelocity)
            needsDisplay = true
            return
        }
        if velocityRect.contains(point), controller.lane != .velocity {
            controllerLaneMouseDown(at: point, option: event.modifierFlags.contains(.option), in: clip)
            return
        }
        if velocityRect.contains(point) {
            if !event.modifierFlags.contains(.option), let index = velocityDot(at: point, in: clip) {
                controller.beginEdit()
                drag = .velocityNote(index: index, startY: point.y, startVelocity: Int(clip.notes[index].velocity))
                startVelocityAudition(pitch: Int(clip.notes[index].pitch))
                needsDisplay = true
                return
            }
            controller.beginEdit()
            let value = velocity(atY: point.y)
            if event.modifierFlags.contains(.option) {
                let originals = Dictionary(uniqueKeysWithValues: velocityTargets(in: clip).map { ($0, clip.notes[$0].velocity) })
                drag = .velocityLine(startX: point.x, startValue: value, current: point, originals: originals)
                return
            }
            setVelocity(near: point.x, to: value, in: clip)
            drag = .velocity(lastX: point.x, lastValue: value)
            return
        }
        guard gridRect.contains(point) else { return }
        let hit = note(at: point)
        let mouseTick = tick(atX: point.x)

        switch controller.tool {
        case .arrow:
            if let hit {
                if shift {
                    toggleSelection(hit.index)
                    return
                }
                if !controller.selection.contains(hit.index) {
                    controller.selection = [hit.index]
                }
                controller.beginEdit()
                if event.modifierFlags.contains(.option) {
                    duplicateSelectionInPlace(clip)
                }
                let originals = Dictionary(uniqueKeysWithValues: controller.validSelection(in: clip).map { ($0, clip.notes[$0]) })
                let note = clip.notes[hit.index]
                controller.audition(pitch: Int(note.pitch), velocity: Int(note.velocity))
                switch hit.edge {
                case 1: drag = .resizeEnd(anchor: hit.index, originals: originals, startTick: mouseTick)
                case -1: drag = .resizeStart(anchor: hit.index, originals: originals, startTick: mouseTick)
                default:
                    drag = .move(anchor: hit.index, originals: originals, startTick: mouseTick,
                                 startPitch: pitch(atY: point.y), startRow: row(atY: point.y), lastPitchDelta: 0)
                }
            } else if event.clickCount == 2 {
                addNote(at: point, in: clip)
            } else {
                drag = .rubberBand(start: point, current: point, base: shift ? controller.selection : [])
                if !shift { controller.selection = [] }
            }
        case .pencil:
            // On a note too: the new note may overlap it.
            addNote(at: point, in: clip)
        case .eraser:
            controller.beginEdit()
            drag = .erase
            if let hit { controller.deleteNotes([hit.index]) }
        }
        needsDisplay = true
    }

    /// Pencil or double-click: a note of the grid length on the grid; the
    /// drag that follows sets its length.
    private func addNote(at point: NSPoint, in clip: MIDIClip) {
        guard isOnRow(y: point.y) else { return }
        controller.beginEdit()
        let start = controller.snappedDown(tick(atX: point.x))
        let pitch = pitch(atY: point.y)
        guard let index = controller.addNote(atTimelineTick: start, pitch: pitch, lengthTicks: controller.gridTicks) else { return }
        controller.selection = [index]
        controller.audition(pitch: pitch, velocity: controller.defaultVelocity)
        drag = .resizeEnd(anchor: index, originals: [index: clip.notes[index]], startTick: start + controller.gridTicks)
    }

    private func toggleSelection(_ index: Int) {
        if controller.selection.contains(index) {
            controller.selection.remove(index)
        } else {
            controller.selection.insert(index)
        }
    }

    /// Option-drag: copies of the selected notes stay where they are while
    /// the originals move.
    private func duplicateSelectionInPlace(_ clip: MIDIClip) {
        clip.notes += controller.validSelection(in: clip).map { clip.notes[$0] }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let clip else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mouseTick = tick(atX: point.x)
        switch drag {
        case .none, .keyboard:
            break
        case .ruler:
            locatePlayhead(atX: point.x)
        case .move(let anchor, let originals, let startTick, let startPitch, let startRow, let lastPitchDelta):
            guard let anchorNote = originals[anchor] else { return }
            let anchorStart = clip.timelineTick(ofContentTick: anchorNote.startTick)
            let earliest = originals.values.map { clip.timelineTick(ofContentTick: $0.startTick) }.min() ?? 0
            let tickDelta = max(-earliest, controller.snapped(anchorStart + mouseTick - startTick) - anchorStart)
            if let drumLayout {
                // By rows. A note that stays on its row keeps its pitch (on a
                // folded drum, the row holds several).
                let rows = originals.values.map { drumLayout.row(ofPitch: Int($0.pitch)) }
                let rowDelta = max(-(rows.min() ?? 0), min(drumLayout.rows.count - 1 - (rows.max() ?? 0), row(atY: point.y) - startRow))
                func moved(_ original: MIDINote) -> UInt8 {
                    rowDelta == 0 ? original.pitch : UInt8(drumLayout.rows[drumLayout.row(ofPitch: Int(original.pitch)) + rowDelta].pitch)
                }
                var notes = clip.notes
                for (index, original) in originals where notes.indices.contains(index) {
                    notes[index].startTick = original.startTick + tickDelta
                    notes[index].pitch = moved(original)
                }
                clip.notes = notes
                if rowDelta != lastPitchDelta {
                    controller.audition(pitch: Int(moved(anchorNote)), velocity: Int(anchorNote.velocity))
                    drag = .move(anchor: anchor, originals: originals, startTick: startTick,
                                 startPitch: startPitch, startRow: startRow, lastPitchDelta: rowDelta)
                }
                break
            }
            let pitches = originals.values.map { Int($0.pitch) }
            let pitchDelta = max(-(pitches.min() ?? 0), min(127 - (pitches.max() ?? 127), pitch(atY: point.y) - startPitch))
            var notes = clip.notes
            for (index, original) in originals where notes.indices.contains(index) {
                notes[index].startTick = original.startTick + tickDelta
                notes[index].pitch = UInt8(Int(original.pitch) + pitchDelta)
            }
            clip.notes = notes
            if pitchDelta != lastPitchDelta {
                controller.audition(pitch: Int(anchorNote.pitch) + pitchDelta, velocity: Int(anchorNote.velocity))
                drag = .move(anchor: anchor, originals: originals, startTick: startTick,
                             startPitch: startPitch, startRow: startRow, lastPitchDelta: pitchDelta)
            }
        case .resizeEnd(let anchor, let originals, let startTick):
            guard let anchorNote = originals[anchor] else { return }
            let anchorEnd = clip.timelineTick(ofContentTick: anchorNote.endTick)
            let delta = controller.snapped(anchorEnd + mouseTick - startTick) - anchorEnd
            let shortest = (projectState?.snapToGrid ?? true) ? controller.gridTicks : 10
            var notes = clip.notes
            for (index, original) in originals where notes.indices.contains(index) {
                notes[index].lengthTicks = max(min(shortest, original.lengthTicks), original.lengthTicks + delta)
            }
            clip.notes = notes
        case .resizeStart(let anchor, let originals, let startTick):
            guard let anchorNote = originals[anchor] else { return }
            let anchorStart = clip.timelineTick(ofContentTick: anchorNote.startTick)
            let delta = controller.snapped(anchorStart + mouseTick - startTick) - anchorStart
            var notes = clip.notes
            for (index, original) in originals where notes.indices.contains(index) {
                let shift = min(delta, original.lengthTicks - 10)
                notes[index].startTick = max(0, original.startTick + shift)
                notes[index].lengthTicks = original.endTick - notes[index].startTick
            }
            clip.notes = notes
        case .rubberBand(let start, _, let base):
            drag = .rubberBand(start: start, current: point, base: base)
            let band = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            controller.selection = base.union(clip.notes.indices.filter { rect(ofNote: $0, in: clip).intersects(band) })
        case .erase:
            if let hit = note(at: point) {
                controller.deleteNotes([hit.index])
            }
        case .velocity(let lastX, let lastValue):
            let value = velocity(atY: point.y)
            setVelocities(from: (lastX, lastValue), to: (point.x, value), in: clip)
            drag = .velocity(lastX: point.x, lastValue: value)
        case .velocityNote(let index, let startY, let startVelocity):
            guard clip.notes.indices.contains(index) else { break }
            let change = (startY - point.y) / (velocityRect.height - 4) * 127
            let value = UInt8(max(1, min(127, startVelocity + Int(change.rounded()))))
            if clip.notes[index].velocity != value {
                var notes = clip.notes
                notes[index].velocity = value
                clip.notes = notes
            }
        case .velocityLine(let startX, let startValue, _, let originals):
            // Notes the line no longer covers go back to their velocity.
            var notes = clip.notes
            for (index, velocity) in originals where notes.indices.contains(index) {
                notes[index].velocity = velocity
            }
            clip.notes = notes
            setVelocities(from: (startX, startValue), to: (point.x, velocity(atY: point.y)), in: clip)
            drag = .velocityLine(startX: startX, startValue: startValue, current: point, originals: originals)
        case .laneDraw(let last):
            let next = (tick: contentTick(atX: point.x, in: clip), value: laneValue(atY: point.y))
            setLaneLine(from: last, to: next, over: clip.events, in: clip)
            drag = .laneDraw(last: next)
        case .laneLine(let start, let originals):
            let end = (tick: contentTick(atX: point.x, in: clip), value: laneValue(atY: point.y))
            setLaneLine(from: start, to: end, over: originals, in: clip)
        case .laneErase(let lastX):
            eraseLaneEvents(fromX: lastX, toX: point.x, in: clip)
            drag = .laneErase(lastX: point.x)
        case .lanePoint(let index):
            guard clip.events.indices.contains(index) else { break }
            let original = clip.events[index]
            if let moved = controller.lane.event(tick: original.tick, value: laneValue(atY: point.y), channel: original.channel) {
                clip.events[index] = moved
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .velocityNote:
            stopVelocityAudition()
            controller.endEdit()
        case .move, .resizeEnd, .resizeStart, .erase, .velocity, .velocityLine,
             .laneDraw, .laneLine, .laneErase, .lanePoint:
            controller.endEdit()
        case .keyboard(let pitch):
            controller.stopAudition(pitch: pitch)
        case .none, .rubberBand, .ruler:
            break
        }
        drag = .none
        refreshDrumLayout()
        clampScroll()
        needsDisplay = true
    }

    // MARK: Right-click menu

    /// On a note: that note (or the selection it is in) with the note
    /// commands; elsewhere the paste and select commands. Never the mixer's.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard controller.clip != nil, !isLocked else { return nil }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // A note outside the selection becomes the selection; an empty spot
        // keeps it, so the menu can act on it.
        if let hit = note(at: point), !controller.selection.contains(hit.index) {
            controller.selection = [hit.index]
        }
        needsDisplay = true
        let controller = controller
        let hasSelection = !controller.selection.isEmpty
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(String(localized: "Mute Notes"), symbol: "speaker.slash",
                                     enabled: controller.selectionHasUnmutedNotes) {
            controller.setSelectionMuted(true)
        })
        menu.addItem(ClosureMenuItem(String(localized: "Unmute Notes"), symbol: "speaker.wave.2",
                                     enabled: controller.selectionHasMutedNotes) {
            controller.setSelectionMuted(false)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Cut"), symbol: "scissors", enabled: hasSelection) {
            controller.cutSelection()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Copy"), symbol: "doc.on.doc", enabled: hasSelection) {
            controller.copySelection()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Paste at Playhead"), symbol: "doc.on.clipboard",
                                     enabled: controller.canPaste) {
            controller.paste()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Delete Notes"), symbol: "trash", enabled: hasSelection) {
            controller.deleteSelection()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Select All Notes"), symbol: nil, enabled: true) {
            controller.selectAll()
        })
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        // Shown here, not passed on: the bottom panel's SwiftUI menu (the
        // mixer's Add FX) must not open over the piano roll.
        if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private func locatePlayhead(atX x: CGFloat) {
        guard let projectState, !projectState.audioEngine.isRecording else { return }
        let seconds = MIDITiming.seconds(ticks: max(0, tick(atX: x)), bpm: projectState.audioEngine.bpm)
        projectState.audioEngine.seek(to: seconds, tracks: projectState.tracks, fxChannels: projectState.fxChannels)
        needsDisplay = true
    }

    // MARK: Velocity lane

    /// Where a note's velocity dot is drawn.
    private func velocityDotCenter(of note: MIDINote, in clip: MIDIClip) -> NSPoint {
        let lane = velocityRect
        let barX = x(ofTick: clip.timelineTick(ofContentTick: note.startTick))
        let height = CGFloat(note.velocity) / 127 * (lane.height - 4)
        return NSPoint(x: barX + 1, y: lane.maxY - 2 - height)
    }

    /// The note whose velocity dot is under `point` (the nearest if several).
    private func velocityDot(at point: NSPoint, in clip: MIDIClip) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in clip.notes.indices {
            let dot = velocityDotCenter(of: clip.notes[index], in: clip)
            let dx = abs(dot.x - point.x)
            let dy = abs(dot.y - point.y)
            guard dx <= Self.velocityDotGrabRadius, dy <= Self.velocityDotGrabRadius else { continue }
            let distance = dx * dx + dy * dy
            if distance < best?.distance ?? .infinity { best = (index, distance) }
        }
        return best?.index
    }

    /// Sounds the dragged note now and every half second at its current
    /// velocity; each repeat ends the previous one, so one note sounds.
    private func startVelocityAudition(pitch: Int) {
        stopVelocityAudition()
        guard controller.auditionsNotes else { return }
        velocityAuditionPitch = pitch
        playVelocityAudition()
        let timer = Timer(timeInterval: Self.velocityAuditionInterval, repeats: true) { [weak self] _ in
            self?.playVelocityAudition()
        }
        RunLoop.main.add(timer, forMode: .common)
        velocityAuditionTimer = timer
    }

    private func playVelocityAudition() {
        guard let pitch = velocityAuditionPitch, case .velocityNote(let index, _, _) = drag,
              let clip, clip.notes.indices.contains(index) else { return }
        controller.stopAudition(pitch: pitch)
        controller.startAudition(pitch: pitch, velocity: Int(clip.notes[index].velocity))
    }

    private func stopVelocityAudition() {
        velocityAuditionTimer?.invalidate()
        velocityAuditionTimer = nil
        if let pitch = velocityAuditionPitch { controller.stopAudition(pitch: pitch) }
        velocityAuditionPitch = nil
    }

    private func velocity(atY y: CGFloat) -> Int {
        let lane = velocityRect
        return max(1, min(127, Int(((lane.maxY - 2 - y) / (lane.height - 4) * 127).rounded())))
    }

    /// The notes a velocity drag acts on: the selection when there is one.
    private func velocityTargets(in clip: MIDIClip) -> [Int] {
        controller.selection.isEmpty ? Array(clip.notes.indices) : controller.validSelection(in: clip)
    }

    private func setVelocity(near x: CGFloat, to value: Int, in clip: MIDIClip) {
        var notes = clip.notes
        for index in velocityTargets(in: clip) {
            let noteX = self.x(ofTick: clip.timelineTick(ofContentTick: notes[index].startTick))
            if abs(noteX - x) <= 4 {
                notes[index].velocity = UInt8(value)
            }
        }
        clip.notes = notes
        needsDisplay = true
    }

    /// Dragging across the lane draws a line: each note passed takes the
    /// line's value at its start.
    private func setVelocities(from: (x: CGFloat, value: Int), to: (x: CGFloat, value: Int), in clip: MIDIClip) {
        let low = min(from.x, to.x) - 2
        let high = max(from.x, to.x) + 2
        var notes = clip.notes
        for index in velocityTargets(in: clip) {
            let noteX = x(ofTick: clip.timelineTick(ofContentTick: notes[index].startTick))
            guard noteX >= low, noteX <= high else { continue }
            let amount = to.x == from.x ? 1 : (noteX - from.x) / (to.x - from.x)
            let value = Double(from.value) + Double(to.value - from.value) * Double(max(0, min(1, amount)))
            notes[index].velocity = UInt8(max(1, min(127, Int(value.rounded()))))
        }
        clip.notes = notes
    }

    // MARK: Scrolling and keys

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        // On the ruler the wheel zooms in time, as in the track view.
        if event.modifierFlags.contains(.command) || point.y < Self.rulerHeight {
            // Zoom in time around the pointer.
            let anchor = scrollTick + Double((point.x - keyWidth) / ppt)
            controller.zoom(by: pow(1.01, Double(event.scrollingDeltaY * scale)))
            scrollTick = anchor - Double((point.x - keyWidth) / ppt)
        } else if event.modifierFlags.contains(.option) {
            let anchorPitch = Double(point.y - Self.rulerHeight + scrollY) / Double(rowHeight)
            controller.zoomRows(by: pow(1.01, Double(event.scrollingDeltaY * scale)))
            scrollY = CGFloat(anchorPitch) * rowHeight - (point.y - Self.rulerHeight)
        } else {
            if event.scrollingDeltaX != 0 {
                controller.followsArranger = false
            }
            scrollTick -= Double(event.scrollingDeltaX * scale / ppt)
            scrollY -= event.scrollingDeltaY * scale
        }
        clampScroll()
        needsDisplay = true
    }

    /// ↑↓ on a drum instrument: the next way of striking, keeping the note
    /// on screen. With Option it goes past the drum's end to the next drum.
    private func moveSelectionToVariation(step: Int, crossesDrums: Bool) {
        guard let pitch = controller.moveSelectionToVariation(step: step, crossesDrums: crossesDrums) else { return }
        let grid = gridRect
        let rowY = y(ofPitch: pitch)
        if rowY < grid.minY {
            scrollY -= grid.minY - rowY
        } else if rowY + rowHeight > grid.maxY {
            scrollY += rowY + rowHeight - grid.maxY
        }
        clampScroll()
    }

    override func keyDown(with event: NSEvent) {
        guard !isLocked else { return }
        let octave = event.modifierFlags.contains(.shift) ? 12 : 1
        switch event.keyCode {
        case 51, 117:
            controller.deleteSelection()
        case 126 where drumLayout != nil:
            moveSelectionToVariation(step: -1, crossesDrums: event.modifierFlags.contains(.option))
        case 125 where drumLayout != nil:
            moveSelectionToVariation(step: 1, crossesDrums: event.modifierFlags.contains(.option))
        case 126:
            controller.transposeSelection(by: octave)
        case 125:
            controller.transposeSelection(by: -octave)
        case 12 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty:
            controller.quantize()
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }
}
