import SwiftUI
import Combine


public struct ArrangerView: View {
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
    @ObservedObject public var projectState: ProjectState
    @ObservedObject public var audioEngine: AudioEngineManager
    /// Bookkeeping for following `timelineScrollTime` (see `ScrollFollow`).
    @State private var scrollFollow = ScrollFollow()
    /// The tracks' horizontal scroll view, which horizontal scrolls over the
    /// ruler are passed to.
    @State private var timelineScrollView = WeakScrollView()
    /// Track or folder being dragged by its header to a new place in the
    /// order, how far it has been dragged, and where the pointer is (in the
    /// header column, which lines up with the rows).
    @State private var reorderRowID: UUID?
    @State private var reorderTranslation: CGSize = .zero
    @State private var reorderPointerY: CGFloat = 0
    /// While playing or recording, how far the timeline reaches for the
    /// playhead: raised in steps as the playhead moves (so this view, which
    /// does not observe the playhead, is rebuilt only now and then) and
    /// cleared on stop, so the timeline goes back to the song's length.
    @State private var playheadExtentTime: Double = 0
    /// When stopped, a playhead left past the song's end (else 0); kept here
    /// rather than read from the engine so that a rewind narrows the
    /// timeline again (this view does not observe the playhead).
    @State private var parkedPlayheadTime: Double = 0

    /// The song's length: its clips and end flag, at least a minute. Moving
    /// the playhead (clicking the ruler, playing on) does not lengthen it.
    private func songLength() -> Double {
        let clipEndTime = projectState.tracks
            .flatMap { $0.clips }
            .map { $0.startTime + $0.duration }
            .max() ?? 0.0
        return max(60.0, clipEndTime + 5.0, (projectState.songEndTime ?? 0.0) + 5.0)
    }

    /// The timeline's width: the song, and while playing or recording a
    /// screen past the playhead (where auto-scroll puts the view: the ruler
    /// is offset by `timelineScrollTime` while the tracks scroll for real,
    /// and a scroll clamped at the content's end would leave the ruler
    /// drawn ahead of the tracks). When stopped it also reaches a playhead
    /// left past the song's end. Never narrower than the view, so the ruler
    /// always runs to the right edge without the song getting longer.
    private func timelineWidth(viewportWidth: CGFloat) -> CGFloat {
        let pixelsPerSecond = max(0.001, projectState.pixelsPerSecond)
        let visibleWidth = max(1.0, viewportWidth - ArrangerLayout.headerColumnWidth)
        let length = max(songLength(), parkedPlayheadTime, playheadExtentTime)
        return max(visibleWidth, CGFloat(length) * pixelsPerSecond)
    }

    /// Darkens the ruler or lanes past the song's end: the part that is
    /// only there to fill the view (or reach the playhead), not the song.
    private func pastSongShade(timelineWidth: CGFloat) -> some View {
        let songEndX = CGFloat(songLength()) * projectState.pixelsPerSecond
        return Rectangle()
            .fill(Color.black.opacity(0.28))
            .frame(width: max(0, timelineWidth - songEndX))
            .frame(maxHeight: .infinity)
            .offset(x: songEndX)
            .allowsHitTesting(false)
    }

    public init(projectState: ProjectState, audioEngine: AudioEngineManager) {
        self.projectState = projectState
        self.audioEngine = audioEngine
    }

    /// Scrolls the tracks' horizontal scroll view to `offset` (clamped to
    /// its content).
    private func setTrackScrollOffset(_ offset: CGFloat) {
        guard let scrollView = timelineScrollView.scrollView else { return }
        let clipView = scrollView.contentView
        let documentWidth = scrollView.documentView?.frame.width ?? 0
        let maxOffset = max(0, documentWidth - clipView.bounds.width)
        let x = min(max(0, offset), maxOffset)
        guard abs(clipView.bounds.origin.x - x) >= 0.5 else { return }
        clipView.scroll(to: NSPoint(x: x, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    // Waveform drawn inside the drag preview so the clip content stays visible while moving
    @ViewBuilder
    private func clipDragPreviewWaveform(clip: AudioClip, isStereo: Bool, color: Color, landingTrack: AudioTrack) -> some View {
        let verticalScale = projectState.waveformVerticalScale * CGFloat(pow(10.0, clip.gainDB / 20.0))
        // Faded and crossfaded as it would be where it lands.
        let layerSpans = ClipLayering.spans(for: projectState.layeringClips(for: landingTrack))
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
        let anchorOffset = max(0.0, location.x - ArrangerLayout.headerColumnWidth)
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
        let isOverRuler = location.y < 32.0 && location.x >= ArrangerLayout.headerColumnWidth
        // The ruler is outside the tracks' scroll view, so horizontal
        // scrolling there (Shift + wheel, trackpad swipe) is passed to it.
        if isOverRuler,
           modifiers.isEmpty || modifiers == [.shift],
           abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || modifiers == [.shift],
           let scrollView = timelineScrollView.scrollView {
            scrollView.scrollWheel(with: event)
            return true
        }
        if modifiers.isEmpty {
            guard isOverRuler else { return false }
            var delta = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                delta /= 10.0
            }
            // Leave horizontal swipes alone.
            guard delta != 0 else { return false }
            projectState.setPixelsPerSecond(
                projectState.pixelsPerSecond * pow(1.1, delta),
                anchorOffset: location.x - ArrangerLayout.headerColumnWidth
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
            projectState.setTrackHeightScale(projectState.trackHeightScale + delta * 0.1)
        } else {
            let current = projectState.waveformScalePreview.target ?? projectState.waveformVerticalScale
            projectState.previewWaveformVerticalScale(current * pow(1.1, delta))
        }
        return true
    }

    /// The dragged clips, each drawn from its own track moved by the
    /// pointer's vertical travel, so the selection moves as one block.
    private func clipDragPreviews(_ preview: ClipDragPreview) -> some View {
        let tracks = projectState.visibleTracks
        let items: [(clip: AudioClip, track: AudioTrack, landing: AudioTrack)] = tracks.indices.flatMap { index in
            let track = tracks[index]
            let landingIndex = index + preview.trackDelta
            let landing = tracks.indices.contains(landingIndex) ? tracks[landingIndex] : track
            return track.clips
                .filter { preview.clipIDs.contains($0.id) }
                .map { (clip: $0, track: track, landing: landing) }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.clip.id) { item in
                let width = max(4.0, CGFloat(item.clip.duration) * projectState.pixelsPerSecond)
                let height = max(20.0, rowHeight(item.track) - 4.0)
                let isStereo = item.track.channelMode == .stereo
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.track.color.opacity(0.18))
                    .frame(width: width, height: height)
                    .overlay {
                        clipDragPreviewWaveform(
                            clip: item.clip,
                            isStereo: isStereo,
                            color: item.track.color,
                            landingTrack: item.landing
                        )
                        .opacity(item.clip.isMuted ? 0.35 : 0.85)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(
                                item.track.color.opacity(0.95),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                            )
                    )
                    .position(
                        x: CGFloat(item.clip.startTime) * projectState.pixelsPerSecond + width / 2.0,
                        y: projectState.trackTopY(for: item.track.id) + 2.0 + preview.verticalOffset + height / 2.0
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func rowHeight(_ track: AudioTrack) -> CGFloat {
        TrackHeaderView.rowHeight(for: track) * projectState.trackHeightScale
    }

    /// Rows that move with the current header drag: the dragged track, or the
    /// dragged folder with its tracks.
    private func reorderMovingIDs() -> Set<UUID> {
        guard let draggedID = reorderRowID else { return [] }
        guard let folder = projectState.folder(withID: draggedID) else { return [draggedID] }
        return Set([draggedID] + projectState.tracks(in: folder).map(\.id))
    }

    /// Where the dragged track or folder would land if dropped now: at the
    /// gap between the rows nearest the pointer, or into a closed folder
    /// when a track is held over that folder's header.
    ///
    /// Below the last track of a folder (or below an empty folder's header)
    /// a track could go either inside the folder or after it: inside while
    /// the pointer is still over that last row, outside once it is over the
    /// row below.
    private func reorderDropTarget() -> RowDropTarget? {
        guard let draggedID = reorderRowID else { return nil }
        let moving = reorderMovingIDs()
        var others: [(row: ArrangerRow, top: CGFloat, height: CGFloat)] = []
        var y: CGFloat = 0
        for row in projectState.visibleRows {
            let height = projectState.rowHeight(row)
            if !moving.contains(row.id) {
                others.append((row, y, height))
            }
            y += height + 1
        }
        let pointerY = reorderPointerY
        let draggedTrack = projectState.tracks.first { $0.id == draggedID }

        if draggedTrack != nil {
            for entry in others {
                guard let folder = entry.row.folder, !folder.isOpen,
                      pointerY >= entry.top + entry.height * 0.25,
                      pointerY <= entry.top + entry.height * 0.75 else { continue }
                let index = others.firstIndex { $0.row.id == folder.id }! + 1
                return RowDropTarget(
                    beforeRowID: others.indices.contains(index) ? others[index].row.id : nil,
                    folderID: folder.id,
                    lineY: entry.top,
                    isIndented: false,
                    closedFolderID: folder.id
                )
            }
        }

        var best: (target: RowDropTarget, distance: CGFloat)?
        for gap in 0...others.count {
            let above = gap > 0 ? others[gap - 1].row : nil
            let below = gap < others.count ? others[gap] : nil
            let lineY = below.map { $0.top - 0.5 }
                ?? others.last.map { $0.top + $0.height + 0.5 }
                ?? 0
            var folderID: UUID?
            if draggedTrack != nil {
                if let belowFolderID = below?.row.track?.folderID {
                    folderID = belowFolderID
                } else {
                    // Right below an open folder's header or its last track.
                    let edgeFolderID: UUID? = above?.folder.flatMap { $0.isOpen ? $0.id : nil }
                        ?? above?.track?.folderID
                    if let edgeFolderID, pointerY < lineY {
                        folderID = edgeFolderID
                    }
                }
            } else if let below, below.row.track?.folderID != nil {
                // A folder lands only above a folder or a track out of any
                // folder, since folders do not nest.
                continue
            }
            let target = RowDropTarget(
                beforeRowID: below?.row.id,
                folderID: folderID,
                lineY: lineY,
                isIndented: folderID != nil,
                closedFolderID: nil
            )
            let distance = abs(pointerY - lineY)
            if best == nil || distance < best!.distance {
                best = (target, distance)
            }
        }
        return best?.target
    }

    /// The line (or closed folder outline) showing where a dragged header
    /// will land; indented when a track will go into a folder.
    private func dropIndicator(_ target: RowDropTarget) -> some View {
        let x = target.isIndented ? ArrangerLayout.folderIndent : 0
        return Group {
            if target.closedFolderID != nil {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: ArrangerLayout.headerWidth, height: TrackFolder.rowHeight)
                    .offset(y: target.lineY)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(width: ArrangerLayout.headerWidth, height: 3)
                    .offset(x: x, y: target.lineY - 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    /// Dragging a track or folder header moves it in the order; a folder
    /// takes its tracks along. Buttons, menus and the resize strip on the
    /// header keep their own gestures.
    private func reorderGesture(for row: ArrangerRow) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("trackHeaderColumn"))
            .onChanged { value in
                if reorderRowID == nil {
                    reorderRowID = row.id
                    // A folder never becomes the current track.
                    if let track = row.track {
                        projectState.selectedTrackId = track.id
                    }
                }
                guard reorderRowID == row.id else { return }
                reorderTranslation = value.translation
                reorderPointerY = value.location.y
            }
            .onEnded { _ in
                guard reorderRowID == row.id else { return }
                let target = reorderDropTarget()
                withAnimation(.easeOut(duration: 0.18)) {
                    if let target {
                        switch row {
                        case .track(let track):
                            projectState.moveTrack(
                                id: track.id,
                                beforeRowID: target.beforeRowID,
                                folderID: target.folderID
                            )
                        case .folder(let folder):
                            projectState.moveFolder(id: folder.id, beforeRowID: target.beforeRowID)
                        }
                    }
                    reorderRowID = nil
                    reorderTranslation = .zero
                }
            }
    }

    /// Right-click menu of a track or folder header. A track becomes the
    /// current one (a folder never does). Additions go above the clicked row,
    /// or for a folder, a track goes in as its first; a track inside a folder
    /// offers no folder, since folders do not nest.
    private func headerMenu(for row: ArrangerRow) -> NSMenu {
        if let track = row.track {
            projectState.selectedTrackId = track.id
        }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Add Track"), symbol: "plus.rectangle", enabled: true) {
            projectState.addTrack(above: row.id)
        })
        if row.track?.folderID == nil {
            menu.addItem(ClosureMenuItem(String(localized: "Add Folder"), symbol: "folder.badge.plus", enabled: true) {
                projectState.addFolder(above: row.id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Show in Mixer"), symbol: "slider.vertical.3", enabled: true) {
            projectState.mixerScrollRequests.send(row.id)
        })
        return menu
    }

    private func reorderLift(for row: ArrangerRow, moving: Set<UUID>, color: Color) -> ReorderLift {
        let isMoving = moving.contains(row.id)
        return ReorderLift(
            isDragged: isMoving,
            offset: isMoving ? reorderTranslation.height : 0,
            color: color
        )
    }

    /// Shaded band over each track in the time selection.
    private func timeSelectionHighlight(_ selection: TimeSelection) -> some View {
        let x = CGFloat(selection.start) * projectState.pixelsPerSecond
        let width = max(1.0, CGFloat(selection.end - selection.start) * projectState.pixelsPerSecond)
        let selectedTracks = projectState.visibleTracks.filter { selection.trackIDs.contains($0.id) }
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

    /// Scrolls the tracks to a new `timelineScrollTime`, unless the change
    /// came from the tracks' own scrolling.
    private func followScrollTime(_ time: Double, proxy horizontalProxy: ScrollViewProxy) {
        let requested = CGFloat(time) * projectState.pixelsPerSecond
        // Nothing to do when the tracks are already there (the change came
        // from their own scrolling). Compared in points, not as a time: after
        // a zoom the same time is a different offset.
        if let clipView = timelineScrollView.scrollView?.contentView {
            guard abs(clipView.bounds.origin.x - requested) >= 0.5 else { return }
        } else {
            guard time != scrollFollow.scrolledTime else { return }
        }
        scrollFollow.requestedOffset = requested
        guard timelineScrollView.scrollView != nil else {
            withAnimation(nil) {
                horizontalProxy.scrollTo(
                    "savedScrollPosition-\(projectState.scrollRestoreRevision)",
                    anchor: .leading
                )
            }
            Task { @MainActor in
                await Task.yield()
                await Task.yield()
                if scrollFollow.requestedOffset == requested {
                    scrollFollow.requestedOffset = nil
                }
            }
            return
        }
        // Scroll the clip view itself: `scrollTo`
        // finds its target in the layout of the
        // moment, which right after a stop and
        // rewind can still be the old one (the
        // timeline width follows the playhead),
        // leaving the view where it was.
        setTrackScrollOffset(requested)
        DispatchQueue.main.async {
            guard scrollFollow.requestedOffset == requested else { return }
            // Again once the new width is laid
            // out, which may have clamped it.
            timelineScrollView.scrollView?.window?.contentView?.layoutSubtreeIfNeeded()
            setTrackScrollOffset(requested)
        }
        // After a zoom the content may widen only some layout passes later;
        // until then the offset is clamped short of the target, and it is
        // applied again whenever the content resizes (see
        // `ScrollOffsetObserver`). If it is still not reached after this
        // wait, the ruler takes the tracks' real position instead, so the
        // two never stay apart.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard scrollFollow.requestedOffset == requested else { return }
            scrollFollow.requestedOffset = nil
            guard let clipView = timelineScrollView.scrollView?.contentView else { return }
            let offset = clipView.bounds.origin.x
            guard abs(offset - requested) >= 1.0 else { return }
            let actualTime = max(0.0, Double(offset / projectState.pixelsPerSecond))
            scrollFollow.scrolledTime = actualTime
            projectState.timelineScrollTime = actualTime
        }
    }

    public var body: some View {
        GeometryReader { viewport in
            let timelineWidth = timelineWidth(viewportWidth: viewport.size.width)
            // Worked out once per update; a closed folder's tracks are not
            // drawn at all.
            let visibleRows = projectState.visibleRows
            let movingIDs = reorderMovingIDs()
            let dropTarget = reorderDropTarget()
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack {
                        Text("TRACKS (\(projectState.tracks.count))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Menu {
                            Button("Add Track") { projectState.addTrack() }
                            Button("Add Folder") { projectState.addFolder() }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 22, height: 20)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(4)
                        }
                        .menuStyle(BorderlessButtonMenuStyle())
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add Track or Folder")
                    }
                    .padding(.horizontal, 10)
                    .frame(width: ArrangerLayout.headerColumnWidth, height: 32)
                    .background(Color(red: 0.15, green: 0.16, blue: 0.18))
                    .zIndex(1)

                    TimelineRulerView(
                        audioEngine: audioEngine,
                        projectState: projectState,
                        width: timelineWidth
                    )
                    .overlay(alignment: .topLeading) {
                        pastSongShade(timelineWidth: timelineWidth)
                    }
                    .modifier(TimelineScrollOffset(
                        scroll: projectState.timelineScroll,
                        pixelsPerSecond: projectState.pixelsPerSecond
                    ))
                    .frame(width: max(0, viewport.size.width - ArrangerLayout.headerColumnWidth), height: 32, alignment: .leading)
                    .clipped()
                }

                ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleRows) { row in
                                switch row {
                                case .track(let track):
                                    let folder = projectState.folder(withID: track.folderID)
                                    TrackHeaderView(
                                        track: track,
                                        projectState: projectState,
                                        isSelected: projectState.selectedTrackId == track.id,
                                        isRecording: audioEngine.isRecording
                                    )
                                    // TrackHeaderView sets its own size: it observes
                                    // the track, so its height follows a resize drag
                                    // that this view would not see.
                                    .gesture(reorderGesture(for: row))
                                    .background(LaneMenuMonitor { _ in headerMenu(for: row) })
                                    .modifier(reorderLift(for: row, moving: movingIDs, color: track.color))
                                    .padding(.leading, folder == nil ? 0 : ArrangerLayout.folderIndent)
                                    .background(alignment: .leading) {
                                        if let folder {
                                            FolderIndentGuide(folder: folder)
                                                .offset(y: movingIDs.contains(track.id) ? reorderTranslation.height : 0)
                                        }
                                    }
                                case .folder(let folder):
                                    FolderHeaderView(folder: folder, projectState: projectState)
                                        .gesture(reorderGesture(for: row))
                                        .background(LaneMenuMonitor { _ in headerMenu(for: row) })
                                        .modifier(reorderLift(for: row, moving: movingIDs, color: folder.color))
                                }
                            }
                        }
                        .frame(width: ArrangerLayout.headerColumnWidth, alignment: .topLeading)
                        .overlay(alignment: .topLeading) {
                            if let target = dropTarget {
                                dropIndicator(target)
                            }
                        }
                        .coordinateSpace(name: "trackHeaderColumn")
                    }
                    .frame(width: ArrangerLayout.headerColumnWidth, alignment: .top)
                    .background(Color(red: 0.12, green: 0.13, blue: 0.15))

                    ScrollViewReader { horizontalProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        ForEach(visibleRows) { row in
                                            switch row {
                                            case .track(let track):
                                                WaveformLaneView(
                                                    track: track,
                                                    projectState: projectState,
                                                    timelineWidth: timelineWidth
                                                )
                                                .modifier(reorderLift(for: row, moving: movingIDs, color: track.color))
                                            case .folder(let folder):
                                                FolderLaneView(timelineWidth: timelineWidth)
                                                    .modifier(reorderLift(for: row, moving: movingIDs, color: folder.color))
                                            }
                                        }
                                    }
                                    .overlay(alignment: .topLeading) {
                                        pastSongShade(timelineWidth: timelineWidth)
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
                                        clipDragPreviews(preview)
                                    }

                                    let playheadX = CGFloat(audioEngine.currentTime) * projectState.pixelsPerSecond
                                    let totalHeight = visibleRows.reduce(CGFloat.zero) { height, row in
                                        height + projectState.rowHeight(row)
                                    } + CGFloat(max(0, visibleRows.count - 1))

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
                                    PlayheadLine(
                                        clock: audioEngine.transportClock,
                                        color: PlayheadBall.color(for: audioEngine),
                                        pixelsPerSecond: projectState.pixelsPerSecond,
                                        height: max(300, totalHeight)
                                    )
                                }
                                // Read from AppKit: a SwiftUI geometry
                                // preference is not updated while the user
                                // scrolls with the wheel or trackpad.
                                .background(ScrollOffsetObserver(scrollView: timelineScrollView, onContentResize: {
                                    // A scroll clamped by the old width
                                    // goes on to its target.
                                    if let requested = scrollFollow.requestedOffset {
                                        setTrackScrollOffset(requested)
                                    }
                                }) { offset in
                                    if projectState.timelineScroll.trackOffset != offset {
                                        projectState.timelineScroll.trackOffset = offset
                                    }
                                    guard !projectState.isRestoringScrollPosition else { return }
                                    if let requested = scrollFollow.requestedOffset {
                                        guard abs(offset - requested) < 1.0 else { return }
                                        scrollFollow.requestedOffset = nil
                                    }
                                    let time = max(
                                        0.0,
                                        Double(offset / projectState.pixelsPerSecond)
                                    )
                                    scrollFollow.scrolledTime = time
                                    projectState.timelineScrollTime = time
                                })
                                // Called right after the value changes, before
                                // anything is drawn, so the tracks move in the
                                // same frame as the ruler; and not observed, so
                                // scrolling does not rebuild this whole view.
                                .onAppear {
                                    projectState.timelineScroll.onChange = { time in
                                        followScrollTime(time, proxy: horizontalProxy)
                                    }
                                    projectState.timelineViewportWidth = max(1.0, viewport.size.width - ArrangerLayout.headerColumnWidth)
                                    projectState.refreshDrawWindow(force: true)
                                }
                                .onChange(of: viewport.size.width) { width in
                                    projectState.timelineViewportWidth = max(1.0, width - ArrangerLayout.headerColumnWidth)
                                }
                                // Received, not observed: the playhead moves 60
                                // times a second and this view stays as it is.
                                .onReceive(audioEngine.transportClock.$time) { time in
                                    let visibleWidth = max(1.0, viewport.size.width - ArrangerLayout.headerColumnWidth)
                                    let visibleDuration = max(
                                        1.0,
                                        Double(visibleWidth) / Double(projectState.pixelsPerSecond)
                                    )
                                    guard audioEngine.isPlaying || audioEngine.isRecording else {
                                        let parked = time > songLength() ? time : 0.0
                                        if parked != parkedPlayheadTime { parkedPlayheadTime = parked }
                                        return
                                    }
                                    // Only while the transport runs; cleared
                                    // on stop (see `playheadExtentTime`).
                                    if time + visibleDuration + 5.0 > playheadExtentTime {
                                        playheadExtentTime = time + visibleDuration + 30.0
                                    }
                                    guard projectState.autoScrollEnabled else { return }
                                    let rightMarginTime = visibleDuration * 0.1
                                    let scrollTriggerTime = projectState.timelineScrollTime + visibleDuration - rightMarginTime
                                    if time >= scrollTriggerTime {
                                        // Keep the ruler, waveform, and bottom
                                        // scrollbar driven by the same offset.
                                        // The track view follows through the
                                        // timelineScrollTime change above.
                                        projectState.timelineScrollTime = max(
                                            0.0,
                                            time - rightMarginTime
                                        )
                                    }
                                }
                                // On stop the timeline goes back to the
                                // song (and a playhead left past its end).
                                .onChange(of: audioEngine.isPlaying || audioEngine.isRecording) { running in
                                    guard !running else { return }
                                    let time = audioEngine.currentTime
                                    parkedPlayheadTime = time > songLength() ? time : 0.0
                                    playheadExtentTime = 0
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
                                // Track geometry, the marquee and the time
                                // selection are all measured in this space.
                                .coordinateSpace(name: "timelineScroll")
                            }
                            .frame(width: max(timelineWidth, viewport.size.width - ArrangerLayout.headerColumnWidth), alignment: .leading)
                            // Down to the bottom of the visible area (less the
                            // ruler and scroll bar rows), so a lane dragged
                            // below the last track is not clipped away.
                            .frame(minHeight: max(0, viewport.size.height - 52), alignment: .topLeading)
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
                TimelineScrollSlider(
                    scroll: projectState.timelineScroll,
                    projectState: projectState,
                    range: 0.0...max(
                        0.0,
                        Double(timelineWidth / projectState.pixelsPerSecond)
                            - Double(max(1.0, (viewport.size.width - ArrangerLayout.headerColumnWidth) / projectState.pixelsPerSecond))
                    ),
                    tint: .cyan
                )
            }
            .padding(.leading, ArrangerLayout.headerColumnWidth)
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

/// Lifts the row of a track dragged to a new place in the order above the
/// others, and moves each row by its offset during the drag.
private struct ReorderLift: ViewModifier {
    let isDragged: Bool
    let offset: CGFloat
    let color: Color

    func body(content: Content) -> some View {
        content
            .overlay(
                Rectangle()
                    .stroke(color.opacity(isDragged ? 0.9 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            )
            // Only while dragged, so the lanes don't pay for a shadow pass.
            .background {
                if isDragged {
                    Rectangle()
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 3)
                }
            }
            .offset(y: offset)
            // The dragged row tracks the pointer; the others glide aside.
            .animation(isDragged ? nil : .easeInOut(duration: 0.15), value: offset)
            .zIndex(isDragged ? 1 : 0)
    }
}

/// Where a header dragged in the track list would land.
private struct RowDropTarget {
    /// Row it goes in front of; nil for the end of the list.
    let beforeRowID: UUID?
    /// Folder a dragged track goes into; nil for out of any folder.
    let folderID: UUID?
    /// Height of the drop line, in the header column.
    let lineY: CGFloat
    let isIndented: Bool
    /// Closed folder a track is held over, to go in at its end.
    let closedFolderID: UUID?
}

/// A thin line in the folder's colour beside the tracks indented under it.
private struct FolderIndentGuide: View {
    @ObservedObject var folder: TrackFolder

    var body: some View {
        Rectangle()
            .fill(folder.color.opacity(0.6))
            .frame(width: 2)
            .padding(.leading, ArrangerLayout.folderIndent / 2 - 1)
            .allowsHitTesting(false)
    }
}

/// A folder's lane: empty, with the same edges as a track's lane. It takes
/// no clicks or drops.
private struct FolderLaneView: View {
    let timelineWidth: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(red: 0.10, green: 0.11, blue: 0.13))
            .frame(width: timelineWidth, height: TrackFolder.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture {}
    }
}

/// Background, ticks and labels of the ruler. Its own view so that pointer
/// tracking in the ruler (for the flag menu) does not redraw it.
private struct RulerTicks: View {
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
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
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
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

            PlayheadBall(
                audioEngine: audioEngine,
                clock: audioEngine.transportClock,
                pixelsPerSecond: projectState.pixelsPerSecond
            )
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
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
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
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
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
/// The playhead line over the tracks, observing only the playhead.
private struct PlayheadLine: View {
    @ObservedObject var clock: TransportClock
    let color: Color
    let pixelsPerSecond: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: height)
            .offset(x: CGFloat(clock.time) * pixelsPerSecond - 1)
            .allowsHitTesting(false)
    }
}

private struct PlayheadBall: View {
    @ObservedObject var audioEngine: AudioEngineManager
    @ObservedObject var clock: TransportClock
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
        let x = CGFloat(clock.time) * pixelsPerSecond
        let lift: CGFloat
        if audioEngine.isPlaying || audioEngine.isRecording {
            let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
            let phase = (max(0.0, clock.time) / beatDuration).truncatingRemainder(dividingBy: 1.0)
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

/// Horizontal slider that only moves when its knob is dragged; clicks on the
/// track do nothing, so a click near the mixer border cannot jump the view.
/// Shifts the ruler by the scroll position, observing only that.
private struct TimelineScrollOffset: ViewModifier {
    @ObservedObject var scroll: TimelineScrollPosition
    let pixelsPerSecond: CGFloat

    func body(content: Content) -> some View {
        // The tracks' real offset, so the ball and the playhead line agree
        // even mid-zoom (see `TimelineScrollPosition.trackOffset`).
        content.offset(x: -(scroll.trackOffset ?? CGFloat(scroll.time) * pixelsPerSecond))
    }
}

/// The horizontal scroll knob, observing only the scroll position.
private struct TimelineScrollSlider: View {
    @ObservedObject var scroll: TimelineScrollPosition
    let projectState: ProjectState
    let range: ClosedRange<Double>
    let tint: Color

    var body: some View {
        KnobOnlySlider(
            value: Binding(
                get: { scroll.time },
                set: { projectState.timelineScrollTime = $0 }
            ),
            range: range,
            tint: tint
        )
    }
}

private struct KnobOnlySlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    @State private var dragStartValue: Double?

    private static let knobSize: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - Self.knobSize)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            let knobX = CGFloat(fraction) * travel
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 4)
                    .padding(.horizontal, Self.knobSize / 2)
                Capsule()
                    .fill(tint)
                    .frame(width: knobX, height: 4)
                    .padding(.leading, Self.knobSize / 2)
                Circle()
                    .fill(Color(white: 0.92))
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .offset(x: knobX)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStartValue ?? value
                                if dragStartValue == nil { dragStartValue = start }
                                let delta = Double(drag.translation.width / travel) * span
                                value = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragStartValue = nil }
                    )
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: Self.knobSize)
    }
}

/// Watches scroll-wheel and trackpad pinch events that land inside the
/// arranger and hands them to `onWheel` / `onMagnify`; events they consume do
/// not reach the scroll views.
private final class WeakScrollView {
    weak var scrollView: NSScrollView?
}

/// What the arranger keeps while following `timelineScrollTime`. A plain
/// object, not `@State` values: these are written on every zoom step and
/// every scroll, and as state each write rebuilt the whole arranger once more
/// on top of the update the zoom itself needs.
private final class ScrollFollow {
    /// Scroll time last read from the track scroll view, so that a change
    /// coming from the user's own scrolling is not sent back to it.
    var scrolledTime: Double?
    /// Offset a scroll is heading for; offsets reported before it lands are
    /// stale.
    var requestedOffset: CGFloat?
}

/// Reports the horizontal offset of the scroll view it sits in whenever that
/// scroll view scrolls, however the scroll was made.
private struct ScrollOffsetObserver: NSViewRepresentable {
    let scrollView: WeakScrollView
    /// Called when the scrolled content changes size.
    var onContentResize: () -> Void = {}
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.scrollViewBox = scrollView
        view.onScroll = onScroll
        view.onContentResize = onContentResize
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onContentResize = onContentResize
    }

    final class ObserverView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onContentResize: (() -> Void)?
        var scrollViewBox: WeakScrollView?
        private weak var clipView: NSClipView?
        private weak var documentView: NSView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let clipView {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: clipView
                )
                self.clipView = nil
            }
            if let documentView {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.frameDidChangeNotification, object: documentView
                )
                self.documentView = nil
            }
            guard window != nil, let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            scrollViewBox?.scrollView = scrollView
            clipView = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
            if let document = scrollView.documentView {
                documentView = document
                document.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(documentFrameDidChange),
                    name: NSView.frameDidChangeNotification,
                    object: document
                )
            }
        }

        @objc private func documentFrameDidChange() {
            onContentResize?()
        }

        @objc private func boundsDidChange() {
            guard let clipView else { return }
            onScroll?(clipView.bounds.origin.x)
        }
    }
}

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
