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
}

private struct AudioClipView: View {
    @ObservedObject var clip: AudioClip
    @ObservedObject var track: AudioTrack
    @ObservedObject var projectState: ProjectState
    @State private var dragStartTime: Double?
    @State private var dragStartLocationX: CGFloat?
    @State private var dragGrabOffsetY: CGFloat?
    @State private var dragTargetTrackId: UUID?
    @State private var resizeStartTime: Double?
    @State private var resizeSourceStartTime: Double?
    @State private var resizeDuration: Double?
    @State private var gainStartDB: Double?
    @State private var fadeInStartDuration: Double?
    @State private var fadeOutStartDuration: Double?
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
        let isActiveClip = track.isRecordArmed &&
            clip.id == track.clips.last?.id &&
            projectState.audioEngine.isRecording
        let liveDuration = max(0.0, projectState.audioEngine.currentTime - clip.startTime)
        let displayDuration = max(clip.duration, isActiveClip ? liveDuration : 0.0)
        let clipWidth = max(4.0, CGFloat(displayDuration) * projectState.pixelsPerSecond)
        let isSelected = track.selectedClipId == clip.id
        let clipGainScale = CGFloat(pow(10.0, clip.gainDB / 20.0))

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
                    projectState.selectClip(trackId: track.id, clipId: clip.id)
                }
                .contextMenu {
                            locateFileButton
                    Divider()
                    muteButton
                    Divider()
                    deleteButton
                }
                .offset(x: CGFloat(clip.startTime) * projectState.pixelsPerSecond)
        } else if !clip.waveformCache.peaks.isEmpty || isActiveClip {
            Group {
                if track.channelMode == .stereo {
                    VStack(spacing: 1) {
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: clip.sampleRate,
                            pixelsPerSecond: projectState.pixelsPerSecond,
                            sampleOffset: clip.sourceStartTime,
                            visibleDuration: displayDuration,
                            channelIndex: 0,
                            verticalScale: projectState.waveformVerticalScale * clipGainScale,
                            fadeInDuration: clip.fadeInDuration,
                            fadeOutDuration: clip.fadeOutDuration
                        )
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: clip.sampleRate,
                            pixelsPerSecond: projectState.pixelsPerSecond,
                            sampleOffset: clip.sourceStartTime,
                            visibleDuration: displayDuration,
                            channelIndex: 1,
                            verticalScale: projectState.waveformVerticalScale * clipGainScale,
                            fadeInDuration: clip.fadeInDuration,
                            fadeOutDuration: clip.fadeOutDuration
                        )
                    }
                } else {
                    WaveformCanvas(
                        waveformCache: clip.waveformCache,
                        trackColor: track.color,
                        sampleRate: clip.sampleRate,
                        pixelsPerSecond: projectState.pixelsPerSecond,
                        sampleOffset: clip.sourceStartTime,
                        visibleDuration: displayDuration
                        , verticalScale: projectState.waveformVerticalScale * clipGainScale,
                        fadeInDuration: clip.fadeInDuration,
                        fadeOutDuration: clip.fadeOutDuration
                    )
                }
            }
            .frame(width: clipWidth, height: max(20.0, height))
            .background(track.color.opacity(0.08))
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
                fadeInHandle
                    .offset(x: CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond - 5.0, y: -5.0)
                    .gesture(fadeInGesture)
            }
            .overlay(alignment: .topTrailing) {
                fadeOutHandle
                    .offset(x: -CGFloat(clip.fadeOutDuration) * projectState.pixelsPerSecond + 5.0, y: -5.0)
                    .gesture(fadeOutGesture)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(clip.isMuted ? 0.35 : 1.0)
            .opacity(projectState.clipDragPreview?.clipID == clip.id ? 0 : 1)
            .contentShape(Rectangle())
            .gesture(
                    DragGesture(coordinateSpace: .named("timelineScroll"))
                    .onChanged { value in
                            let pixelsPerSecond = projectState.pixelsPerSecond
                            if dragStartTime == nil {
                                projectState.beginClipEdit()
                                dragStartTime = clip.startTime
                                dragStartLocationX = value.startLocation.x
                                dragTargetTrackId = track.id
                                dragGrabOffsetY = value.startLocation.y - trackTopY(for: track.id)
                                projectState.beginClipDragPreview(
                                    clipID: clip.id,
                                    startTime: clip.startTime,
                                    topY: trackTopY(for: track.id) + 2.0,
                                    width: clipWidth,
                                    height: max(20.0, height),
                                    color: track.color
                                )
                                projectState.selectClip(trackId: track.id, clipId: clip.id)
                            }
                            let initialStartTime = dragStartTime ?? clip.startTime
                            let initialLocationX = dragStartLocationX ?? value.startLocation.x
                            let horizontalDelta = value.location.x - initialLocationX
                            let rawStartTime = initialStartTime + Double(horizontalDelta / pixelsPerSecond)
                            let newStartTime = projectState.snappedTimelineTime(rawStartTime)
                            track.moveClip(id: clip.id, to: newStartTime)
                            dragTargetTrackId = trackID(atTimelineY: value.location.y)
                            let grabOffsetY = dragGrabOffsetY ?? 0.0
                            projectState.updateClipDragPreview(
                                startTime: newStartTime,
                                topY: value.location.y - grabOffsetY
                            )
                    }
                    .onEnded { _ in
                            let destinationTrackId = dragTargetTrackId
                            let finalStartTime = clip.startTime
                            if let destinationTrackId,
                               destinationTrackId != track.id {
                                _ = projectState.moveClip(
                                    clipId: clip.id,
                                    from: track.id,
                                    to: destinationTrackId,
                                    startTime: finalStartTime
                                )
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
                projectState.selectClip(trackId: track.id, clipId: clip.id)
            }
            .contextMenu {
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
            .offset(x: CGFloat(clip.startTime) * projectState.pixelsPerSecond)
        }
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

    private func trackTopY(for trackID: UUID) -> CGFloat {
        var currentY: CGFloat = 0.0
        for candidate in projectState.tracks {
            if candidate.id == trackID {
                return currentY
            }
            currentY += TrackHeaderView.rowHeight(for: candidate) * projectState.trackHeightScale + 1.0
        }
        return currentY
    }

    private func trackID(atTimelineY y: CGFloat) -> UUID? {
        var currentY: CGFloat = 0.0
        for candidate in projectState.tracks {
            let height = TrackHeaderView.rowHeight(for: candidate) * projectState.trackHeightScale
            if y >= currentY && y < currentY + height {
                return candidate.id
            }
            currentY += height + 1.0
        }
        return nil
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

    private var gainGesture: some Gesture {
        DragGesture()
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
        DragGesture(coordinateSpace: .named("timeline"))
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
            }
    }

    private var fadeOutGesture: some Gesture {
        DragGesture(coordinateSpace: .named("timeline"))
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

    private func resetResizeState() {
        resizeStartTime = nil
        resizeSourceStartTime = nil
        resizeDuration = nil
        gainStartDB = nil
        fadeInStartDuration = nil
        fadeOutStartDuration = nil
    }
}

