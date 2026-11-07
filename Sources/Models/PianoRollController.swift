import Foundation
import Combine

/// The piano roll's state and its note edits. It edits one MIDI clip, found
/// by ID each time (an undo replaces the clip objects). Positions given to
/// and taken from it are timeline ticks; notes keep content ticks.
@MainActor
public final class PianoRollController: ObservableObject {
    public enum Tool: String, CaseIterable, Identifiable {
        case arrow, pencil, eraser
        public var id: String { rawValue }
    }

    /// What the lane under the notes shows and edits (its tabs).
    public enum Lane: String, CaseIterable, Identifiable {
        case velocity, pitchBend, modulation, aftertouch
        public var id: String { rawValue }
    }

    @Published public private(set) var trackID: UUID?
    /// The canvas's horizontal scroll, for the scroll bar under it (not
    /// published here, so scrolling does not rebuild the whole piano roll).
    let scrollPosition = PanelScrollPosition()
    @Published public private(set) var clipID: UUID?
    @Published public var tool: Tool = .arrow
    @Published public var lane: Lane = .velocity
    /// Note value of the grid: 4 = quarter, 16 = sixteenth.
    @Published public var gridDivision: Int = 16
    @Published public var isTripletGrid = false
    /// Velocity of the notes drawn with the pencil.
    @Published public var defaultVelocity: Int = 100
    /// Plays a note when it is drawn, picked or moved to another pitch (the
    /// toolbar's speaker button). The keyboard sounds either way.
    @Published public var auditionsNotes = true
    /// Selected notes, as indices into the clip's notes.
    @Published public var selection: Set<Int> = []
    /// True while the piano roll has the keyboard (edit keys go to it).
    public var hasKeyFocus = false
    /// Horizontal zoom (points per tick) and the height of a key row.
    @Published public var pixelsPerTick: Double = 0.0625
    @Published public var rowHeight: Double = 12
    public static let zoomRange = 0.005...1.0
    public static let rowHeightRange = 6.0...30.0
    /// Drums shown as one row, when the rows are grouped by drum.
    @Published public var foldedDrums: Set<String> = []
    /// What [Q] moves to the grid. Start and end toggle separately;
    /// "keep length" moves the start and the end with it, and excludes the
    /// other two (see the setters below).
    @Published public private(set) var quantizesStart = true
    @Published public private(set) var quantizesEnd = false
    @Published public private(set) var quantizeKeepsLength = false

    public func toggleQuantizeStart() {
        quantizesStart.toggle()
        if quantizesStart { quantizeKeepsLength = false }
    }

    public func toggleQuantizeEnd() {
        quantizesEnd.toggle()
        if quantizesEnd { quantizeKeepsLength = false }
    }

    public func toggleQuantizeKeepsLength() {
        quantizeKeepsLength.toggle()
        if quantizeKeepsLength {
            quantizesStart = false
            quantizesEnd = false
        }
    }

    public var canQuantize: Bool {
        hasSelection && (quantizesStart || quantizesEnd || quantizeKeepsLength)
    }

    /// The quantize and the adjustments change the selected notes only (and
    /// nothing without a selection).
    public var hasSelection: Bool {
        clip != nil && !selection.isEmpty
    }

    /// Moves the selected notes to the nearest grid lines, as the quantize
    /// mode says. A note whose end would reach its start keeps one grid step.
    public func quantize() {
        guard let clip, canQuantize else { return }
        let targets = Array(selection)
        let step = gridTicks
        let nearest = { (tick: Int) -> Int in max(0, Int((Double(tick) / Double(step)).rounded()) * step) }
        beginEdit()
        var notes = clip.notes
        for index in targets where notes.indices.contains(index) {
            let start = clip.timelineTick(ofContentTick: notes[index].startTick)
            let end = start + notes[index].lengthTicks
            var newStart = start
            var newEnd = end
            if quantizeKeepsLength {
                newStart = nearest(start)
                newEnd = newStart + notes[index].lengthTicks
            } else {
                if quantizesStart { newStart = nearest(start) }
                if quantizesEnd { newEnd = nearest(end) }
                if newEnd <= newStart { newEnd = newStart + step }
            }
            notes[index].startTick += newStart - start
            notes[index].lengthTicks = newEnd - newStart
        }
        clip.notes = notes
        endEdit()
    }

    /// Shows the same time span as the arranger (scrolling with it while it
    /// follows the playhead). Turned off when the piano roll is scrolled or
    /// zoomed by hand.
    @Published public var followsArranger = false
    /// Raised to make the canvas fit the clip in view (it was opened).
    @Published public private(set) var scrollRequest = 0

    weak var project: ProjectState?
    private var clipboard: [MIDINote] = []
    /// The clip as an edit began, to tell whether it changed.
    private var editStartState: (notes: [MIDINote], events: [MIDIChannelEvent], start: Int, length: Int, offset: Int)?
    private var heldAuditions: Set<UInt8> = []

    public static let divisions = [1, 2, 4, 8, 16, 32]

    // MARK: Target

    public var track: AudioTrack? {
        project?.tracks.first { $0.id == trackID }
    }

    public var clip: MIDIClip? {
        track?.midiClips.first { $0.id == clipID }
    }

    func open(trackID: UUID, clipID: UUID) {
        if self.clipID != clipID {
            selection = []
        }
        self.trackID = trackID
        self.clipID = clipID
        scrollRequest += 1
    }

    /// A zoom by hand (buttons, wheel), which ends following the arranger.
    public func zoom(by factor: Double) {
        followsArranger = false
        pixelsPerTick = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, pixelsPerTick * factor))
    }

    public func zoomRows(by factor: Double) {
        rowHeight = min(Self.rowHeightRange.upperBound, max(Self.rowHeightRange.lowerBound, rowHeight * factor))
    }

    /// The selected indices that still have a note, in order. A recording in
    /// replace mode can remove notes while they are selected.
    func validSelection(in clip: MIDIClip) -> [Int] {
        selection.filter { clip.notes.indices.contains($0) }.sorted()
    }

    /// Drops indices an undo or another edit left without a note.
    func validateSelection() {
        let count = clip?.notes.count ?? 0
        let valid = selection.filter { $0 < count }
        if valid != selection {
            selection = valid
        }
    }

    // MARK: Grid

    /// Ticks of one grid step.
    public var gridTicks: Int {
        let straight = MIDITiming.ticksPerBeat * 4 / max(1, gridDivision)
        return isTripletGrid ? straight * 2 / 3 : straight
    }

    /// `tick` on the grid while snapping is on.
    public func snapped(_ tick: Int) -> Int {
        guard project?.snapToGrid ?? true else { return max(0, tick) }
        let step = gridTicks
        return max(0, Int((Double(tick) / Double(step)).rounded()) * step)
    }

    /// The grid step at or before `tick` while snapping is on.
    public func snappedDown(_ tick: Int) -> Int {
        guard project?.snapToGrid ?? true else { return max(0, tick) }
        let step = gridTicks
        return max(0, Int(floor(Double(tick) / Double(step))) * step)
    }

    // MARK: Edits

    /// Starts an undoable edit (a gesture or a command).
    public func beginEdit() {
        project?.beginClipEdit()
        if let clip, editStartState == nil {
            editStartState = (clip.notes, clip.events, clip.startTick, clip.lengthTicks, clip.contentOffsetTicks)
        }
    }

    /// Ends the edit: the clip grows to hold its notes, and playback follows
    /// (not after a click that changed nothing, which would cut the notes
    /// sounding while playing).
    public func endEdit() {
        let before = editStartState
        editStartState = nil
        if let clip {
            // Only notes this edit added or changed widen the clip: notes a
            // trim hides stay hidden.
            var unchanged = Dictionary(grouping: before?.notes ?? [], by: { $0 }).mapValues(\.count)
            let edited = clip.notes.filter { note in
                if let count = unchanged[note], count > 0 {
                    unchanged[note] = count - 1
                    return false
                }
                return true
            }
            fit(clip, toHold: edited)
        }
        project?.endClipEdit()
        if let project, let clip, let before,
           before.notes != clip.notes || before.events != clip.events || before.start != clip.startTick
            || before.length != clip.lengthTicks || before.offset != clip.contentOffsetTicks {
            project.audioEngine.syncAfterClipEdit(project.tracks, fxChannels: project.fxChannels)
        }
        validateSelection()
    }

    /// Widens the clip (to the bar) so `notes` lie inside it, keeping the
    /// notes where they are.
    private func fit(_ clip: MIDIClip, toHold notes: [MIDINote]) {
        guard !notes.isEmpty else { return }
        let ticksPerBar = (project?.audioEngine.meter ?? .common).ticksPerBar
        let first = notes.map { clip.timelineTick(ofContentTick: $0.startTick) }.min() ?? clip.startTick
        let last = notes.map { clip.timelineTick(ofContentTick: $0.endTick) }.max() ?? clip.endTick
        if first < clip.startTick {
            let start = max(0, first / ticksPerBar * ticksPerBar)
            let delta = clip.startTick - start
            clip.startTick = start
            clip.contentOffsetTicks -= delta
            clip.lengthTicks += delta
        }
        if last > clip.endTick {
            clip.lengthTicks = (last + ticksPerBar - 1) / ticksPerBar * ticksPerBar - clip.startTick
        }
    }

    /// Adds a note at timeline `tick`; returns its index.
    @discardableResult
    public func addNote(atTimelineTick tick: Int, pitch: Int, lengthTicks: Int, velocity: Int? = nil) -> Int? {
        guard let clip else { return nil }
        let note = MIDINote(
            startTick: tick - clip.startTick + clip.contentOffsetTicks,
            lengthTicks: lengthTicks,
            pitch: UInt8(clamping: pitch),
            velocity: UInt8(clamping: velocity ?? defaultVelocity)
        )
        clip.notes.append(note)
        return clip.notes.count - 1
    }

    /// Removes notes, keeping the selection on the notes that remain.
    public func deleteNotes(_ indices: Set<Int>) {
        guard let clip, !indices.isEmpty else { return }
        let remaining = clip.notes.indices.filter { !indices.contains($0) }
        let newIndex = Dictionary(uniqueKeysWithValues: remaining.enumerated().map { ($1, $0) })
        clip.notes = remaining.map { clip.notes[$0] }
        selection = Set(selection.compactMap { newIndex[$0] })
    }

    /// Timeline tick where note `index` starts.
    public func timelineStart(of index: Int) -> Int? {
        guard let clip, clip.notes.indices.contains(index) else { return nil }
        return clip.timelineTick(ofContentTick: clip.notes[index].startTick)
    }

    public func deleteSelection() {
        guard !selection.isEmpty else { return }
        beginEdit()
        deleteNotes(selection)
        selection = []
        endEdit()
    }

    /// Moves the selected notes `semitones` up (down when negative); none
    /// goes past the keyboard's ends.
    public func transposeSelection(by semitones: Int) {
        guard let clip else { return }
        let targets = validSelection(in: clip)
        guard !targets.isEmpty else { return }
        let pitches = targets.map { Int(clip.notes[$0].pitch) }
        let low = pitches.min() ?? 0
        let high = pitches.max() ?? 127
        let shift = max(-low, min(127 - high, semitones))
        guard shift != 0 else { return }
        beginEdit()
        var notes = clip.notes
        for index in targets {
            notes[index].pitch = UInt8(Int(notes[index].pitch) + shift)
        }
        clip.notes = notes
        endEdit()
        if let top = targets.max(by: { notes[$0].pitch < notes[$1].pitch }) {
            audition(pitch: Int(notes[top].pitch), velocity: Int(notes[top].velocity))
        }
    }

    // MARK: Drum rows

    /// The kit's keys when there is a drum map for the track's instrument:
    /// the rows are then grouped by drum.
    var drumKit: [DrumMap.Drum]? {
        guard let instrument = track?.instrument else { return nil }
        return DrumMap.map(subtype: instrument.componentSubType,
                           manufacturer: instrument.componentManufacturer)?.drums
    }

    func makeDrumLayout() -> DrumRollLayout? {
        guard let drumKit else { return nil }
        let pitches = Set((clip?.notes ?? []).map { Int($0.pitch) })
        return DrumRollLayout(drums: drumKit, folded: foldedDrums,
                              otherPitches: DrumRollLayout.otherPitches(of: pitches, drums: drumKit),
                              otherName: String(localized: "Other"),
                              noteName: PianoRollCanvas.noteName)
    }

    public func toggleDrumFolded(_ id: String) {
        if foldedDrums.remove(id) == nil {
            foldedDrums.insert(id)
        }
    }

    /// Moves each selected note to the next way of striking its drum
    /// (`step` -1: the row above). At the drum's end it stays, or with
    /// `crossesDrums` goes on to the next drum. Returns the pitch of the first
    /// note moved.
    @discardableResult
    func moveSelectionToVariation(step: Int, crossesDrums: Bool = false) -> Int? {
        guard let clip, !selection.isEmpty, let layout = makeDrumLayout() else { return nil }
        var notes = clip.notes
        var first: (pitch: Int, velocity: Int)?
        for index in selection.sorted() where notes.indices.contains(index) {
            guard let pitch = layout.variation(from: Int(notes[index].pitch), step: step, crossesDrums: crossesDrums) else { continue }
            notes[index].pitch = UInt8(pitch)
            if first == nil { first = (pitch, Int(notes[index].velocity)) }
        }
        guard let first else { return nil }
        beginEdit()
        clip.notes = notes
        endEdit()
        audition(pitch: first.pitch, velocity: first.velocity)
        return first.pitch
    }

    // MARK: Adjustments (inspector)

    /// Settings of the inspector's Adjust section.
    @Published public var fixedLengthDivision: Int = 16
    @Published public var fixedLengthIsTriplet = false
    @Published public var fixedVelocity: Int = 100
    @Published public var velocityScalePercent: Int = 100
    @Published public var velocityOffset: Int = 0
    @Published public var transposeSemitones: Int = 0

    /// Changes the selected notes in one undo step.
    private func adjustSelection(_ change: (inout [MIDINote], [Int]) -> Void) {
        guard let clip, !selection.isEmpty else { return }
        beginEdit()
        var notes = clip.notes
        change(&notes, selection.filter { notes.indices.contains($0) }.sorted())
        clip.notes = notes
        endEdit()
    }

    /// Every selected note gets the fixed length (its start stays).
    public func applyFixedLength() {
        let straight = MIDITiming.ticksPerBeat * 4 / max(1, fixedLengthDivision)
        let length = fixedLengthIsTriplet ? straight * 2 / 3 : straight
        adjustSelection { notes, targets in
            for index in targets { notes[index].lengthTicks = length }
        }
    }

    /// Among the selected notes, a note overlapping the next one of the
    /// same pitch ends where that one starts (see `MIDINote.overlapFixes`).
    public func removeOverlaps() {
        guard let clip, !selection.isEmpty else { return }
        beginEdit()
        removeOverlaps(in: clip)
        endEdit()
    }

    /// The overlap removal itself (inside an edit already begun).
    private func removeOverlaps(in clip: MIDIClip) {
        let targets = selection.filter { clip.notes.indices.contains($0) }.sorted()
        let fixes = MIDINote.overlapFixes(targets.map { clip.notes[$0] })
        guard !fixes.lengths.isEmpty || !fixes.removed.isEmpty else { return }
        var notes = clip.notes
        for (position, length) in fixes.lengths {
            notes[targets[position]].lengthTicks = length
        }
        clip.notes = notes
        deleteNotes(Set(fixes.removed.map { targets[$0] }))
    }

    // MARK: Swing

    /// Swing ranges: velocity in velocity steps, start in 1/128 of a 4/4 bar.
    @Published public var swingVelocityDown: Int = 10
    @Published public var swingVelocityUp: Int = 10
    @Published public var swingStartEarlier: Int = 10
    @Published public var swingStartLater: Int = 10
    /// Ticks in one swing step: a note length, the same in every meter.
    public static var swingStepTicks: Int { MusicalMeter.common.ticksPerBar / 128 }

    /// Moves each selected note's start and changes its velocity by random
    /// amounts within the swing ranges (its length stays), then removes the
    /// overlaps this made; one undo step. A note stays inside the clip as it
    /// is: a shift that would take its start or end past an edge stops at
    /// the edge (a note already past one is not moved further out).
    public func applySwing() {
        guard let clip, !selection.isEmpty else { return }
        beginEdit()
        var notes = clip.notes
        let step = Self.swingStepTicks
        let clipStart = clip.contentOffsetTicks
        let clipEnd = clip.contentOffsetTicks + clip.lengthTicks
        for index in selection where notes.indices.contains(index) {
            let note = notes[index]
            let random = Int.random(in: -(swingStartEarlier * step)...(swingStartLater * step))
            let earliestShift = min(0, clipStart - note.startTick)
            let latestShift = max(0, clipEnd - note.endTick)
            let shift = max(earliestShift, min(latestShift, random))
            notes[index].startTick = note.startTick + shift
            let velocity = Int(notes[index].velocity) + Int.random(in: -swingVelocityDown...swingVelocityUp)
            notes[index].velocity = UInt8(max(1, min(127, velocity)))
        }
        clip.notes = notes
        removeOverlaps(in: clip)
        endEdit()
    }

    private static func clampedVelocity(_ value: Double) -> UInt8 {
        UInt8(max(1, min(127, Int(value.rounded()))))
    }

    public func applyFixedVelocity() {
        adjustSelection { notes, targets in
            for index in targets { notes[index].velocity = Self.clampedVelocity(Double(fixedVelocity)) }
        }
    }

    public func applyVelocityScale() {
        adjustSelection { notes, targets in
            for index in targets {
                notes[index].velocity = Self.clampedVelocity(Double(notes[index].velocity) * Double(velocityScalePercent) / 100)
            }
        }
    }

    public func applyVelocityOffset() {
        adjustSelection { notes, targets in
            for index in targets {
                notes[index].velocity = Self.clampedVelocity(Double(Int(notes[index].velocity) + velocityOffset))
            }
        }
    }

    /// Mutes (or unmutes) the selected notes.
    public func setSelectionMuted(_ muted: Bool) {
        guard let clip, !selection.isEmpty else { return }
        beginEdit()
        var notes = clip.notes
        for index in selection where notes.indices.contains(index) {
            notes[index].isMuted = muted
        }
        clip.notes = notes
        endEdit()
    }

    public var selectionHasMutedNotes: Bool {
        guard let clip else { return false }
        return selection.contains { clip.notes.indices.contains($0) && clip.notes[$0].isMuted }
    }

    public var selectionHasUnmutedNotes: Bool {
        guard let clip else { return false }
        return selection.contains { clip.notes.indices.contains($0) && !clip.notes[$0].isMuted }
    }

    public var canPaste: Bool { !clipboard.isEmpty }

    /// Selects the notes inside the clip (those a trim hides are left out).
    public func selectAll() {
        guard let clip else { return }
        let visible = clip.contentOffsetTicks..<(clip.contentOffsetTicks + clip.lengthTicks)
        selection = Set(clip.notes.indices.filter { visible.contains(clip.notes[$0].startTick) })
    }

    // MARK: Clipboard

    public func copySelection() {
        guard let clip else { return }
        let notes = validSelection(in: clip).map { clip.notes[$0] }
        guard !notes.isEmpty else { return }
        let origin = notes.map { clip.timelineTick(ofContentTick: $0.startTick) }.min() ?? 0
        clipboard = notes.map { note in
            var copy = note
            copy.startTick = clip.timelineTick(ofContentTick: note.startTick) - origin
            return copy
        }
    }

    public func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Pastes at the playhead (on the grid); the pasted notes are selected.
    public func paste() {
        guard let clip, let project, !clipboard.isEmpty else { return }
        let origin = snappedDown(MIDITiming.ticks(seconds: project.audioEngine.currentTime, bpm: project.audioEngine.bpm))
        beginEdit()
        var added: Set<Int> = []
        for note in clipboard {
            var copy = note
            copy.startTick = origin + note.startTick - clip.startTick + clip.contentOffsetTicks
            clip.notes.append(copy)
            added.insert(clip.notes.count - 1)
        }
        selection = added
        endEdit()
    }

    /// Edit keys while the piano roll has the keyboard; false leaves the
    /// command to the arranger.
    public func handle(cut: Bool = false, copy: Bool = false, paste: Bool = false,
                       selectAll: Bool = false, clear: Bool = false) -> Bool {
        guard hasKeyFocus, clip != nil else { return false }
        if cut { cutSelection() }
        if copy { copySelection() }
        if paste { self.paste() }
        if selectAll { self.selectAll() }
        if clear { selection = [] }
        return true
    }

    // MARK: Audition

    /// Plays `pitch` briefly on the track's instrument.
    public func audition(pitch: Int, velocity: Int) {
        guard auditionsNotes else { return }
        startAudition(pitch: pitch, velocity: velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.stopAudition(pitch: pitch)
        }
    }

    /// Holds `pitch` until `stopAudition` (the keyboard, which always sounds).
    public func startAudition(pitch: Int, velocity: Int) {
        guard let trackID, let engine = project?.audioEngine else { return }
        let key = UInt8(clamping: pitch)
        if heldAuditions.contains(key) {
            engine.sendLiveMIDI(to: trackID, status: 0x80, data1: key, data2: 0)
        }
        heldAuditions.insert(key)
        engine.sendLiveMIDI(to: trackID, status: 0x90, data1: key, data2: UInt8(clamping: max(1, velocity)))
    }

    public func stopAudition(pitch: Int) {
        let key = UInt8(clamping: pitch)
        guard heldAuditions.remove(key) != nil, let trackID, let engine = project?.audioEngine else { return }
        engine.sendLiveMIDI(to: trackID, status: 0x80, data1: key, data2: 0)
    }
}

/// The controller lanes: which events each shows and how their values map.
extension PianoRollController.Lane {
    public var title: String {
        switch self {
        case .velocity: return String(localized: "Velocity")
        case .pitchBend: return String(localized: "Pitch Bend")
        case .modulation: return String(localized: "Modulation")
        case .aftertouch: return String(localized: "Aftertouch")
        }
    }

    /// Highest value: 14 bits for pitch bend, 7 for the others.
    public var maximum: Int { self == .pitchBend ? 16383 : 127 }

    /// Where the graph starts before the first event (bend centred).
    public var restingValue: Int { self == .pitchBend ? 8192 : 0 }

    /// True for the events this lane shows: pitch bend, CC1 (modulation
    /// wheel) and channel pressure. Never for velocity, which is the notes'.
    public func shows(_ event: MIDIChannelEvent) -> Bool {
        switch self {
        case .velocity: return false
        case .pitchBend: return event.kind == 0xE0
        case .modulation: return event.kind == 0xB0 && event.data1 == 1
        case .aftertouch: return event.kind == 0xD0
        }
    }

    public func value(of event: MIDIChannelEvent) -> Int {
        switch self {
        case .velocity: return 0
        case .pitchBend: return Int(event.data2) << 7 | Int(event.data1)
        case .modulation: return Int(event.data2)
        case .aftertouch: return Int(event.data1)
        }
    }

    public func event(tick: Int, value: Int, channel: UInt8) -> MIDIChannelEvent? {
        let value = max(0, min(maximum, value))
        let channel = channel & 0x0F
        switch self {
        case .velocity:
            return nil
        case .pitchBend:
            return MIDIChannelEvent(tick: tick, status: 0xE0 | channel, data1: UInt8(value & 0x7F), data2: UInt8(value >> 7))
        case .modulation:
            return MIDIChannelEvent(tick: tick, status: 0xB0 | channel, data1: 1, data2: UInt8(value))
        case .aftertouch:
            return MIDIChannelEvent(tick: tick, status: 0xD0 | channel, data1: UInt8(value))
        }
    }
}
