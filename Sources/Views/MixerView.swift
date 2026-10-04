import SwiftUI
import UniformTypeIdentifiers

/// Studio One-style mixer: every strip has three stacked sections (inserts,
/// sends, controls) whose heights are shared, draggable and remembered.
public struct MixerView: View {
    @ObservedObject public var projectState: ProjectState
    @AppStorage("mixer.height") private var mixerHeight: Double = 460
    @AppStorage("mixer.pluginSectionHeight") private var pluginSectionHeight: Double = 110
    @AppStorage("mixer.sendSectionHeight") private var sendSectionHeight: Double = 80
    /// Folded down to its title bar.
    @AppStorage("mixer.collapsed") private var isCollapsed = false
    /// Strip to scroll to once a folded mixer has unfolded.
    @State private var pendingScrollID: UUID?
    @State private var heightDragStart: Double?
    /// How much taller the mixer may get before the tracks above it reach
    /// their minimum height.
    private let growthLimit: Double
    @State private var dragGrowthLimit: Double?

    static let stripWidth: CGFloat = 92
    /// Smallest distance from the divider above the fader section to the
    /// bottom edge of the mixer.
    static let minControlHeight: Double = 220
    /// Resize bar, title row and the two section dividers.
    private static let chromeHeight: Double = 37

    /// Lowest mixer height that keeps the fader section `minControlHeight` tall.
    private var minimumMixerHeight: Double {
        Self.chromeHeight + pluginSectionHeight + sendSectionHeight + Self.minControlHeight
    }

    public init(projectState: ProjectState, growthLimit: Double = .infinity) {
        self.projectState = projectState
        self.growthLimit = growthLimit
    }

    /// The tracks' strips in order, with a line in the folder's colour where
    /// each folder starts. Closed folders hide nothing here.
    private var mixerItems: [MixerItem] {
        projectState.rows.map { row in
            switch row {
            case .folder(let folder): return .folderEdge(folder)
            case .track(let track): return .track(track)
            }
        }
    }

    public var body: some View {
        let height = max(mixerHeight, minimumMixerHeight)
        let layout = MixerSectionLayout(
            pluginHeight: $pluginSectionHeight,
            sendHeight: $sendSectionHeight,
            maxTopHeight: max(64, height - Self.chromeHeight - Self.minControlHeight)
        )
        VStack(spacing: 0) {
            if isCollapsed {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            } else {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 5)
                .overlay(
                    VerticalResizeHandle(
                        onBegin: {
                            heightDragStart = height
                            // Fixed for the drag: the limit shrinks as the
                            // mixer grows into the tracks' space.
                            dragGrowthLimit = growthLimit
                        },
                        onDrag: { translation in
                            let start = heightDragStart ?? height
                            let tallest = min(1000, start + (dragGrowthLimit ?? growthLimit))
                            mixerHeight = max(minimumMixerHeight, min(tallest, start - Double(translation)))
                        },
                        onEnd: {
                            heightDragStart = nil
                            dragGrowthLimit = nil
                        }
                    )
                )
            }

            HStack {
                Button {
                    isCollapsed.toggle()
                } label: {
                    Image(systemName: isCollapsed ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help(isCollapsed ? "Show Mixer" : "Hide Mixer")
                Label("Mixer", systemImage: "slider.vertical.3")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Button {
                    projectState.addFXChannel()
                } label: {
                    Label("Add FX", systemImage: "plus.circle")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 10)
            .frame(height: 22)

            if !isCollapsed {
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(mixerItems) { item in
                            switch item {
                            case .track(let track):
                                TrackStripView(track: track, projectState: projectState, layout: layout)
                                    .id(item.id)
                            case .folderEdge(let folder):
                                // The stack's spacing leaves 2 pt either side.
                                FolderEdgeLine(folder: folder)
                                    .id(item.id)
                            }
                        }
                        if let firstFX = projectState.fxChannels.first {
                            FXEdgeLine(channel: firstFX, channels: projectState.fxChannels)
                        }
                        ForEach(projectState.fxChannels) { channel in
                            FXStripView(
                                channel: channel,
                                projectState: projectState,
                                audioEngine: projectState.audioEngine,
                                layout: layout
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollIndicators(.visible)
                // "Show in Mixer" from a track or folder header.
                .onReceive(projectState.mixerScrollRequests) { id in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .leading)
                    }
                }
                .onAppear {
                    guard let id = pendingScrollID else { return }
                    pendingScrollID = nil
                    // Once the strips are laid out.
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .leading)
                    }
                }
                }
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1)
                MasterStripView(projectState: projectState, audioEngine: projectState.audioEngine, layout: layout)
                    .padding(.horizontal, 4)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 4)
            }
        }
        .frame(height: isCollapsed ? 23 : height)
        // "Show in Mixer" unfolds a folded mixer first.
        .onReceive(projectState.mixerScrollRequests) { id in
            if isCollapsed {
                pendingScrollID = id
                isCollapsed = false
            }
        }
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .contextMenu {
            Button {
                projectState.addFXChannel()
            } label: {
                Label("Add FX", systemImage: "plus.circle")
            }
        }
    }
}

/// Shared heights of the insert and send sections; the control section
/// takes the rest.
struct MixerSectionLayout {
    @Binding var pluginHeight: Double
    @Binding var sendHeight: Double
    let maxTopHeight: Double
}

/// Stacks a strip's three sections with draggable dividers between them.
private struct StripSections<Plugins: View, Sends: View, Controls: View>: View {
    let layout: MixerSectionLayout
    let background: Color
    let border: Color
    @ViewBuilder let plugins: () -> Plugins
    @ViewBuilder let sends: () -> Sends
    @ViewBuilder let controls: () -> Controls
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            plugins()
                .frame(height: CGFloat(layout.pluginHeight), alignment: .top)
                .clipped()
            divider { delta in
                layout.pluginHeight = clampTop(plugin: (dragStart ?? layout.pluginHeight) + delta, send: layout.sendHeight).plugin
            } begin: { layout.pluginHeight }
            sends()
                .frame(height: CGFloat(layout.sendHeight), alignment: .top)
                .clipped()
            divider { delta in
                layout.sendHeight = clampTop(plugin: layout.pluginHeight, send: (dragStart ?? layout.sendHeight) + delta).send
            } begin: { layout.sendHeight }
            controls()
                .frame(maxHeight: .infinity)
        }
        .frame(width: MixerView.stripWidth)
        .background(background)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(border, lineWidth: 1))
    }

    private func clampTop(plugin: Double, send: Double) -> (plugin: Double, send: Double) {
        let pluginValue = max(36, plugin)
        let sendValue = max(28, send)
        let overflow = pluginValue + sendValue - layout.maxTopHeight
        return overflow > 0 ? (pluginValue, max(28, sendValue - overflow)) : (pluginValue, sendValue)
    }

    private func divider(onDrag: @escaping (Double) -> Void, begin: @escaping () -> Double) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 3)
            .padding(.vertical, 1)
            .overlay(
                VerticalResizeHandle(
                    onBegin: { dragStart = begin() },
                    onDrag: { translation in onDrag(Double(translation)) },
                    onEnd: { dragStart = nil }
                )
            )
    }
}

/// Up/down resize handle done in AppKit, so that the resize cursor and the
/// drag always cover exactly the same area (SwiftUI's hover push/pop of the
/// cursor gets out of step and is not shown reliably).
struct VerticalResizeHandle: NSViewRepresentable {
    let onBegin: () -> Void
    /// Distance dragged since the press, positive downwards.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: HandleView) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var startY: CGFloat?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeUpDown.set()
        }

        override func mouseDown(with event: NSEvent) {
            // Screen coordinates: the handle itself moves while dragging.
            startY = NSEvent.mouseLocation.y
            NSCursor.resizeUpDown.set()
            onBegin?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startY else { return }
            NSCursor.resizeUpDown.set()
            onDrag?(startY - NSEvent.mouseLocation.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard startY != nil else { return }
            startY = nil
            onEnd?()
            window?.invalidateCursorRects(for: self)
        }
    }
}

private struct SectionHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.55))
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 4)
        .frame(height: 16)
    }
}

private struct InsertMenu: View {
    let plugins: [TrackPluginDescriptor]
    let disabled: Bool
    let onInsert: (TrackPluginDescriptor) -> Void

    var body: some View {
        Menu {
            ForEach(plugins) { plugin in
                Button(plugin.menuDisplayName) { onInsert(plugin) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .help("Insert plug-in")
    }
}

private struct PluginRow: View {
    let plugin: TrackPluginDescriptor
    let isUnavailable: Bool
    let canReorder: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onMove: (UUID) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onToggle) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(plugin.enabled ? .green : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(plugin.enabled ? "Disable plugin" : "Enable plugin")
            PluginNameButton(
                name: plugin.name.components(separatedBy: ": ").last ?? plugin.name,
                pluginID: plugin.id,
                isUnavailable: isUnavailable,
                canReorder: canReorder,
                onOpen: onOpen,
                onMove: onMove
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(plugin.menuDisplayName)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 4)
        .frame(height: 18)
        .background(Color.white.opacity(plugin.enabled ? 0.08 : 0.03))
        .cornerRadius(2)
    }
}

/// The master fader, observing the master meter and level so only it
/// redraws with them.
private struct MasterFaderColumn: View {
    @ObservedObject var meter: TrackMeter
    @ObservedObject var level: MasterVolumeState
    let audioEngine: AudioEngineManager

    var body: some View {
        FaderColumn(
            gain: Binding(
                get: { level.value },
                set: { audioEngine.masterVolume = $0 }
            ),
            peak: meter.outputPeak,
            tint: Color(white: 0.9),
            onChange: {}
        )
    }
}

/// A track's fader, observing the meter levels so only it redraws with them.
private struct TrackFaderColumn: View {
    @ObservedObject var meter: TrackMeter
    @Binding var gain: Float
    let isRecordArmed: Bool
    let onChange: () -> Void

    var body: some View {
        FaderColumn(
            gain: $gain,
            peak: isRecordArmed
                ? StereoPeak(left: meter.inputPeak, right: meter.inputPeak)
                : meter.outputPeak,
            tint: isRecordArmed ? .red : Color(white: 0.85),
            onChange: onChange
        )
    }
}

/// Fader column: dB labels, fader, L/R meter. Heights align across strips.
private struct FaderColumn: View {
    @Binding var gain: Float
    let peak: StereoPeak
    let tint: Color
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            EditableValueText(text: MixerScale.label(forGain: gain)) { text in
                if let value = MixerScale.gain(parsing: text) {
                    gain = min(MixerGain.maximum, value)
                    onChange()
                }
            }
            .frame(height: 14)
            HStack(spacing: 2) {
                FaderScale().frame(width: 18)
                VolumeFader(gain: $gain, tint: tint, onChange: onChange).frame(width: 26)
                StereoMeter(peak: peak).frame(width: 11)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct PanBlock: View {
    @Binding var pan: Float
    let tint: Color
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            PanControl(pan: $pan, tint: tint, onChange: onChange)
            EditableValueText(
                text: MixerScale.panLabel(pan),
                onCommit: { text in
                    if let value = MixerScale.pan(parsing: text) {
                        pan = value
                        onChange()
                    }
                },
                font: .system(size: 9, weight: .semibold, design: .monospaced)
            )
            .frame(height: 12)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }
}

private struct StripFooter: View {
    let name: String
    let color: Color
    /// The current track's name is shown reversed: black on white.
    var isCurrent = false
    /// When set, the name can be edited by double-clicking it.
    var onRename: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(color).frame(height: 3)
            Group {
                if let onRename {
                    EditableValueText(
                        text: name,
                        onCommit: onRename,
                        font: .system(size: 9, weight: .semibold)
                    )
                    .help("Double-click to rename")
                } else {
                    Text(name)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .foregroundColor(isCurrent ? .black : nil)
            .background(isCurrent ? Color.white : Color.clear)
        }
    }
}

private struct TrackStripView: View {
    @ObservedObject var track: AudioTrack
    @ObservedObject var projectState: ProjectState
    let layout: MixerSectionLayout

    private var isBusy: Bool {
        projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording
    }

    private func applyLevels() {
        projectState.audioEngine.updateMixerLevels(tracks: projectState.tracks, fxChannels: projectState.fxChannels)
    }

    var body: some View {
        StripSections(
            layout: layout,
            background: track.id == projectState.selectedTrackId
                ? Color(red: 0.18, green: 0.20, blue: 0.24)
                : Color(red: 0.13, green: 0.14, blue: 0.16),
            border: track.color.opacity(0.45)
        ) {
            VStack(spacing: 2) {
                SectionHeader(title: "INSERT") {
                    InsertMenu(plugins: projectState.pluginManager.availablePlugins, disabled: isBusy) { plugin in
                        projectState.insertPlugin(plugin, into: track.id)
                    }
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 2) {
                        ForEach(track.plugins) { plugin in
                            PluginRow(
                                plugin: plugin,
                                isUnavailable: projectState.audioEngine.isPluginUnavailable(plugin.id),
                                canReorder: !isBusy,
                                onToggle: { projectState.togglePlugin(plugin.id, on: track.id) },
                                onOpen: { projectState.openPluginUI(plugin.id, on: track.id) },
                                onMove: { sourceID in projectState.movePlugin(sourceID, before: plugin.id, on: track.id) },
                                onRemove: { projectState.removePlugin(plugin.id, from: track.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
        } sends: {
            VStack(spacing: 2) {
                SectionHeader(title: "SEND") { EmptyView() }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(projectState.fxChannels) { fxChannel in
                            let level = track.fxSends.first(where: { $0.fxChannelID == fxChannel.id })?.level ?? 0
                            VStack(spacing: 1) {
                                HStack(spacing: 2) {
                                    Text(fxChannel.name)
                                        .font(.system(size: 8))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    EditableValueText(
                                        text: MixerScale.label(forGain: level),
                                        onCommit: { text in
                                            if let value = MixerScale.gain(parsing: text) {
                                                projectState.setSend(trackID: track.id, fxChannelID: fxChannel.id, level: min(MixerGain.maximum, value))
                                            }
                                        },
                                        font: .system(size: 8, design: .monospaced)
                                    )
                                    .frame(width: 34)
                                }
                                SendLevelBar(gain: level, tint: fxChannel.color) { value in
                                    projectState.setSend(trackID: track.id, fxChannelID: fxChannel.id, level: value)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 5)
                }
            }
        } controls: {
            VStack(spacing: 4) {
                PanBlock(pan: $track.pan, tint: .cyan, onChange: applyLevels)
                HStack(spacing: 4) {
                    Button("M") { projectState.toggleMute(for: track) }
                        .buttonStyle(MixerButtonStyle(active: track.isMuted, held: track.isMutedByFolder, color: .cyan))
                        .disabled(track.isMutedByFolder)
                    Button("S") { projectState.toggleSolo(for: track) }
                        .buttonStyle(MixerButtonStyle(active: track.isSoloed, held: track.isSoloedByFolder, color: .yellow))
                        .disabled(track.isSoloedByFolder)
                }
                .frame(height: 20)
                TrackFaderColumn(
                    meter: track.meter,
                    gain: $track.volume,
                    isRecordArmed: track.isRecordArmed,
                    onChange: applyLevels
                )
                StripFooter(
                    name: track.name,
                    color: track.color,
                    isCurrent: track.id == projectState.selectedTrackId
                )
                    .contentShape(Rectangle())
                    .onTapGesture { projectState.selectedTrackId = track.id }
            }
            .padding(.top, 4)
        }
    }
}

private struct FXStripView: View {
    @ObservedObject var channel: FXChannel
    @ObservedObject var projectState: ProjectState
    @ObservedObject var audioEngine: AudioEngineManager
    let layout: MixerSectionLayout

    private var isBusy: Bool { audioEngine.isPlaying || audioEngine.isRecording }

    private func applyLevels() {
        projectState.audioEngine.updateMixerLevels(tracks: projectState.tracks, fxChannels: projectState.fxChannels)
    }

    var body: some View {
        StripSections(
            layout: layout,
            background: Color(red: 0.14, green: 0.12, blue: 0.19),
            border: channel.color.opacity(0.6)
        ) {
            VStack(spacing: 2) {
                SectionHeader(title: "INSERT") {
                    InsertMenu(plugins: projectState.pluginManager.availablePlugins, disabled: isBusy) { plugin in
                        projectState.insertPlugin(plugin, intoFX: channel.id)
                    }
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 2) {
                        ForEach(channel.plugins) { plugin in
                            PluginRow(
                                plugin: plugin,
                                isUnavailable: audioEngine.isPluginUnavailable(plugin.id),
                                canReorder: !isBusy,
                                onToggle: { projectState.togglePlugin(plugin.id, onFX: channel.id) },
                                onOpen: { audioEngine.openPluginUI(pluginID: plugin.id) },
                                onMove: { sourceID in projectState.movePlugin(sourceID, before: plugin.id, onFX: channel.id) },
                                onRemove: { projectState.removePlugin(plugin.id, fromFX: channel.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
        } sends: {
            // Nothing to show here for an FX channel; the section stays so
            // the strips line up with the track strips.
            Spacer(minLength: 0)
        } controls: {
            VStack(spacing: 4) {
                PanBlock(pan: $channel.pan, tint: channel.color, onChange: applyLevels)
                HStack(spacing: 4) {
                    Button("M") { projectState.toggleMute(for: channel) }
                        .buttonStyle(MixerButtonStyle(active: channel.isMuted, color: .cyan))
                    Button("S") { projectState.toggleSolo(for: channel) }
                        .buttonStyle(MixerButtonStyle(active: channel.isSoloed, color: .yellow))
                }
                .frame(height: 20)
                FaderColumn(gain: $channel.volume, peak: channel.outputStereoPeak, tint: channel.color, onChange: applyLevels)
                StripFooter(name: channel.name, color: channel.color) { newName in
                    projectState.renameFXChannel(id: channel.id, to: newName)
                }
            }
            .padding(.top, 4)
        }
        // Replaces the mixer-wide menu on this strip, so it repeats Add FX.
        .contextMenu {
            Button {
                projectState.addFXChannel()
            } label: {
                Label("Add FX", systemImage: "plus.circle")
            }
            Divider()
            Button(role: .destructive) {
                // Let the context menu close before the modal alert opens.
                DispatchQueue.main.async { projectState.confirmRemoveFXChannel(id: channel.id) }
            } label: {
                Label("Remove \(channel.name)", systemImage: "trash")
            }
        }
    }
}

private struct MasterStripView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var audioEngine: AudioEngineManager
    let layout: MixerSectionLayout

    private var isBusy: Bool { audioEngine.isPlaying || audioEngine.isRecording }

    var body: some View {
        StripSections(
            layout: layout,
            background: Color(red: 0.17, green: 0.17, blue: 0.18),
            border: Color.white.opacity(0.55)
        ) {
            VStack(spacing: 2) {
                SectionHeader(title: "POST") {
                    InsertMenu(plugins: projectState.pluginManager.availablePlugins, disabled: isBusy) { plugin in
                        projectState.insertMasterPlugin(plugin)
                    }
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 2) {
                        ForEach(projectState.masterPlugins) { plugin in
                            PluginRow(
                                plugin: plugin,
                                isUnavailable: audioEngine.isPluginUnavailable(plugin.id),
                                canReorder: !isBusy,
                                onToggle: { projectState.toggleMasterPlugin(plugin.id) },
                                onOpen: { audioEngine.openPluginUI(pluginID: plugin.id) },
                                onMove: { sourceID in projectState.moveMasterPlugin(sourceID, before: plugin.id) },
                                onRemove: {
                                    DispatchQueue.main.async { projectState.removeMasterPlugin(plugin.id) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
        } sends: {
            Color.clear
        } controls: {
            VStack(spacing: 4) {
                Text("STEREO OUT")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(height: 30)
                Color.clear.frame(height: 20)
                MasterFaderColumn(
                    meter: audioEngine.masterMeter,
                    level: audioEngine.masterVolumeState,
                    audioEngine: audioEngine
                )
                StripFooter(name: "MASTER", color: .white)
            }
            .padding(.top, 4)
        }
    }
}

struct MixerLevelMeter: View {
    let peak: Float
    let label: String

    private var decibels: Double {
        peak > 0.001 ? 20.0 * log10(Double(peak)) : -60.0
    }

    // Logic Pro-style scale (measured from its meter): the top 24 dB get
    // almost half the length, lower levels are progressively compressed.
    private static let scale: [(db: Double, fraction: Double)] = [
        (-60, 0.0), (-50, 0.09), (-45, 0.16), (-40, 0.2267), (-35, 0.2967),
        (-30, 0.3667), (-24, 0.4567), (-21, 0.5267), (-18, 0.5967), (-15, 0.6633),
        (-12, 0.73), (-9, 0.7967), (-6, 0.8667), (-3, 0.93), (0, 1.0)
    ]

    static func fraction(forDecibels db: Double) -> CGFloat {
        guard db > scale[0].db else { return 0 }
        guard db < 0 else { return 1 }
        for (lower, upper) in zip(scale, scale.dropFirst()) where db <= upper.db {
            let t = (db - lower.db) / (upper.db - lower.db)
            return CGFloat(lower.fraction + t * (upper.fraction - lower.fraction))
        }
        return 1
    }

    private static let yellowStart = fraction(forDecibels: -12)
    private static let redStart = fraction(forDecibels: -6)

    private var meterFraction: CGFloat {
        Self.fraction(forDecibels: decibels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(label == "REC IN" ? .red : .white.opacity(0.4))
                Spacer()
                Text(peak > 0.001 ? String(format: "%+.0fdB", decibels) : "-∞dB")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(decibels >= -6.0 ? .red : (decibels >= -12.0 ? .yellow : .green))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.7))

                    HStack(spacing: 1) {
                        meterSegment(.green, fraction: Self.yellowStart, activeFraction: meterFraction, totalWidth: geometry.size.width)
                        meterSegment(.yellow, fraction: Self.redStart - Self.yellowStart, activeFraction: meterFraction, startFraction: Self.yellowStart, totalWidth: geometry.size.width)
                        meterSegment(.red, fraction: 1 - Self.redStart, activeFraction: meterFraction, startFraction: Self.redStart, totalWidth: geometry.size.width)
                    }
                    .frame(width: geometry.size.width)
                }
            }
            .frame(height: 7)
        }
        .frame(height: 18)
    }

    private func meterSegment(
        _ color: Color,
        fraction: CGFloat,
        activeFraction: CGFloat,
        startFraction: CGFloat = 0.0,
        totalWidth: CGFloat
    ) -> some View {
        let activeWidth = min(fraction, max(0.0, activeFraction - startFraction)) / fraction
        return ZStack(alignment: .leading) {
            color.opacity(0.18)
            color.opacity(activeWidth > 0.0 ? 1.0 : 0.18)
                .frame(width: totalWidth * fraction * activeWidth)
                .animation(.easeOut(duration: 0.06), value: activeFraction)
        }
        .frame(width: totalWidth * fraction, height: 7)
    }
}

private struct PluginNameButton: View {
    @State private var suppressTapUntil: Date?
    let name: String
    let pluginID: UUID
    let isUnavailable: Bool
    let canReorder: Bool
    let onOpen: () -> Void
    let onMove: (UUID) -> Void

    var body: some View {
        Text(name)
            .font(.system(size: 8))
            .foregroundColor(isUnavailable ? .red : .primary)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture {
                if let suppressTapUntil, Date() < suppressTapUntil {
                    self.suppressTapUntil = nil
                    return
                }
                self.suppressTapUntil = nil
                guard !isUnavailable else { return }
                onOpen()
            }
            .onDrag {
                guard canReorder else { return NSItemProvider() }
                suppressTapUntil = Date().addingTimeInterval(0.5)
                return NSItemProvider(object: pluginID.uuidString as NSString)
            }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                guard canReorder, let provider = providers.first else { return false }
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let value = object as? NSString,
                          let sourceID = UUID(uuidString: value as String) else { return }
                    Task { @MainActor in
                        onMove(sourceID)
                    }
                }
                suppressTapUntil = Date().addingTimeInterval(0.5)
                return true
            }
            .allowsHitTesting(!isUnavailable)
    }
}

private struct MixerButtonStyle: ButtonStyle {
    let active: Bool
    /// Held on by the track's folder: lit grey, and not pressable.
    var held = false
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .black))
            .foregroundColor(active || held ? .black : color.opacity(0.75))
            .frame(width: 24, height: 18)
            .background(held ? Color(white: 0.55) : (active ? color : Color.white.opacity(0.08)))
            .cornerRadius(3)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

/// A channel strip in the mixer, or the line where a folder's tracks start.
private enum MixerItem: Identifiable {
    case track(AudioTrack)
    case folderEdge(TrackFolder)

    var id: UUID {
        switch self {
        case .track(let track): return track.id
        case .folderEdge(let folder): return folder.id
        }
    }
}

/// Vertical line in a folder's colour, as wide as the colour bar on the
/// folder's header in the arranger. Clicking it changes the folder's colour
/// (the header follows, being the same folder).
private struct FolderEdgeLine: View {
    @ObservedObject var folder: TrackFolder

    var body: some View {
        MixerEdgeLine(color: $folder.color, help: "Change folder color")
    }
}

/// The same line, in the first FX channel's colour, where the FX strips
/// start. The colour picked there goes to every FX channel.
private struct FXEdgeLine: View {
    @ObservedObject var channel: FXChannel
    let channels: [FXChannel]

    var body: some View {
        MixerEdgeLine(
            color: Binding(
                get: { channel.color },
                set: { color in
                    for fxChannel in channels {
                        fxChannel.color = color
                    }
                }
            ),
            help: "Change FX color"
        )
    }
}

/// Clicking the line opens the colour palette for what it marks.
private struct MixerEdgeLine: View {
    @Binding var color: Color
    let help: LocalizedStringKey
    @State private var isShowingColorPalette = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isShowingColorPalette = true }
            .help(help)
            .popover(isPresented: $isShowingColorPalette, arrowEdge: .trailing) {
                TrackColorPalette(color: $color) {
                    isShowingColorPalette = false
                }
            }
    }
}
