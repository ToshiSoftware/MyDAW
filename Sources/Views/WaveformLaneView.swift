import SwiftUI
import UniformTypeIdentifiers

public struct WaveformLaneView: View {
    @ObservedObject public var track: AudioTrack
    @ObservedObject public var projectState: ProjectState
    public let timelineWidth: CGFloat

    public init(track: AudioTrack, projectState: ProjectState, timelineWidth: CGFloat) {
        self.track = track
        self.projectState = projectState
        self.timelineWidth = timelineWidth
    }

    public var body: some View {
        let rowHeight = TrackHeaderView.rowHeight(for: track) * projectState.trackHeightScale
        ZStack(alignment: .leading) {
            // Background lane
            Rectangle()
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13))
                .frame(width: timelineWidth, height: rowHeight)

            // Grid Lines (every second or every 5 seconds depending on zoom)
            Canvas { context, size in
                let pps = projectState.pixelsPerSecond
                let stepSeconds: Double = pps > 60 ? 1.0 : 5.0
                let stepPixels = stepSeconds * Double(pps)

                var x = 0.0
                while x < size.width {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(Color.white.opacity(0.04)), lineWidth: 1)
                    x += stepPixels
                }
            }
            .frame(width: timelineWidth, height: rowHeight)

            // Each recording session is displayed as a separate timeline clip.
            if !track.clips.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(track.clips) { clip in
                        AudioClipView(
                            clip: clip,
                            track: track,
                            projectState: projectState,
                            height: rowHeight - 4
                        )
                    }
                }
                .frame(width: timelineWidth, height: rowHeight, alignment: .leading)
            } else {
                // Empty lane placeholder
                HStack {
                    Spacer()
                    if track.isRecordArmed {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("Ready to Record: Press Start / Spacebar")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    } else {
                        Text("No Audio Recorded - Click [R] to Arm for Recording")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.25))
                    }
                    Spacer()
                }
                .frame(width: timelineWidth, height: rowHeight)
            }
        }
        .frame(width: timelineWidth, height: rowHeight)
        // Clips have their own gestures; these fire only on empty lane space.
        .contentShape(Rectangle())
        .gesture(timeSelectionGesture)
        .onTapGesture {
            projectState.clearSelection()
        }
        .contextMenu {
            EditMenuItems(projectState: projectState)
        }
        .coordinateSpace(name: "timeline")
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                guard let url else { return }
                Task { @MainActor in
                    projectState.importAudioFile(url, intoTrackId: track.id)
                }
            }
            return true
        }
    }

    /// Dragging across empty lane space selects the clips it touches
    /// (Shift adds to the selection); Cmd-drag selects a time range instead.
    private var timeSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("timelineScroll"))
            .onChanged { value in
                let pps = projectState.pixelsPerSecond
                if projectState.timeSelectionAnchor == nil && projectState.marqueeRect == nil {
                    let modifiers = NSEvent.modifierFlags
                    if modifiers.contains(.command) {
                        projectState.beginTimeSelection(
                            atTime: Double(value.startLocation.x / pps),
                            timelineY: value.startLocation.y
                        )
                    } else {
                        projectState.beginMarquee(
                            at: value.startLocation,
                            additive: modifiers.contains(.shift)
                        )
                    }
                }
                if projectState.marqueeRect != nil {
                    projectState.updateMarquee(from: value.startLocation, to: value.location)
                } else {
                    projectState.updateTimeSelection(
                        toTime: Double(value.location.x / pps),
                        timelineY: value.location.y
                    )
                }
            }
            .onEnded { _ in
                projectState.endMarquee()
                projectState.endTimeSelection()
            }
    }
}

/// Clipboard and time-range commands shared by the clip and lane menus.
/// `prepare` runs before Cut/Copy (the clip menu uses it to select its clip,
/// so Cut/Copy stay enabled there even with nothing selected yet).
private struct EditMenuItems: View {
    @ObservedObject var projectState: ProjectState
    var prepare: (() -> Void)? = nil

    var body: some View {
        let isRecording = projectState.audioEngine.isRecording
        let canCopy = prepare != nil || projectState.hasSelection
        Button {
            prepare?()
            projectState.cutSelection()
        } label: {
            Label("Cut", systemImage: "scissors")
        }
        .disabled(isRecording || !canCopy)

        Button {
            prepare?()
            projectState.copySelection()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(!canCopy)

        Button {
            projectState.paste()
        } label: {
            Label("Paste at Playhead", systemImage: "doc.on.clipboard")
        }
        .disabled(isRecording || !projectState.canPaste)

        if projectState.timeSelection != nil {
            Divider()
            Button {
                projectState.deleteTimeSelection()
            } label: {
                Label("Delete Range", systemImage: "delete.left")
            }
            .disabled(isRecording)

            Button {
                projectState.cropToTimeSelection()
            } label: {
                Label("Crop to Range", systemImage: "crop")
            }
            .disabled(isRecording)

            Button {
                projectState.splitAtTimeSelection()
            } label: {
                Label("Split at Range Edges", systemImage: "square.split.2x1")
            }
            .disabled(isRecording)
        }
    }
}

private struct AudioClipView: View {
    @ObservedObject var clip: AudioClip
    @ObservedObject var track: AudioTrack
    @ObservedObject var projectState: ProjectState
    @State private var dragStartTime: Double?
    @State private var dragStartLocationX: CGFloat?
    @State private var dragGrabOffsetY: CGFloat?
    @State private var dragTargetTrackId: UUID?
    @State private var isRangeDragging = false
    @State private var resizeStartTime: Double?
    @State private var resizeSourceStartTime: Double?
    @State private var resizeDuration: Double?
    @State private var gainStartDB: Double?
    @State private var fadeInStartDuration: Double?
    @State private var fadeOutStartDuration: Double?
    /// Midpoint gain when a fade-curve handle drag began, and which fade.
    @State private var curveDragStartMidpoint: Double?
    @State private var curveDragIsFadeIn = true
    let height: CGFloat

    init(
        clip: AudioClip,
        track: AudioTrack,
        projectState: ProjectState,
        height: CGFloat
    ) {
        self.clip = clip
        self.track = track
        self.projectState = projectState
        self.height = height
    }

    var body: some View {
        let audioEngine = projectState.audioEngine
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        // The take being recorded: from the record start (also before a
        // punch-in, when the engine is not yet "recording") until its file
        // is finalized after stop.
        let isActiveClip = track.isRecordArmed &&
            clip.id == track.clips.last?.id &&
            (audioEngine.isRecording || audioEngine.hasPendingRecording)
        let liveEndTime = audioEngine.isPunchRecording
            ? audioEngine.currentTime
            : min(audioEngine.currentTime, projectState.punchRange.enabled
                ? projectState.punchRange.endBeat * beatDuration
                : audioEngine.currentTime)
        // A punch take records the whole pass and is cut to the punch range
        // on stop; while it records, only the part inside the range is shown
        // (nothing before punch-in).
        let punchStartTime = projectState.punchRange.enabled
            ? projectState.punchRange.startBeat * beatDuration
            : nil
        let hiddenLead = isActiveClip ? max(0.0, (punchStartTime ?? clip.startTime) - clip.startTime) : 0.0
        let displayStartTime = clip.startTime + hiddenLead
        let liveDuration = max(0.0, liveEndTime - displayStartTime)
        let displayDuration = isActiveClip ? max(clip.duration - hiddenLead, liveDuration) : clip.duration
        let isHiddenBeforePunchIn = isActiveClip && hiddenLead > 0 && liveEndTime <= displayStartTime
        let clipWidth = max(4.0, CGFloat(displayDuration) * projectState.pixelsPerSecond)
        let isSelected = track.selectedClipIDs.contains(clip.id)
        let clipGainScale = CGFloat(pow(10.0, clip.gainDB / 20.0))
        let layerSpans = ClipLayering.spans(for: track.clips)
        let fadeInLocked = ClipLayering.isEdgeCovered(layerSpans, clip: clip.id, atStart: true)
        let fadeOutLocked = ClipLayering.isEdgeCovered(layerSpans, clip: clip.id, atStart: false)
        let fadeInCurve = ClipLayering.resolvedCurve(layerSpans, clip: clip.id, atStart: true)
        let fadeOutCurve = ClipLayering.resolvedCurve(layerSpans, clip: clip.id, atStart: false)
        let envelope = isActiveClip ? nil : ClipLayering.envelope(layerSpans, clip: clip.id)

        if clip.isFileMissing {
            missingFileView
                .frame(width: clipWidth, height: max(20.0, height))
                .background(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.red.opacity(0.85), lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectOnClick()
                }
                .contextMenu {
                    fileNameMenuItem
                    Divider()
                    locateFileButton
                    Divider()
                    muteButton
                    Divider()
                    deleteButton
                }
                .offset(x: CGFloat(clip.startTime) * projectState.pixelsPerSecond)
        } else if (!clip.waveformCache.peaks.isEmpty || isActiveClip) && !isHiddenBeforePunchIn {
            Group {
                if track.channelMode == .stereo {
                    VStack(spacing: 1) {
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: clip.sampleRate,
                            pixelsPerSecond: projectState.pixelsPerSecond,
                            sampleOffset: clip.sourceStartTime + hiddenLead,
                            visibleDuration: displayDuration,
                            channelIndex: 0,
                            verticalScale: projectState.waveformVerticalScale * clipGainScale,
                            envelope: envelope
                        )
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: clip.sampleRate,
                            pixelsPerSecond: projectState.pixelsPerSecond,
                            sampleOffset: clip.sourceStartTime + hiddenLead,
                            visibleDuration: displayDuration,
                            channelIndex: 1,
                            verticalScale: projectState.waveformVerticalScale * clipGainScale,
                            envelope: envelope
                        )
                    }
                } else {
                    WaveformCanvas(
                        waveformCache: clip.waveformCache,
                        trackColor: track.color,
                        sampleRate: clip.sampleRate,
                        pixelsPerSecond: projectState.pixelsPerSecond,
                        sampleOffset: clip.sourceStartTime + hiddenLead,
                        visibleDuration: displayDuration
                        , verticalScale: projectState.waveformVerticalScale * clipGainScale,
                        envelope: envelope
                    )
                }
            }
            .frame(width: clipWidth, height: max(20.0, height))
            .background(track.color.opacity(0.08))
            .overlay {
                FadeLinesOverlay(
                    fadeInWidth: CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond,
                    fadeOutWidth: CGFloat(clip.fadeOutDuration) * projectState.pixelsPerSecond,
                    fadeInCurve: fadeInCurve,
                    fadeOutCurve: fadeOutCurve
                )
            }
            .overlay {
                if !isActiveClip {
                    coveredOverlay(spans: layerSpans, width: clipWidth)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.white : track.color.opacity(0.9), lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .leading) {
                trimHandle
                    .gesture(leftTrimGesture)
            }
            .overlay(alignment: .trailing) {
                trimHandle
                    .gesture(rightTrimGesture)
            }
            .overlay(alignment: .top) {
                gainHandle
                    .gesture(gainGesture)
            }
            .overlay(alignment: .topLeading) {
                if !fadeInLocked {
                    fadeInHandle
                        .offset(x: CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond - 5.0, y: -5.0)
                        .gesture(fadeInGesture)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !fadeOutLocked {
                    fadeOutHandle
                        .offset(x: -CGFloat(clip.fadeOutDuration) * projectState.pixelsPerSecond + 5.0, y: -5.0)
                        .gesture(fadeOutGesture)
                }
            }
            // Curve handles sit on the middle of each fade line; dragging one
            // up or down bends the curve, double-click returns it to Auto.
            .overlay(alignment: .topLeading) {
                let fadeWidth = CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond
                if !fadeInLocked && !isActiveClip && fadeWidth >= 16.0 {
                    curveHandle
                        .offset(
                            x: fadeWidth / 2.0 - 10.0,
                            y: max(20.0, height) * CGFloat(1.0 - fadeInCurve.midpointGain) - 10.0
                        )
                        .gesture(curveGesture(atStart: true, resolved: fadeInCurve))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { resetCurve(atStart: true) })
                }
            }
            .overlay(alignment: .topTrailing) {
                let fadeWidth = CGFloat(clip.fadeOutDuration) * projectState.pixelsPerSecond
                if !fadeOutLocked && !isActiveClip && fadeWidth >= 16.0 {
                    curveHandle
                        .offset(
                            x: -fadeWidth / 2.0 + 10.0,
                            y: max(20.0, height) * CGFloat(1.0 - fadeOutCurve.midpointGain) - 10.0
                        )
                        .gesture(curveGesture(atStart: false, resolved: fadeOutCurve))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { resetCurve(atStart: false) })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            // Value tooltips sit outside the clip shape so they are not cut off
            // at the clip edge while a handle is being dragged.
            .overlay(alignment: .topLeading) {
                if fadeInStartDuration != nil {
                    EditValueTooltip(text: String(localized: "Fade In \(Self.formatFadeTime(clip.fadeInDuration))"))
                        .offset(x: CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond + 8.0, y: 2.0)
                }
            }
            .overlay(alignment: .topTrailing) {
                if fadeOutStartDuration != nil {
                    EditValueTooltip(text: String(localized: "Fade Out \(Self.formatFadeTime(clip.fadeOutDuration))"))
                        .offset(x: -CGFloat(clip.fadeOutDuration) * projectState.pixelsPerSecond - 8.0, y: 2.0)
                }
            }
            .overlay(alignment: .topLeading) {
                if curveDragStartMidpoint != nil {
                    let isFadeIn = curveDragIsFadeIn
                    let curve = isFadeIn ? fadeInCurve : fadeOutCurve
                    let fadeWidth = CGFloat(isFadeIn ? clip.fadeInDuration : clip.fadeOutDuration) * projectState.pixelsPerSecond
                    let handleX = isFadeIn ? fadeWidth / 2.0 : clipWidth - fadeWidth / 2.0
                    EditValueTooltip(text: Self.formatCurve(curve))
                        .offset(
                            x: handleX + 12.0,
                            y: max(20.0, height) * CGFloat(1.0 - curve.midpointGain) - 8.0
                        )
                }
            }
            .overlay(alignment: .top) {
                if gainStartDB != nil {
                    EditValueTooltip(text: Self.formatGain(clip.gainDB))
                        .offset(x: 50.0, y: 2.0)
                }
            }
            .zIndex(fadeInStartDuration != nil || fadeOutStartDuration != nil || gainStartDB != nil || curveDragStartMidpoint != nil ? 1 : 0)
            .opacity(clip.isMuted ? 0.35 : 1.0)
            .opacity(projectState.clipDragPreview?.clipID == clip.id ? 0 : 1)
            .contentShape(Rectangle())
            .gesture(
                    DragGesture(coordinateSpace: .named("timelineScroll"))
                    .onChanged { value in
                            let pixelsPerSecond = projectState.pixelsPerSecond
                            if dragStartTime == nil && !isRangeDragging {
                                let modifiers = NSEvent.modifierFlags
                                if modifiers.contains(.command) {
                                    // Cmd-drag on a clip selects a time range instead of moving.
                                    isRangeDragging = true
                                    projectState.beginTimeSelection(
                                        atTime: Double(value.startLocation.x / pixelsPerSecond),
                                        timelineY: value.startLocation.y
                                    )
                                } else {
                                    projectState.beginClipEdit()
                                    if !track.selectedClipIDs.contains(clip.id) {
                                        if modifiers.contains(.shift) {
                                            projectState.toggleClipSelection(trackId: track.id, clipId: clip.id)
                                        } else {
                                            projectState.selectClip(trackId: track.id, clipId: clip.id)
                                        }
                                    }
                                    projectState.beginGroupDrag()
                                    if modifiers.contains(.option) {
                                        projectState.duplicateSelectedClipsInPlace()
                                    }
                                    dragStartTime = clip.startTime
                                    dragStartLocationX = value.startLocation.x
                                    dragTargetTrackId = track.id
                                    dragGrabOffsetY = value.startLocation.y - projectState.trackTopY(for: track.id)
                                    projectState.beginClipDragPreview(
                                        clipID: clip.id,
                                        startTime: clip.startTime,
                                        topY: projectState.trackTopY(for: track.id) + 2.0,
                                        width: clipWidth,
                                        height: max(20.0, height),
                                        color: track.color,
                                        clip: clip,
                                        isStereo: track.channelMode == .stereo
                                    )
                                }
                            }
                            if isRangeDragging {
                                projectState.updateTimeSelection(
                                    toTime: Double(value.location.x / pixelsPerSecond),
                                    timelineY: value.location.y
                                )
                                return
                            }
                            let initialStartTime = dragStartTime ?? clip.startTime
                            let initialLocationX = dragStartLocationX ?? value.startLocation.x
                            let horizontalDelta = value.location.x - initialLocationX
                            let rawStartTime = initialStartTime + Double(horizontalDelta / pixelsPerSecond)
                            let newStartTime = projectState.snappedTimelineTime(rawStartTime)
                            projectState.updateGroupDrag(delta: newStartTime - initialStartTime)
                            dragTargetTrackId = projectState.trackID(atTimelineY: value.location.y)
                            let grabOffsetY = dragGrabOffsetY ?? 0.0
                            projectState.updateClipDragPreview(
                                startTime: clip.startTime,
                                topY: value.location.y - grabOffsetY
                            )
                    }
                    .onEnded { _ in
                            if isRangeDragging {
                                isRangeDragging = false
                                projectState.endTimeSelection()
                                return
                            }
                            let tracks = projectState.tracks
                            if let destinationTrackId = dragTargetTrackId,
                               let from = tracks.firstIndex(where: { $0.id == track.id }),
                               let to = tracks.firstIndex(where: { $0.id == destinationTrackId }) {
                                projectState.endGroupDrag(trackDelta: to - from)
                            } else {
                                projectState.endGroupDrag(trackDelta: 0)
                            }
                            dragStartTime = nil
                            dragStartLocationX = nil
                            dragTargetTrackId = nil
                            dragGrabOffsetY = nil
                            projectState.endClipDragPreview()
                            projectState.endClipEdit()
                            projectState.audioEngine.syncAfterClipEdit(
                                projectState.tracks,
                                fxChannels: projectState.fxChannels
                            )
                    }
            )
            .onTapGesture {
                selectOnClick()
            }
            .contextMenu {
                fileNameMenuItem
                Divider()
                EditMenuItems(projectState: projectState) {
                    if projectState.timeSelection == nil && !track.selectedClipIDs.contains(clip.id) {
                        projectState.selectClip(trackId: track.id, clipId: clip.id)
                    }
                }
                Divider()
                Button {
                    projectState.normalizeClips(trackId: track.id, clipId: clip.id)
                } label: {
                    Label("Normalize", systemImage: "waveform.badge.plus")
                }
                .disabled(projectState.audioEngine.isRecording)
                Button {
                    projectState.reverseClips(trackId: track.id, clipId: clip.id)
                } label: {
                    Label("Reverse", systemImage: "arrow.uturn.backward")
                }
                .disabled(projectState.audioEngine.isRecording)
                Divider()
                locateFileButton
                Divider()
                muteButton
                Divider()

                Button {
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                    projectState.duplicateClip(trackId: track.id, clipId: clip.id)
                } label: {
                    Label("Duplicate Recording", systemImage: "plus.square.on.square")
                }
                .disabled(projectState.audioEngine.isRecording)

                Button {
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                    projectState.splitClip(trackId: track.id, clipId: clip.id)
                } label: {
                    Label("Split at Cursor", systemImage: "scissors")
                }
                .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

                Divider()

                Button(role: .destructive) {
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                    projectState.deleteClip(trackId: track.id, clipId: clip.id)
                } label: {
                    Label("Delete Recording", systemImage: "trash")
                }
                .disabled(projectState.audioEngine.isRecording)
            }
            .offset(x: CGFloat(displayStartTime) * projectState.pixelsPerSecond)
        }
    }

    /// The clip's file name (no path) at the top of its menu. A menu shows
    /// plain text greyed out, so it is a button: it reveals the file in the
    /// Finder. A missing file has nothing to reveal and stays greyed out.
    @ViewBuilder
    private var fileNameMenuItem: some View {
        if clip.isFileMissing {
            Text(verbatim: clip.fileURL.lastPathComponent)
        } else {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([clip.fileURL])
            } label: {
                Label {
                    Text(verbatim: clip.fileURL.lastPathComponent)
                } icon: {
                    Image(systemName: "doc")
                }
            }
            .help("Show in Finder")
        }
    }

    /// Darkens the parts of this clip fully hidden by clips layered above it
    /// (where its waveform is drawn flat, since nothing of it is heard).
    private func coveredOverlay(spans: [ClipLayerSpan], width: CGFloat) -> some View {
        let start = clip.startTime
        let pps = projectState.pixelsPerSecond
        let hidden = ClipLayering.segments(spans, clip: clip.id).filter { $0.kind == .hidden }
        return Canvas { context, size in
            for segment in hidden {
                let x0 = CGFloat(segment.start - start) * pps
                let x1 = CGFloat(segment.end - start) * pps
                guard x1 > x0 else { continue }
                context.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(.black.opacity(0.55)))
            }
        }
        .frame(width: width)
        .allowsHitTesting(false)
    }

    private var missingFileView: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red.opacity(0.9))
            Text("The recording file cannot be found.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text(clip.fileURL.lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var locateFileButton: some View {
        Button {
            projectState.selectClip(trackId: track.id, clipId: clip.id)
            projectState.locateClipFile(trackId: track.id, clipId: clip.id)
        } label: {
            Label("Choose Recording File…", systemImage: "folder")
        }
        .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)
    }

    private var muteButton: some View {
        Button {
            projectState.selectClip(trackId: track.id, clipId: clip.id)
            projectState.toggleClipMute(trackId: track.id, clipId: clip.id)
        } label: {
            Label(
                clip.isMuted ? "Unmute Recording" : "Mute Recording",
                systemImage: clip.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            )
        }
        .disabled(projectState.audioEngine.isRecording)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            projectState.selectClip(trackId: track.id, clipId: clip.id)
            projectState.deleteClip(trackId: track.id, clipId: clip.id)
        } label: {
            Label("Delete Recording", systemImage: "trash")
        }
        .disabled(projectState.audioEngine.isRecording)
    }

    /// Plain click selects only this clip; Shift- or Cmd-click adds it to or
    /// removes it from the selection.
    private func selectOnClick() {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            projectState.toggleClipSelection(trackId: track.id, clipId: clip.id)
        } else {
            projectState.selectClip(trackId: track.id, clipId: clip.id)
        }
    }

    private var trimHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.9))
            .frame(width: 4, height: 34)
            .padding(.horizontal, 3)
            .contentShape(Rectangle().size(width: 16, height: 80))
    }

    private var gainHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.95))
            .frame(width: 34, height: 5)
            .padding(.vertical, 4)
            .contentShape(Rectangle().size(width: 56, height: 24))
    }

    private var fadeInHandle: some View {
        Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .contentShape(Rectangle().size(width: 18, height: 24))
    }

    private var fadeOutHandle: some View {
        Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .contentShape(Rectangle().size(width: 18, height: 24))
    }

    // minimumDistance 0 so the value tooltip appears on mouse-down, before any movement.
    private var curveHandle: some View {
        Rectangle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    /// Vertical drag moves the fade's halfway point: up bows the curve up.
    private func curveGesture(atStart: Bool, resolved: FadeCurve) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if curveDragStartMidpoint == nil {
                    projectState.beginClipEdit()
                    curveDragStartMidpoint = resolved.midpointGain
                    curveDragIsFadeIn = atStart
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                }
                let start = curveDragStartMidpoint ?? resolved.midpointGain
                let curve = FadeCurve.withMidpoint(start - Double(value.translation.height / max(20.0, height)))
                if atStart {
                    clip.fadeInCurve = curve
                } else {
                    clip.fadeOutCurve = curve
                }
            }
            .onEnded { _ in
                curveDragStartMidpoint = nil
                projectState.endClipEdit()
                projectState.audioEngine.syncAfterClipEdit(
                    projectState.tracks,
                    fxChannels: projectState.fxChannels
                )
            }
    }

    private func resetCurve(atStart: Bool) {
        projectState.beginClipEdit()
        if atStart {
            clip.fadeInCurve = .auto
        } else {
            clip.fadeOutCurve = .auto
        }
        projectState.endClipEdit()
        projectState.audioEngine.syncAfterClipEdit(
            projectState.tracks,
            fxChannels: projectState.fxChannels
        )
    }

    private var gainGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if gainStartDB == nil {
                    projectState.beginClipEdit()
                    gainStartDB = clip.gainDB
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                }
                let sensitivity = 24.0 / 80.0
                clip.setGainDB((gainStartDB ?? clip.gainDB) - Double(value.translation.height) * sensitivity)
            }
            .onEnded { _ in
                gainStartDB = nil
                projectState.endClipEdit()
                projectState.audioEngine.syncAfterClipEdit(
                    projectState.tracks,
                    fxChannels: projectState.fxChannels
                )
            }
    }

    private var fadeInGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if fadeInStartDuration == nil {
                    projectState.beginClipEdit()
                    fadeInStartDuration = clip.fadeInDuration
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                }
                let initial = fadeInStartDuration ?? clip.fadeInDuration
                let duration = min(
                    clip.duration,
                    max(0.0, initial + Double(value.translation.width / projectState.pixelsPerSecond))
                )
                clip.setFadeInDuration(duration)
            }
            .onEnded { _ in
                fadeInStartDuration = nil
                projectState.endClipEdit()
                projectState.audioEngine.syncAfterClipEdit(
                    projectState.tracks,
                    fxChannels: projectState.fxChannels
                )
            }
    }

    private var fadeOutGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if fadeOutStartDuration == nil {
                    projectState.beginClipEdit()
                    fadeOutStartDuration = clip.fadeOutDuration
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                }
                let initial = fadeOutStartDuration ?? clip.fadeOutDuration
                let duration = min(
                    clip.duration,
                    max(0.0, initial - Double(value.translation.width / projectState.pixelsPerSecond))
                )
                clip.setFadeOutDuration(duration)
            }
            .onEnded { _ in
                fadeOutStartDuration = nil
                projectState.endClipEdit()
                projectState.audioEngine.syncAfterClipEdit(
                    projectState.tracks,
                    fxChannels: projectState.fxChannels
                )
            }
    }

    private var leftTrimGesture: some Gesture {
        DragGesture(coordinateSpace: .named("timeline"))
            .onChanged { value in
                if resizeStartTime == nil {
                    projectState.beginClipEdit()
                    resizeStartTime = clip.startTime
                    resizeSourceStartTime = clip.sourceStartTime
                    resizeDuration = clip.duration
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                }
                let pps = projectState.pixelsPerSecond
                let initialStart = resizeStartTime ?? clip.startTime
                let initialSource = resizeSourceStartTime ?? clip.sourceStartTime
                let initialDuration = resizeDuration ?? clip.duration
                let rawStartTime = max(0.0, Double(value.location.x / pps))
                let snappedStartTime = projectState.snappedTimelineTime(rawStartTime)
                let snappedDelta = min(
                    initialDuration - 0.02,
                    max(-initialSource, snappedStartTime - initialStart)
                )
                clip.setTrim(
                    startTime: snappedStartTime,
                    sourceStartTime: initialSource + snappedDelta,
                    duration: initialDuration - snappedDelta
                )
            }
            .onEnded { _ in
                resetResizeState()
                projectState.endClipEdit()
                projectState.audioEngine.syncAfterClipEdit(
                    projectState.tracks,
                    fxChannels: projectState.fxChannels
                )
            }
    }

    private var rightTrimGesture: some Gesture {
        DragGesture(coordinateSpace: .named("timeline"))
            .onChanged { value in
                if resizeStartTime == nil {
                    projectState.beginClipEdit()
                    resizeStartTime = clip.startTime
                    resizeSourceStartTime = clip.sourceStartTime
                    resizeDuration = clip.duration
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                }
                let initialSource = resizeSourceStartTime ?? clip.sourceStartTime
                let maxDuration = max(0.02, clip.originalDuration - initialSource)
                let initialStart = resizeStartTime ?? clip.startTime
                let rawEndTime = max(0.0, Double(value.location.x / projectState.pixelsPerSecond))
                let snappedEndTime = projectState.snappedTimelineTime(rawEndTime)
                let newDuration = min(maxDuration, max(0.02, snappedEndTime - initialStart))
                clip.setTrim(
                    startTime: initialStart,
                    sourceStartTime: initialSource,
                    duration: newDuration
                )
            }
            .onEnded { _ in
                resetResizeState()
                projectState.endClipEdit()
                projectState.audioEngine.syncAfterClipEdit(
                    projectState.tracks,
                    fxChannels: projectState.fxChannels
                )
            }
    }

    private static func formatFadeTime(_ seconds: Double) -> String {
        seconds < 1.0
            ? String(format: "%.0f ms", seconds * 1000.0)
            : String(format: "%.2f s", seconds)
    }

    /// Curve readout: gain at the fade's halfway point, plus its name.
    private static func formatCurve(_ curve: FadeCurve) -> String {
        let midpointDB = String(format: "%.1f", 20.0 * log10(curve.midpointGain))
        return String(localized: "Mid \(midpointDB) dB  \(curve.title)")
    }

    private static func formatGain(_ gainDB: Double) -> String {
        String(format: "%+.1f dB", abs(gainDB) < 0.05 ? 0.0 : gainDB)
    }

    private func resetResizeState() {
        resizeStartTime = nil
        resizeSourceStartTime = nil
        resizeDuration = nil
        gainStartDB = nil
        fadeInStartDuration = nil
        fadeOutStartDuration = nil
    }
}

/// Small value readout shown next to a handle while it is being dragged.
private struct EditValueTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}

