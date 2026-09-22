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
    @State private var dragPointerOffset: CGFloat?
    @State private var resizeStartTime: Double?
    @State private var resizeSourceStartTime: Double?
    @State private var resizeDuration: Double?
    let height: CGFloat

    init(clip: AudioClip, track: AudioTrack, projectState: ProjectState, height: CGFloat) {
        self.clip = clip
        self.track = track
        self.projectState = projectState
        self.height = height
    }

    var body: some View {
        let isActiveClip = clip.id == track.clips.last?.id && projectState.audioEngine.isRecording
        let liveDuration = max(0.0, projectState.audioEngine.currentTime - clip.startTime)
        let displayDuration = max(clip.duration, isActiveClip ? liveDuration : 0.0)
        let clipWidth = max(4.0, CGFloat(displayDuration) * projectState.pixelsPerSecond)
        let isSelected = track.selectedClipId == clip.id

        if !clip.waveformCache.peaks.isEmpty || isActiveClip {
            Group {
                if track.channelMode == .stereo {
                    VStack(spacing: 1) {
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: projectState.audioEngine.hardwareSampleRate,
                            pixelsPerSecond: projectState.pixelsPerSecond,
                            sampleOffset: clip.sourceStartTime,
                            visibleDuration: displayDuration,
                            channelIndex: 0,
                            verticalScale: projectState.waveformVerticalScale
                        )
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: projectState.audioEngine.hardwareSampleRate,
                            pixelsPerSecond: projectState.pixelsPerSecond,
                            sampleOffset: clip.sourceStartTime,
                            visibleDuration: displayDuration,
                            channelIndex: 1,
                            verticalScale: projectState.waveformVerticalScale
                        )
                    }
                } else {
                    WaveformCanvas(
                        waveformCache: clip.waveformCache,
                        trackColor: track.color,
                        sampleRate: projectState.audioEngine.hardwareSampleRate,
                        pixelsPerSecond: projectState.pixelsPerSecond,
                        sampleOffset: clip.sourceStartTime,
                        visibleDuration: displayDuration
                        , verticalScale: projectState.waveformVerticalScale
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
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .gesture(
                    DragGesture(coordinateSpace: .named("timeline"))
                    .onChanged { value in
                            let pixelsPerSecond = projectState.pixelsPerSecond
                            if dragPointerOffset == nil {
                                projectState.beginClipEdit()
                                let clipStartX = CGFloat(clip.startTime) * pixelsPerSecond
                                dragPointerOffset = value.location.x - clipStartX
                            projectState.selectClip(trackId: track.id, clipId: clip.id)
                        }
                            let pointerOffset = dragPointerOffset ?? 0.0
                            let rawStartTime = Double((value.location.x - pointerOffset) / pixelsPerSecond)
                            let newStartTime = projectState.snappedTimelineTime(rawStartTime)
                            track.moveClip(id: clip.id, to: newStartTime)
                    }
                    .onEnded { _ in
                            dragPointerOffset = nil
                        projectState.endClipEdit()
                        projectState.audioEngine.syncTracks(projectState.tracks)
                    }
            )
            .onTapGesture {
                projectState.selectClip(trackId: track.id, clipId: clip.id)
            }
            .contextMenu {
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

    private var trimHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.9))
            .frame(width: 4, height: 34)
            .padding(.horizontal, 3)
            .contentShape(Rectangle().size(width: 16, height: 80))
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
                let rawDelta = Double(value.translation.width / pps)
                let delta = min(initialDuration - 0.02, max(-initialSource, rawDelta))
                let snappedStartTime = projectState.snappedTimelineTime(initialStart + delta)
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
                projectState.audioEngine.syncTracks(projectState.tracks)
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
                let initialDuration = resizeDuration ?? clip.duration
                let initialSource = resizeSourceStartTime ?? clip.sourceStartTime
                let maxDuration = max(0.02, clip.originalDuration - initialSource)
                let rawDelta = Double(value.translation.width / projectState.pixelsPerSecond)
                let initialStart = resizeStartTime ?? clip.startTime
                let snappedEndTime = projectState.snappedTimelineTime(initialStart + initialDuration + rawDelta)
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
                projectState.audioEngine.syncTracks(projectState.tracks)
            }
    }

    private func resetResizeState() {
        resizeStartTime = nil
        resizeSourceStartTime = nil
        resizeDuration = nil
    }
}

