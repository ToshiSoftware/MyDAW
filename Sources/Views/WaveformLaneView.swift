import SwiftUI
import UniformTypeIdentifiers

public struct WaveformLaneView: View {
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
    /// Clips outside it are not built: they are off screen, and building
    /// hundreds of clip views on every zoom step was a large part of its cost.
    @EnvironmentObject var waveformDrawWindow: DrawWindowState
    @ObservedObject public var track: AudioTrack
    @ObservedObject public var projectState: ProjectState
    public let timelineWidth: CGFloat

    public init(track: AudioTrack, projectState: ProjectState, timelineWidth: CGFloat) {
        self.track = track
        self.projectState = projectState
        self.timelineWidth = timelineWidth
    }

    /// The take being recorded (see `AudioClipView`), which grows with the
    /// playhead.
    private func isLiveRecordingClip(_ clip: AudioClip) -> Bool {
        // Asked of the engine, not the R button, so the take stays live
        // whatever the button shows.
        projectState.audioEngine.isRecordingTake(clip.id)
    }

    public var body: some View {
        let rowHeight = TrackHeaderView.rowHeight(for: track) * projectState.trackHeightScale
        ZStack(alignment: .leading) {
            // Background lane
            Rectangle()
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13))
                .frame(width: timelineWidth, height: rowHeight)

            // Grid Lines (every second or every 5 seconds depending on zoom),
            // only across the draw window: the lane spans the whole song, and
            // drawing all of it again on every zoom step was wasted.
            let gridWindow = waveformDrawWindow.range
            Canvas { context, size in
                let pps = projectState.pixelsPerSecond
                let stepSeconds: Double = pps > 60 ? 1.0 : 5.0
                let stepPixels = stepSeconds * Double(pps)
                let firstStep = max(0.0, (gridWindow.lowerBound / stepSeconds).rounded(.down))
                let endX = min(Double(size.width), gridWindow.upperBound * Double(pps))

                var lines = Path()
                var x = firstStep * stepPixels
                while x < endX {
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.addLine(to: CGPoint(x: x, y: size.height))
                    x += stepPixels
                }
                context.stroke(lines, with: .color(Color.white.opacity(0.04)), lineWidth: 1)
            }
            .frame(width: timelineWidth, height: rowHeight)

            // Each recording session is displayed as a separate timeline clip.
            if !track.clips.isEmpty {
                // Worked out once for the lane, not once per clip.
                let layerSpans = ClipLayering.spans(for: projectState.layeringClips(for: track))
                let window = waveformDrawWindow.range
                let builtClips = track.clips.filter { clip in
                    (clip.startTime <= window.upperBound && clip.startTime + clip.duration >= window.lowerBound)
                        || track.selectedClipIDs.contains(clip.id) || isLiveRecordingClip(clip)
                }
                ZStack(alignment: .leading) {
                    ForEach(builtClips) { clip in
                        if isLiveRecordingClip(clip) {
                            LiveRecordingClipView(
                                clock: projectState.audioEngine.transportClock,
                                clip: clip,
                                track: track,
                                projectState: projectState,
                                height: rowHeight - 4,
                                layerSpans: layerSpans
                            )
                        } else {
                            AudioClipView(
                                clip: clip,
                                track: track,
                                projectState: projectState,
                                height: rowHeight - 4,
                                layerSpans: layerSpans
                            )
                        }
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
        // Right-click menus are built in AppKit at the click, after the
        // clicked clip is selected (a SwiftUI menu is built beforehand).
        .background(LaneMenuMonitor { x in laneMenu(atX: x) })
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

    /// Menu for a right-click at `x` in this lane: the range menu inside the
    /// time selection; on a clip, the clip menu (the clip is selected first
    /// unless it is already selected); elsewhere the clipboard menu.
    private func laneMenu(atX x: CGFloat) -> NSMenu {
        let time = Double(x / projectState.pixelsPerSecond)
        if let selection = projectState.timeSelection,
           selection.trackIDs.contains(track.id),
           time >= selection.start, time <= selection.end {
            return LaneMenu.editMenu(projectState)
        }
        if let clip = clip(atX: x) {
            projectState.selectForMenu(trackId: track.id, clipId: clip.id)
            return LaneMenu.clipMenu(projectState, track: track, clip: clip)
        }
        return LaneMenu.editMenu(projectState)
    }

    /// The topmost clip drawn at `x` (later clips lie on top).
    private func clip(atX x: CGFloat) -> AudioClip? {
        let pps = projectState.pixelsPerSecond
        return track.clips.last { clip in
            let start = CGFloat(clip.startTime) * pps
            return x >= start && x <= start + max(4.0, CGFloat(clip.duration) * pps)
        }
    }
}

/// The lane right-click menus.
@MainActor
private enum LaneMenu {
    /// Clipboard commands, plus the range commands when a range is selected.
    static func editMenu(_ projectState: ProjectState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addEditItems(to: menu, projectState)
        return menu
    }

    private static func addEditItems(to menu: NSMenu, _ projectState: ProjectState) {
        let isRecording = projectState.audioEngine.isRecording
        menu.addItem(ClosureMenuItem(String(localized: "Cut"), symbol: "scissors",
                                     enabled: !isRecording && projectState.hasSelection) {
            projectState.cutSelection()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Copy"), symbol: "doc.on.doc",
                                     enabled: projectState.hasSelection) {
            projectState.copySelection()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Paste at Playhead"), symbol: "doc.on.clipboard",
                                     enabled: !isRecording && projectState.canPaste) {
            projectState.paste()
        })
        guard projectState.timeSelection != nil else { return }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Delete Range"), symbol: "delete.left",
                                     enabled: !isRecording) {
            projectState.deleteTimeSelection()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Crop to Range"), symbol: "crop",
                                     enabled: !isRecording) {
            projectState.cropToTimeSelection()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Split at Range Edges"), symbol: "square.split.2x1",
                                     enabled: !isRecording) {
            projectState.splitAtTimeSelection()
        })
    }

    /// Commands on the clicked clip, or on every selected clip when the
    /// clicked one is part of the selection.
    static func clipMenu(_ projectState: ProjectState, track: AudioTrack, clip: AudioClip) -> NSMenu {
        let engine = projectState.audioEngine
        let isRecording = engine.isRecording
        let isBusy = engine.isPlaying || engine.isRecording
        let targets = projectState.menuTargets(trackId: track.id, clipId: clip.id)
        let count = targets.count
        let isMulti = count > 1
        // A lone clip whose file is missing only offers what can fix or drop it.
        let isMissingOnly = !isMulti && clip.isFileMissing
        let trackId = track.id
        let clipId = clip.id

        let menu = NSMenu()
        menu.autoenablesItems = false

        if isMulti {
            menu.addItem(ClosureMenuItem(String(localized: "\(count) Clips"), symbol: "square.stack", enabled: false) {})
        } else if clip.isFileMissing {
            menu.addItem(ClosureMenuItem(clip.fileURL.lastPathComponent, symbol: "doc", enabled: false) {})
        } else {
            let fileURL = clip.fileURL
            let item = ClosureMenuItem(fileURL.lastPathComponent, symbol: "doc", enabled: true) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            item.toolTip = String(localized: "Show in Finder")
            menu.addItem(item)
        }

        if !isMissingOnly {
            menu.addItem(.separator())
            addEditItems(to: menu, projectState)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(
                isMulti ? String(localized: "Normalize (\(count))") : String(localized: "Normalize"),
                symbol: "waveform.badge.plus", enabled: !isRecording
            ) {
                projectState.normalizeClips(trackId: trackId, clipId: clipId)
            })
            menu.addItem(ClosureMenuItem(
                isMulti ? String(localized: "Reverse (\(count))") : String(localized: "Reverse"),
                symbol: "arrow.uturn.backward", enabled: !isRecording
            ) {
                projectState.reverseClips(trackId: trackId, clipId: clipId)
            })
            menu.addItem(ClosureMenuItem(
                isMulti ? String(localized: "Strip Silence… (\(count))") : String(localized: "Strip Silence…"),
                symbol: "waveform.path.badge.minus", enabled: !isRecording
            ) {
                projectState.stripSilenceClips(trackId: trackId, clipId: clipId)
            })
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Choose Recording File…"), symbol: "folder",
                                     enabled: !isMulti && !isBusy) {
            projectState.locateClipFile(trackId: trackId, clipId: clipId)
        })

        menu.addItem(.separator())
        let willMute = targets.contains { !$0.clip.isMuted }
        let muteTitle: String
        switch (willMute, isMulti) {
        case (true, false): muteTitle = String(localized: "Mute Recording")
        case (false, false): muteTitle = String(localized: "Unmute Recording")
        case (true, true): muteTitle = String(localized: "Mute Recordings (\(count))")
        case (false, true): muteTitle = String(localized: "Unmute Recordings (\(count))")
        }
        menu.addItem(ClosureMenuItem(muteTitle, symbol: willMute ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                     enabled: !isRecording) {
            projectState.toggleMuteMenuTargets(trackId: trackId, clipId: clipId)
        })

        menu.addItem(.separator())
        if !isMissingOnly {
            menu.addItem(ClosureMenuItem(
                isMulti ? String(localized: "Duplicate Recordings (\(count))") : String(localized: "Duplicate Recording"),
                symbol: "plus.square.on.square", enabled: !isRecording
            ) {
                projectState.duplicateMenuTargets(trackId: trackId, clipId: clipId)
            })
            let splitCount = projectState.splittableMenuTargets(trackId: trackId, clipId: clipId).count
            menu.addItem(ClosureMenuItem(
                isMulti ? String(localized: "Split at Cursor (\(splitCount))") : String(localized: "Split at Cursor"),
                symbol: "scissors", enabled: splitCount > 0 && !isBusy
            ) {
                projectState.splitMenuTargets(trackId: trackId, clipId: clipId)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(
            isMulti ? String(localized: "Delete Recordings (\(count))") : String(localized: "Delete Recording"),
            symbol: "trash", enabled: !isRecording
        ) {
            projectState.deleteMenuTargets(trackId: trackId, clipId: clipId)
        })
        return menu
    }
}

/// Menu item that runs a closure. It runs after the menu has closed, so a
/// command may open a panel or an alert.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String?, enabled: Bool, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        let handler = handler
        Task { @MainActor in handler() }
    }
}

/// Opens the menu from `menu` for right-clicks (and Control-clicks) on the
/// view it is the background of, with the click's x in that view.
struct LaneMenuMonitor: NSViewRepresentable {
    let menu: @MainActor (CGFloat) -> NSMenu?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.menuProvider = menu
    }

    final class MonitorView: NSView {
        var menuProvider: (@MainActor (CGFloat) -> NSMenu?)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                    self?.handle(event) ?? event
                }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil else { return event }
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return event }
            let point = convert(event.locationInWindow, from: nil)
            // Only the part shown on screen (not scrolled away under the
            // track headers or the ruler).
            guard visibleRect.contains(point), let menu = menuProvider?(point.x) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

/// The take being recorded, redrawn as the playhead moves: other clips do
/// not observe the playhead.
private struct LiveRecordingClipView: View {
    @ObservedObject var clock: TransportClock
    let clip: AudioClip
    let track: AudioTrack
    let projectState: ProjectState
    let height: CGFloat
    let layerSpans: [ClipLayerSpan]

    var body: some View {
        AudioClipView(
            clip: clip,
            track: track,
            projectState: projectState,
            height: height,
            layerSpans: layerSpans,
            liveTime: clock.time
        )
    }
}

private struct AudioClipView: View {
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
    @ObservedObject var clip: AudioClip
    @ObservedObject var track: AudioTrack
    @ObservedObject var projectState: ProjectState
    @State private var dragStartTime: Double?
    @State private var dragStartLocationX: CGFloat?
    @State private var dragStartLocationY: CGFloat?
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
    /// The lane's layering (`ClipLayering.spans`), shared by its clips.
    let layerSpans: [ClipLayerSpan]
    /// The playhead, passed in for the take being recorded only.
    let liveTime: Double?

    init(
        clip: AudioClip,
        track: AudioTrack,
        projectState: ProjectState,
        height: CGFloat,
        layerSpans: [ClipLayerSpan],
        liveTime: Double? = nil
    ) {
        self.clip = clip
        self.track = track
        self.projectState = projectState
        self.height = height
        self.layerSpans = layerSpans
        self.liveTime = liveTime
    }

    var body: some View {
        let audioEngine = projectState.audioEngine
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        // The take being recorded: from the record start (also before a
        // punch-in, when the engine is not yet "recording") until its file
        // is finalized after stop.
        let isActiveClip = audioEngine.isRecordingTake(clip.id)
        let now = liveTime ?? audioEngine.currentTime
        let liveEndTime = audioEngine.isPunchRecording
            ? now
            : min(now, projectState.punchRange.enabled
                ? projectState.punchRange.endBeat * beatDuration
                : now)
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
                .offset(x: CGFloat(clip.startTime) * projectState.pixelsPerSecond)
        } else if (clip.hasWaveform || isActiveClip) && !isHiddenBeforePunchIn {
            // Drawn at the waveforms' zoom and track height, then stretched to
            // the box: while the zoom or height changes, only the stretch
            // follows and the waveform is drawn again once the change stops.
            let renderPixelsPerSecond = projectState.waveformRenderPixelsPerSecond
            let renderWidth = max(4.0, CGFloat(displayDuration) * renderPixelsPerSecond)
            let boxHeight = max(20.0, height)
            let renderHeight = max(20.0, height + TrackHeaderView.rowHeight(for: track)
                * (projectState.waveformRenderTrackHeightScale - projectState.trackHeightScale))
            // While the zoom or track height is changing, the handles are left
            // out: they are not used then, and each one is several views to
            // move on every step for every clip on screen.
            let isGeometryPreview = renderPixelsPerSecond != projectState.pixelsPerSecond
                || projectState.waveformRenderTrackHeightScale != projectState.trackHeightScale
            Group {
                if track.channelMode == .stereo {
                    VStack(spacing: 1) {
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: clip.sampleRate,
                            pixelsPerSecond: renderPixelsPerSecond,
                            sampleOffset: clip.sourceStartTime + hiddenLead,
                            visibleDuration: displayDuration,
                            channelIndex: 0,
                            verticalScale: projectState.waveformVerticalScale * clipGainScale,
                            envelope: envelope,
                            drawWindow: projectState.waveformDrawWindow,
                            timelineOrigin: displayStartTime,
                            scalePreview: projectState.waveformScalePreview
                        )
                        .equatable()
                        WaveformCanvas(
                            waveformCache: clip.waveformCache,
                            trackColor: track.color,
                            sampleRate: clip.sampleRate,
                            pixelsPerSecond: renderPixelsPerSecond,
                            sampleOffset: clip.sourceStartTime + hiddenLead,
                            visibleDuration: displayDuration,
                            channelIndex: 1,
                            verticalScale: projectState.waveformVerticalScale * clipGainScale,
                            envelope: envelope,
                            drawWindow: projectState.waveformDrawWindow,
                            timelineOrigin: displayStartTime,
                            scalePreview: projectState.waveformScalePreview
                        )
                        .equatable()
                    }
                } else {
                    WaveformCanvas(
                        waveformCache: clip.waveformCache,
                        trackColor: track.color,
                        sampleRate: clip.sampleRate,
                        pixelsPerSecond: renderPixelsPerSecond,
                        sampleOffset: clip.sourceStartTime + hiddenLead,
                        visibleDuration: displayDuration
                        , verticalScale: projectState.waveformVerticalScale * clipGainScale,
                        envelope: envelope,
                        drawWindow: projectState.waveformDrawWindow,
                        timelineOrigin: displayStartTime,
                        scalePreview: projectState.waveformScalePreview
                    )
                    .equatable()
                }
            }
            .frame(width: renderWidth, height: renderHeight)
            .scaleEffect(x: clipWidth / renderWidth, y: boxHeight / renderHeight, anchor: .topLeading)
            .frame(width: clipWidth, height: boxHeight, alignment: .topLeading)
            .clipped()
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
                if !isGeometryPreview {
                    trimHandle(cursor: .resizeRight)
                        .gesture(leftTrimGesture)
                }
            }
            .overlay(alignment: .trailing) {
                if !isGeometryPreview {
                    trimHandle(cursor: .resizeLeft)
                        .gesture(rightTrimGesture)
                }
            }
            .overlay(alignment: .top) {
                if !isGeometryPreview {
                    gainHandle
                        .gesture(gainGesture)
                }
            }
            .overlay(alignment: .topLeading) {
                if !fadeInLocked && !isGeometryPreview {
                    fadeInHandle
                        .offset(x: CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond - 8.0, y: -8.0)
                        .gesture(fadeInGesture)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !fadeOutLocked && !isGeometryPreview {
                    fadeOutHandle
                        .offset(x: -CGFloat(clip.fadeOutDuration) * projectState.pixelsPerSecond + 8.0, y: -8.0)
                        .gesture(fadeOutGesture)
                }
            }
            // Curve handles sit on the middle of each fade line; dragging one
            // up or down bends the curve, double-click returns it to Auto.
            .overlay(alignment: .topLeading) {
                let fadeWidth = CGFloat(clip.fadeInDuration) * projectState.pixelsPerSecond
                if !fadeInLocked && !isActiveClip && !isGeometryPreview && fadeWidth >= 16.0 {
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
                if !fadeOutLocked && !isActiveClip && !isGeometryPreview && fadeWidth >= 16.0 {
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
            .opacity(projectState.clipDragPreview?.clipIDs.contains(clip.id) == true ? 0 : 1)
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
                                    dragStartLocationY = value.startLocation.y
                                    projectState.beginClipDragPreview()
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
                            let targetTrackId = projectState.trackID(atTimelineY: value.location.y)
                            dragTargetTrackId = targetTrackId
                            projectState.updateClipDragPreview(
                                verticalOffset: value.location.y - (dragStartLocationY ?? value.startLocation.y),
                                trackDelta: trackDelta(to: targetTrackId)
                            )
                    }
                    .onEnded { _ in
                            if isRangeDragging {
                                isRangeDragging = false
                                projectState.endTimeSelection()
                                return
                            }
                            projectState.endGroupDrag(trackDelta: trackDelta(to: dragTargetTrackId))
                            dragStartTime = nil
                            dragStartLocationX = nil
                            dragTargetTrackId = nil
                            dragStartLocationY = nil
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
            // The take being recorded cannot be moved, trimmed or faded
            // until its file is finalized.
            .allowsHitTesting(!isActiveClip)
            .offset(x: CGFloat(displayStartTime) * projectState.pixelsPerSecond)
        }
    }

    /// Tracks from this clip's track to the one under the pointer; 0 when the
    /// pointer is outside every track.
    private func trackDelta(to destinationTrackId: UUID?) -> Int {
        let tracks = projectState.visibleTracks
        guard let destinationTrackId,
              let from = tracks.firstIndex(where: { $0.id == track.id }),
              let to = tracks.firstIndex(where: { $0.id == destinationTrackId }) else { return 0 }
        return to - from
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

    /// Not drawn: the clip's own edge is the handle, and the pointer turns
    /// into a resize arrow over it.
    private func trimHandle(cursor: HandleCursor) -> some View {
        Color.clear
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .hoverCursor(cursor)
    }

    private var gainHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.95))
            .frame(width: 8.5, height: 5)
            .padding(.vertical, 4)
            .padding(.horizontal, 7.75)
            .contentShape(Rectangle())
            .hoverCursor(.resizeUpDown)
    }

    // Hit area centred on the dot and kept small, so it does not reach
    // down over the trim edge below it.
    private var fadeInHandle: some View {
        Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .hoverCursor(.pointingHand)
    }

    // Hit area centred on the dot and kept small, so it does not reach
    // down over the trim edge below it.
    private var fadeOutHandle: some View {
        Circle()
            .fill(Color.white.opacity(0.95))
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .hoverCursor(.pointingHand)
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
            .hoverCursor(.pointingHand)
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
                // From -∞ the drag starts at the lowest finite gain.
                let start = gainStartDB ?? clip.gainDB
                let base = start.isFinite ? start : AudioClip.silenceGainDB
                clip.setGainDB(base - Double(value.translation.height) * sensitivity)
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
        gainDB.isFinite ? String(format: "%+.1f dB", abs(gainDB) < 0.05 ? 0.0 : gainDB) : "-∞ dB"
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


/// Pointer shape shown while the pointer is over a handle.
private enum HandleCursor {
    /// Clip start: the arrow points right only.
    case resizeRight
    /// Clip end: the arrow points left only.
    case resizeLeft
    /// Clip gain: up and down.
    case resizeUpDown
    case pointingHand

    var nsCursor: NSCursor {
        switch self {
        case .resizeRight: return .resizeRight
        case .resizeLeft: return .resizeLeft
        case .resizeUpDown: return .resizeUpDown
        case .pointingHand: return .pointingHand
        }
    }
}

/// Shows a cursor while the pointer is over the view. A cursor pushed from
/// `onHover` is put back to the arrow at once by the hosting view, so macOS
/// 15 and later use `pointerStyle`, and older systems set it again on every
/// pointer move.
private struct HoverCursor: ViewModifier {
    let cursor: HandleCursor

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(pointerStyle)
        } else {
            content.onContinuousHover { phase in
                switch phase {
                case .active: cursor.nsCursor.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
    }

    @available(macOS 15.0, *)
    private var pointerStyle: PointerStyle {
        switch cursor {
        case .resizeRight: return .columnResize(directions: .trailing)
        case .resizeLeft: return .columnResize(directions: .leading)
        case .resizeUpDown: return .rowResize
        case .pointingHand: return .link
        }
    }
}

private extension View {
    func hoverCursor(_ cursor: HandleCursor) -> some View {
        modifier(HoverCursor(cursor: cursor))
    }
}
