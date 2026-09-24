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

    // Dynamic timeline width (minimum 2000pt or extends with zoom & duration)
    private var timelineWidth: CGFloat {
        let clipEndTime = projectState.tracks
            .flatMap { $0.clips }
            .map { $0.startTime + $0.duration }
            .max() ?? 0.0
        let maxDuration = max(60.0, audioEngine.currentTime + 30.0, clipEndTime + 5.0)
        return max(2500.0, CGFloat(maxDuration) * projectState.pixelsPerSecond)
    }

    public init(projectState: ProjectState, audioEngine: AudioEngineManager) {
        self.projectState = projectState
        self.audioEngine = audioEngine
    }

    public var body: some View {
        GeometryReader { viewport in
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
                                    isSelected: projectState.selectedTrackId == track.id
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

                                    if let preview = projectState.clipDragPreview {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(preview.color.opacity(0.18))
                                            .frame(width: preview.width, height: preview.height)
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

                                    VStack(spacing: 0) {
                                        Triangle()
                                            .fill(Color.orange)
                                            .frame(width: 12, height: 8)
                                            .offset(y: -4)

                                        Rectangle()
                                            .fill(Color.orange)
                                            .frame(width: 2, height: max(300, totalHeight))
                                    }
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
            }
        }
    }

// MARK: - Timeline Ruler View
struct TimelineRulerView: View {
    @ObservedObject var audioEngine: AudioEngineManager
    @ObservedObject var projectState: ProjectState
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
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

            PunchRangeOverlay(
                audioEngine: audioEngine,
                projectState: projectState,
                width: width
            )
        }
        .frame(width: width, height: 32)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let clickX = max(0, value.location.x)
                    let targetTime = Double(clickX / projectState.pixelsPerSecond)
                    audioEngine.seek(
                        to: targetTime,
                        tracks: projectState.tracks,
                        fxChannels: projectState.fxChannels
                    )
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

// Scrubber triangle indicator
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
