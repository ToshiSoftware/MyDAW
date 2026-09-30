import SwiftUI

private struct TimelineScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0.0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

public struct ArrangerView: View {
    @ObservedObject public var projectState: ProjectState
    @ObservedObject public var audioEngine: AudioEngineManager

    // Dynamic timeline width (minimum 2500 pt, extends with zoom & duration).
    // It always reaches a screen past the playhead, where auto-scroll puts
    // the view: the ruler is offset by `timelineScrollTime` while the tracks
    // scroll for real, and a scroll clamped at the content's end would leave
    // the ruler (flags, playhead ball) drawn ahead of the tracks.
    private func timelineWidth(viewportWidth: CGFloat) -> CGFloat {
        let clipEndTime = projectState.tracks
            .flatMap { $0.clips }
            .map { $0.startTime + $0.duration }
            .max() ?? 0.0
        let pixelsPerSecond = max(0.001, projectState.pixelsPerSecond)
        let visibleDuration = Double(max(1.0, viewportWidth - 230.0) / pixelsPerSecond)
        let maxDuration = max(
            60.0,
            audioEngine.currentTime + 30.0,
            clipEndTime + 5.0,
            (projectState.songEndTime ?? 0.0) + 5.0,
            audioEngine.currentTime + visibleDuration + 5.0
        )
        return max(2500.0, CGFloat(maxDuration) * pixelsPerSecond)
    }

    public init(projectState: ProjectState, audioEngine: AudioEngineManager) {
        self.projectState = projectState
        self.audioEngine = audioEngine
    }

    // Waveform drawn inside the drag preview so the clip content stays visible while moving
    @ViewBuilder
    private func clipDragPreviewWaveform(clip: AudioClip, isStereo: Bool, color: Color) -> some View {
        let verticalScale = projectState.waveformVerticalScale * CGFloat(pow(10.0, clip.gainDB / 20.0))
        let layerSpans = projectState.tracks.first(where: { $0.clips.contains { $0.id == clip.id } })
            .map { ClipLayering.spans(for: $0.clips) } ?? []
        let channels: [Int?] = isStereo ? [0, 1] : [nil]
        VStack(spacing: 1) {
            ForEach(channels.indices, id: \.self) { index in
                WaveformCanvas(
                    waveformCache: clip.waveformCache,
                    trackColor: color,
                    sampleRate: clip.sampleRate,
                    pixelsPerSecond: projectState.pixelsPerSecond,
                    sampleOffset: clip.sourceStartTime,
                    visibleDuration: clip.duration,
                    channelIndex: channels[index],
                    verticalScale: verticalScale,
                    envelope: ClipLayering.envelope(layerSpans, clip: clip.id)
                )
            }
        }
        .overlay {
            FadeLinesOverlay(
                fadeInWidth: CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond,
                fadeOutWidth: CGFloat(clip.fadeOutDuration) * projectState.pixelsPerSecond,
                fadeInCurve: ClipLayering.resolvedCurve(layerSpans, clip: clip.id, atStart: true),
                fadeOutCurve: ClipLayering.resolvedCurve(layerSpans, clip: clip.id, atStart: false)
            )
        }
    }

    /// Trackpad pinch zooms the timeline horizontally around the pointer.
    /// `location` is in the arranger's coordinates (x from its left edge).
    private func handleMagnify(_ event: NSEvent, at location: CGPoint) -> Bool {
        let anchorOffset = max(0.0, location.x - 230.0)
        projectState.setPixelsPerSecond(
            projectState.pixelsPerSecond * (1.0 + event.magnification),
            anchorOffset: anchorOffset
        )
        return true
    }

    /// Plain wheel over the ruler zooms the timeline horizontally around the
    /// pointer; Option + wheel changes the track height; Option + Shift + wheel
    /// changes the waveform vertical scale. `location` is in the arranger's
    /// coordinates, measured from its top-left corner. Returns true when the
    /// event was consumed.
    private func handleWheel(_ event: NSEvent, at location: CGPoint) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            let isOverRuler = location.y < 32.0 && location.x >= 230.0
            guard isOverRuler else { return false }
            var delta = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                delta /= 10.0
            }
            // Leave horizontal swipes alone.
            guard delta != 0 else { return false }
            projectState.setPixelsPerSecond(
                projectState.pixelsPerSecond * pow(1.1, delta),
                anchorOffset: location.x - 230.0
            )
            return true
        }
        guard modifiers == [.option] || modifiers == [.option, .shift] else { return false }
        // macOS turns Shift + vertical wheel into horizontal scrolling.
        var delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX
        if event.hasPreciseScrollingDeltas {
            delta /= 10.0
        }
        guard delta != 0 else { return true }

        if modifiers == [.option] {
            projectState.trackHeightScale += delta * 0.1
        } else {
            projectState.waveformVerticalScale *= pow(1.1, delta)
        }
        return true
    }

    /// Shaded band over each track in the time selection.
    private func timeSelectionHighlight(_ selection: TimeSelection) -> some View {
        let x = CGFloat(selection.start) * projectState.pixelsPerSecond
        let width = max(1.0, CGFloat(selection.end - selection.start) * projectState.pixelsPerSecond)
        let selectedTracks = projectState.tracks.filter { selection.trackIDs.contains($0.id) }
        return ZStack(alignment: .topLeading) {
            ForEach(selectedTracks) { track in
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        Rectangle()
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    )
                    .frame(
                        width: width,
                        height: TrackHeaderView.rowHeight(for: track) * projectState.trackHeightScale
                    )
                    .offset(x: x, y: projectState.trackTopY(for: track.id))
            }
        }
        .allowsHitTesting(false)
    }

    public var body: some View {
        GeometryReader { viewport in
            let timelineWidth = timelineWidth(viewportWidth: viewport.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack {
                        Text("TRACKS (\(projectState.tracks.count))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Button(action: { projectState.addTrack() }) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 22, height: 20)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(4)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Add Track")
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 230, height: 32)
                    .background(Color(red: 0.15, green: 0.16, blue: 0.18))
                    .zIndex(1)

                    TimelineRulerView(
                        audioEngine: audioEngine,
                        projectState: projectState,
                        width: timelineWidth
                    )
                    .offset(x: -CGFloat(projectState.timelineScrollTime) * projectState.pixelsPerSecond)
                    .frame(width: max(0, viewport.size.width - 230), height: 32, alignment: .leading)
                    .clipped()
                }

                ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        VStack(spacing: 1) {
                            ForEach(projectState.tracks) { track in
                                TrackHeaderView(
                                    track: track,
                                    projectState: projectState,
                                    isSelected: projectState.selectedTrackId == track.id,
                                    isRecording: audioEngine.isRecording
                                )
                                .frame(
                                    width: 230,
                                    height: TrackHeaderView.rowHeight(for: track) * projectState.trackHeightScale,
                                    alignment: .top
                                )
                                .clipped()
                            }
                        }
                        .frame(width: 230, alignment: .top)
                    }
                    .frame(width: 230, alignment: .top)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.15))

                    ScrollViewReader { horizontalProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        ForEach(projectState.tracks) { track in
                                            WaveformLaneView(
                                                track: track,
                                                projectState: projectState,
                                                timelineWidth: timelineWidth
                                            )
                                        }
                                    }

                                    if let selection = projectState.timeSelection {
                                        timeSelectionHighlight(selection)
                                    }

                                    if let marquee = projectState.marqueeRect {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.08))
                                            .overlay(
                                                Rectangle()
                                                    .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                            )
                                            .frame(width: marquee.width, height: marquee.height)
                                            .offset(x: marquee.minX, y: marquee.minY)
                                            .allowsHitTesting(false)
                                    }

                                    if let preview = projectState.clipDragPreview {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(preview.color.opacity(0.18))
                                            .frame(width: preview.width, height: preview.height)
                                            .overlay {
                                                if let clip = preview.clip {
                                                    clipDragPreviewWaveform(clip: clip, isStereo: preview.isStereo, color: preview.color)
                                                        .opacity(clip.isMuted ? 0.35 : 0.85)
                                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                                }
                                            }
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(
                                                        preview.color.opacity(0.95),
                                                        style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                                                    )
                                            )
                                            .position(
                                                x: CGFloat(preview.startTime) * projectState.pixelsPerSecond + preview.width / 2.0,
                                                y: preview.topY + preview.height / 2.0
                                            )
                                            .allowsHitTesting(false)
                                    }

                                    let playheadX = CGFloat(audioEngine.currentTime) * projectState.pixelsPerSecond
                                    let totalHeight = projectState.tracks.reduce(CGFloat.zero) { height, track in
                                        height + TrackHeaderView.rowHeight(for: track) * projectState.trackHeightScale
                                    } + CGFloat(max(0, projectState.tracks.count - 1))

                                    HStack(spacing: 0) {
                                        Color.clear
                                            .frame(width: max(0.0, CGFloat(projectState.timelineScrollTime) * projectState.pixelsPerSecond), height: 1)
                                        Color.clear
                                            .frame(width: 1, height: 1)
                                            .id("savedScrollPosition-\(projectState.scrollRestoreRevision)")
                                    }

                                    HStack(spacing: 0) {
                                        Color.clear
                                            .frame(width: max(0, playheadX), height: 1)
                                        Color.clear
                                            .frame(width: 1, height: 1)
                                            .id("playhead")
                                    }
                                    .frame(maxWidth: timelineWidth, alignment: .leading)

                                    // The ball on top of this line is drawn in the ruler.
                                    Rectangle()
                                        .fill(PlayheadBall.color(for: audioEngine))
                                        .frame(width: 2, height: max(300, totalHeight))
                                        .offset(x: playheadX - 1)
                                        .allowsHitTesting(false)
                                }
                                .background(
                                    GeometryReader { content in
                                        Color.clear.preference(
                                            key: TimelineScrollOffsetKey.self,
                                            value: -content.frame(in: .named("timelineScroll")).minX
                                        )
                                    }
                                )
                                .onPreferenceChange(TimelineScrollOffsetKey.self) { offset in
                                    guard !projectState.isRestoringScrollPosition else { return }
                                    projectState.timelineScrollTime = max(
                                        0.0,
                                        Double(offset / projectState.pixelsPerSecond)
                                    )
                                }
                                .onChange(of: projectState.timelineScrollTime) { _ in
                                    withAnimation(nil) {
                                        horizontalProxy.scrollTo(
                                            "savedScrollPosition-\(projectState.scrollRestoreRevision)",
                                            anchor: .leading
                                        )
                                    }
                                }
                                .onChange(of: audioEngine.currentTime) { _ in
                                    guard audioEngine.isPlaying || audioEngine.isRecording else { return }
                                    let visibleWidth = max(1.0, viewport.size.width - 230.0)
                                    let visibleDuration = max(
                                        1.0,
                                        Double(visibleWidth) / Double(projectState.pixelsPerSecond)
                                    )
                                    let rightMarginTime = visibleDuration * 0.1
                                    let scrollTriggerTime = projectState.timelineScrollTime + visibleDuration - rightMarginTime
                                    if audioEngine.currentTime >= scrollTriggerTime {
                                        // Keep the ruler, waveform, and bottom
                                        // scrollbar driven by the same offset.
                                        projectState.timelineScrollTime = max(
                                            0.0,
                                            audioEngine.currentTime - rightMarginTime
                                        )
                                        withAnimation(nil) {
                                            horizontalProxy.scrollTo(
                                                "savedScrollPosition-\(projectState.scrollRestoreRevision)",
                                                anchor: .leading
                                            )
                                        }
                                    }
                                }
                                .onChange(of: projectState.scrollRestoreRevision) { _ in
                                    Task { @MainActor in
                                        await Task.yield()
                                        withAnimation(nil) {
                                            horizontalProxy.scrollTo(
                                                "savedScrollPosition-\(projectState.scrollRestoreRevision)",
                                                anchor: .leading
                                            )
                                        }
                                        await Task.yield()
                                        projectState.isRestoringScrollPosition = false
                                    }
                                }
                                .onAppear {
                                    Task { @MainActor in
                                        withAnimation(nil) {
                                            horizontalProxy.scrollTo(
                                                projectState.timelineScrollTime > 0.0
                                                    ? "savedScrollPosition-\(projectState.scrollRestoreRevision)"
                                                    : "playhead",
                                                anchor: .leading
                                            )
                                        }
                                    }
                                }
                                .coordinateSpace(name: "timelineScroll")
                            }
                            .frame(width: max(timelineWidth, viewport.size.width - 230), alignment: .leading)
                        }
                        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(red: 0.08, green: 0.09, blue: 0.11))
            .onDeleteCommand {
                projectState.deleteSelectedClip()
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Slider(
                    value: $projectState.timelineScrollTime,
                    in: 0.0...max(
                        0.0,
                        Double(timelineWidth / projectState.pixelsPerSecond)
                            - Double(max(1.0, (viewport.size.width - 230.0) / projectState.pixelsPerSecond))
                    )
                )
                .accentColor(.cyan)
            }
            .padding(.leading, 230)
            .padding(.trailing, 10)
            .frame(height: 20)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15))

                }
                // Covers the ruler row as well as the tracks, so the ruler
                // wheel zoom can see events there.
                .background(ArrangerWheelMonitor(onWheel: handleWheel, onMagnify: handleMagnify))
            }
        }
    }

/// Background, ticks and labels of the ruler. Its own view so that pointer
/// tracking in the ruler (for the flag menu) does not redraw it.
private struct RulerTicks: View {
    @ObservedObject var audioEngine: AudioEngineManager
    @ObservedObject var projectState: ProjectState

    var body: some View {
            Canvas { context, size in
            let pps = projectState.pixelsPerSecond

            // Background
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.14, green: 0.15, blue: 0.17)))

            // Bottom border
            var border = Path()
            border.move(to: CGPoint(x: 0, y: size.height))
            border.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(border, with: .color(Color.white.opacity(0.1)), lineWidth: 1)

            let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
            let interval = projectState.showsBeats ? beatDuration : (pps > 120 ? 1.0 : (pps > 40 ? 5.0 : 10.0))

            var time: Double = 0.0
            var markerIndex = 0
            while (time * Double(pps)) < size.width {
                let x = CGFloat(time * Double(pps))
                let isBarStart = projectState.showsBeats && markerIndex % 4 == 0

                if isBarStart {
                    let barWidth = CGFloat(beatDuration * 4.0 * Double(pps))
                    let barRect = CGRect(x: x, y: 0, width: barWidth, height: size.height)
                    context.fill(
                        Path(barRect),
                        with: .color(Color.orange.opacity((markerIndex / 4) % 2 == 0 ? 0.055 : 0.025))
                    )
                }

                // Major tick
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: isBarStart ? size.height - 20 : size.height - 10))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    tick,
                    with: .color(isBarStart ? Color.orange.opacity(0.95) : Color.white.opacity(0.35)),
                    lineWidth: isBarStart ? 2 : 1
                )

                // Time label: mm:ss
                let timeStr: String
                if projectState.showsBeats {
                    let bar = markerIndex / 4 + 1
                    let beat = markerIndex % 4 + 1
                    timeStr = isBarStart ? "\(bar)" : "\(beat)"
                } else {
                    let minutes = Int(time) / 60
                    let seconds = Int(time) % 60
                    timeStr = String(format: "%02d:%02d", minutes, seconds)
                }
                let text = Text(timeStr)
                    .font(.system(size: isBarStart ? 12 : 8, weight: isBarStart ? .black : .bold))
                    .foregroundColor(isBarStart ? Color.orange : Color.white.opacity(0.6))
                context.draw(context.resolve(text), at: CGPoint(x: x + 16, y: 22))

                time += interval
                markerIndex += 1
            }
            }
    }
}

// MARK: - Timeline Ruler View
struct TimelineRulerView: View {
    @ObservedObject var audioEngine: AudioEngineManager
    @ObservedObject var projectState: ProjectState
    let width: CGFloat
    @StateObject private var optionKey = OptionKeyMonitor()
    /// Last pointer x over the ruler, where the context menu places a flag.
    @State private var hoverX: CGFloat = 0.0
    /// Position of the last seek in the current ruler drag.
    @State private var seekTarget: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RulerTicks(audioEngine: audioEngine, projectState: projectState)

            // Under the punch handles, which win where the two overlap
            // (⌥ lets the drag through to a flag).
            SongRangeOverlay(
                audioEngine: audioEngine,
                projectState: projectState,
                width: width
            )

            PunchRangeOverlay(
                audioEngine: audioEngine,
                projectState: projectState,
                width: width
            )
            .allowsHitTesting(!optionKey.isDown)

            PlayheadBall(audioEngine: audioEngine, pixelsPerSecond: projectState.pixelsPerSecond)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: 32)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                hoverX = location.x
            }
        }
        .contextMenu {
            let time = projectState.snappedTimelineTime(Double(hoverX / max(0.001, projectState.pixelsPerSecond)))
            Button("Set Song Start Here") { projectState.setSongStart(time: time) }
                .disabled(!projectState.canPlaceSongStart(at: time))
            Button("Set Song End Here") { projectState.setSongEnd(time: time) }
                .disabled(!projectState.canPlaceSongEnd(at: time))
            if projectState.songRange.startBeat != nil || projectState.songRange.endBeat != nil {
                Divider()
            }
            if projectState.songRange.startBeat != nil {
                Button("Remove Song Start") { projectState.setSongStart(time: nil) }
            }
            if projectState.songRange.endBeat != nil {
                Button("Remove Song End") { projectState.setSongEnd(time: nil) }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let clickX = max(0, value.location.x)
                    let targetTime = projectState.snappedTimelineTime(Double(clickX / projectState.pixelsPerSecond))
                    // Within one drag, seek (and so restart playback) only
                    // when the snapped position changes.
                    guard targetTime != seekTarget else { return }
                    seekTarget = targetTime
                    audioEngine.seek(
                        to: targetTime,
                        tracks: projectState.tracks,
                        fxChannels: projectState.fxChannels
                    )
                }
                .onEnded { _ in
                    seekTarget = nil
                }
        )
    }
}

private struct PunchRangeOverlay: View {
    @ObservedObject var audioEngine: AudioEngineManager
    @ObservedObject var projectState: ProjectState
    let width: CGFloat
    @State private var dragStartTime: Double?

    var body: some View {
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        let pixelsPerSecond = max(0.001, projectState.pixelsPerSecond)
        let startX = CGFloat(projectState.punchRange.startBeat * beatDuration) * pixelsPerSecond
        let endX = CGFloat(projectState.punchRange.endBeat * beatDuration) * pixelsPerSecond

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(projectState.punchRange.enabled ? Color.red.opacity(0.38) : Color.gray.opacity(0.08))
                .frame(width: max(1.0, endX - startX), height: 10)
                .offset(x: startX, y: 0)
                .allowsHitTesting(false)

            Text("PUNCH")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(projectState.punchRange.enabled ? 0.95 : 0.5))
                .offset(x: startX + 4, y: 1)
                .allowsHitTesting(false)

            punchHandle(
                x: startX,
                initialTime: projectState.punchRange.startBeat * beatDuration,
                pixelsPerSecond: pixelsPerSecond,
                isStartHandle: true,
                beatDuration: beatDuration
            )
            punchHandle(
                x: endX,
                initialTime: projectState.punchRange.endBeat * beatDuration,
                pixelsPerSecond: pixelsPerSecond,
                isStartHandle: false,
                beatDuration: beatDuration
            )
        }
        .frame(width: width, height: 32, alignment: .topLeading)
    }

    private func punchHandle(
        x: CGFloat,
        initialTime: Double,
        pixelsPerSecond: CGFloat,
        isStartHandle: Bool,
        beatDuration: Double
    ) -> some View {
        Capsule()
            .fill(projectState.punchRange.enabled ? Color.red : Color.gray)
            .frame(width: 10, height: 14)
            .overlay(Circle().fill(Color.white).frame(width: 4, height: 4))
            .frame(width: 24, height: 32)
            .contentShape(Rectangle())
            .position(x: min(max(12.0, x), max(12.0, width - 12.0)), y: 6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartTime == nil {
                            dragStartTime = initialTime
                        }
                        let rawTime = max(
                            0.0,
                            (dragStartTime ?? initialTime) + Double(value.translation.width) / Double(pixelsPerSecond)
                        )
                        let snappedBeat = projectState.snappedTimelineTime(rawTime) / beatDuration
                        if isStartHandle {
                            projectState.setPunchStartBeat(
                                min(snappedBeat, projectState.punchRange.endBeat - 1.0)
                            )
                        } else {
                            projectState.setPunchEndBeat(
                                max(snappedBeat, projectState.punchRange.startBeat + 1.0)
                            )
                        }
                    }
                    .onEnded { _ in
                        dragStartTime = nil
                    }
            )
    }
}

/// Song start / end flags on the ruler. Dragging moves a flag with the grid
/// snap and shows its position in the ruler's current units.
private struct SongRangeOverlay: View {
    @ObservedObject var audioEngine: AudioEngineManager
    @ObservedObject var projectState: ProjectState
    let width: CGFloat
    @State private var dragStartTime: Double?
    @State private var draggedFlag: Flag?

    enum Flag {
        case start, end

        // Both flags share one colour; the pennant's direction tells them apart.
        var color: Color { Color(red: 0.35, green: 0.65, blue: 1.00) }
    }

    var body: some View {
        let pixelsPerSecond = max(0.001, projectState.pixelsPerSecond)
        ZStack(alignment: .topLeading) {
            if let start = projectState.songStartTime {
                flag(.start, time: start, pixelsPerSecond: pixelsPerSecond)
            }
            if let end = projectState.songEndTime {
                flag(.end, time: end, pixelsPerSecond: pixelsPerSecond)
            }
        }
        .frame(width: width, height: 32, alignment: .topLeading)
    }

    private func flag(_ flag: Flag, time: Double, pixelsPerSecond: CGFloat) -> some View {
        let x = CGFloat(time) * pixelsPerSecond
        return ZStack(alignment: .topLeading) {
            FlagShape(pointsRight: flag == .start)
                .fill(flag.color)
                .frame(width: 22, height: 32)
                .allowsHitTesting(false)
            if draggedFlag == flag {
                Text(positionText(time))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(3)
                    .fixedSize()
                    // Beside the pole, on the pennant's side.
                    .frame(width: 160, alignment: flag == .start ? .leading : .trailing)
                    .offset(x: flag == .start ? 14 : 8 - 160, y: 15)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 22, height: 32, alignment: .topLeading)
        // Only the pennant grabs the flag; the pole and the rest of the
        // ruler move the playhead.
        .contentShape(PennantHitShape(pointsRight: flag == .start))
        .offset(x: x - 11, y: 0)
        .help(flag == .start ? "Song start" : "Song end")
        // High priority, so grabbing a flag never also moves the playhead
        // through the ruler's own drag.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartTime == nil {
                        dragStartTime = time
                        // Shows the position tooltip from the moment of the press.
                        draggedFlag = flag
                    }
                    // A press alone leaves the flag where it is, even off the grid.
                    guard value.translation.width != 0 else { return }
                    let rawTime = (dragStartTime ?? time) + Double(value.translation.width / pixelsPerSecond)
                    let snapped = projectState.snappedTimelineTime(rawTime)
                    switch flag {
                    case .start: projectState.setSongStart(time: snapped)
                    case .end: projectState.setSongEnd(time: snapped)
                    }
                }
                .onEnded { _ in
                    dragStartTime = nil
                    draggedFlag = nil
                }
        )
    }

    /// Bar:beat:tick (480 per beat) in beat mode, h:m:s.ms in time mode.
    private func positionText(_ time: Double) -> String {
        if projectState.showsBeats {
            let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
            let totalTicks = Int((max(0.0, time) / beatDuration * 480.0).rounded())
            let beats = totalTicks / 480
            return String(format: "%03d:%02d:%03d", beats / 4 + 1, beats % 4 + 1, totalTicks % 480)
        }
        let totalMilliseconds = Int((max(0.0, time) * 1000.0).rounded())
        let seconds = totalMilliseconds / 1000
        return String(
            format: "%02d:%02d:%02d.%03d",
            seconds / 3600, (seconds / 60) % 60, seconds % 60, totalMilliseconds % 1000
        )
    }
}

/// The playhead's head: a ball resting on the playhead line at the bottom of
/// the ruler. While the transport runs it bounces once per beat, touching
/// down on each beat; stopped, it rests wherever the playhead is.
private struct PlayheadBall: View {
    @ObservedObject var audioEngine: AudioEngineManager
    let pixelsPerSecond: CGFloat

    private static let diameter: CGFloat = 12
    private static let bounceHeight: CGFloat = 16

    /// Green while playing, red while actually recording (not while waiting
    /// for a punch-in), orange when stopped. Shared with the playhead line.
    static func color(for engine: AudioEngineManager) -> Color {
        if engine.isRecording { return .red }
        if engine.isPlaying { return .green }
        return .orange
    }

    var body: some View {
        let x = CGFloat(audioEngine.currentTime) * pixelsPerSecond
        let lift: CGFloat
        if audioEngine.isPlaying || audioEngine.isRecording {
            let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
            let phase = (max(0.0, audioEngine.currentTime) / beatDuration).truncatingRemainder(dividingBy: 1.0)
            lift = Self.bounceHeight * CGFloat(sin(Double.pi * phase))
        } else {
            lift = 0
        }
        return Circle()
            .fill(Self.color(for: audioEngine))
            .frame(width: Self.diameter, height: Self.diameter)
            .position(x: x, y: 32 - Self.diameter / 2 - lift)
    }
}

/// A pole down the middle of the ruler with a pennant at the top, pointing
/// into the song (right for the start flag, left for the end flag).
private struct FlagShape: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let poleX = rect.midX
        path.addRect(CGRect(x: poleX - 0.75, y: rect.minY, width: 1.5, height: rect.height))
        let tip = pointsRight ? poleX + 10 : poleX - 10
        path.move(to: CGPoint(x: poleX, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: tip, y: rect.minY + 6))
        path.addLine(to: CGPoint(x: poleX, y: rect.minY + 11))
        path.closeSubpath()
        return path
    }
}

/// The pennant of a `FlagShape` (with a little slack), where a flag can be grabbed.
private struct PennantHitShape: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        let width: CGFloat = 13
        let x = pointsRight ? rect.midX - 2 : rect.midX + 2 - width
        return Path(CGRect(x: x, y: rect.minY, width: width, height: 13))
    }
}

/// Publishes whether ⌥ is held, so the ruler can let a drag through the
/// punch handles to a song flag beneath them.
private final class OptionKeyMonitor: ObservableObject {
    @Published private(set) var isDown = false
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isDown = event.modifierFlags.contains(.option)
            if self?.isDown != isDown {
                self?.isDown = isDown
            }
            return event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

/// Watches scroll-wheel and trackpad pinch events that land inside the
/// arranger and hands them to `onWheel` / `onMagnify`; events they consume do
/// not reach the scroll views.
private struct ArrangerWheelMonitor: NSViewRepresentable {
    let onWheel: (NSEvent, CGPoint) -> Bool
    let onMagnify: (NSEvent, CGPoint) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onWheel: onWheel, onMagnify: onMagnify)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onWheel = onWheel
        context.coordinator.onMagnify = onMagnify
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onWheel: (NSEvent, CGPoint) -> Bool
        var onMagnify: (NSEvent, CGPoint) -> Bool
        weak var view: NSView?
        private var monitor: Any?

        init(onWheel: @escaping (NSEvent, CGPoint) -> Bool, onMagnify: @escaping (NSEvent, CGPoint) -> Bool) {
            self.onWheel = onWheel
            self.onMagnify = onMagnify
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self,
                      let view = self.view,
                      let window = view.window,
                      event.window === window else {
                    return event
                }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                // Hand the handlers a top-left origin, matching SwiftUI.
                let topLeftPoint = CGPoint(
                    x: point.x,
                    y: view.isFlipped ? point.y : view.bounds.height - point.y
                )
                let consumed = event.type == .magnify
                    ? self.onMagnify(event, topLeftPoint)
                    : self.onWheel(event, topLeftPoint)
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
