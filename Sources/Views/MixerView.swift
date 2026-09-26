import SwiftUI
import UniformTypeIdentifiers

public struct MixerView: View {
    @ObservedObject public var projectState: ProjectState

    public init(projectState: ProjectState) {
        self.projectState = projectState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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
                Text("Track controls")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(projectState.tracks) { track in
                        MixerChannelView(track: track, projectState: projectState)
                    }
                    ForEach(projectState.fxChannels) { channel in
                        FXChannelView(
                            channel: channel,
                            projectState: projectState,
                            audioEngine: projectState.audioEngine
                        )
                    }
                    MasterChannelView(
                        projectState: projectState,
                        audioEngine: projectState.audioEngine
                    )
                }
                .frame(
                    minWidth: CGFloat(projectState.tracks.count + projectState.fxChannels.count + 1) * 191.0,
                    alignment: .leading
                )
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 340, maxHeight: 370)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
        }
    }
}

private struct MasterChannelView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var audioEngine: AudioEngineManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3, height: 16)
                Text("MASTER")
                    .font(.system(size: 10, weight: .black))
                Spacer()
            }
            MixerLevelMeter(
                peak: audioEngine.masterPeak,
                label: "MASTER"
            )
            Text("FINAL OUTPUT")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.55))

            HStack(spacing: 6) {
                Text("VOLUME")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Slider(
                    value: Binding(
                        get: { projectState.audioEngine.masterVolume },
                        set: { projectState.audioEngine.masterVolume = $0 }
                    ),
                    in: 0.0...1.5
                )
                    .accentColor(.white)
            }

            Menu {
                ForEach(projectState.pluginManager.availablePlugins) { plugin in
                    Button(plugin.menuDisplayName) {
                        projectState.insertMasterPlugin(plugin)
                    }
                }
            } label: {
                Label("Insert", systemImage: "plus.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

            ScrollView(.vertical, showsIndicators: true) {
                ForEach(projectState.masterPlugins) { plugin in
                    HStack(spacing: 4) {
                        Button {
                            projectState.toggleMasterPlugin(plugin.id)
                        } label: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundColor(plugin.enabled ? .green : .gray)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(plugin.enabled ? "Disable plugin" : "Enable plugin")
                        PluginNameButton(
                            name: plugin.menuDisplayName,
                            pluginID: plugin.id,
                            isUnavailable: projectState.audioEngine.isPluginUnavailable(plugin.id),
                            canReorder: false,
                            onOpen: { projectState.audioEngine.openPluginUI(pluginID: plugin.id) },
                            onMove: { sourceID in
                                projectState.moveMasterPlugin(sourceID, before: plugin.id)
                            }
                        )
                        Button {
                            DispatchQueue.main.async {
                                projectState.removeMasterPlugin(plugin.id)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .frame(maxHeight: 90)
            .scrollIndicators(.visible)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 185, height: 320, alignment: .top)
        .background(Color(red: 0.18, green: 0.18, blue: 0.19))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(0.65), lineWidth: 1)
        )
    }
}

private struct MixerChannelView: View {
    @ObservedObject var track: AudioTrack
    @ObservedObject var projectState: ProjectState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(track.color)
                    .frame(width: 3, height: 16)
                Text(track.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            MixerLevelMeter(
                peak: track.isRecordArmed ? track.currentInputPeak : track.currentOutputPeak,
                label: track.isRecordArmed ? "REC IN" : "OUT"
            )

            HStack(spacing: 4) {
                Button("M") { projectState.toggleMute(for: track) }
                    .buttonStyle(MixerButtonStyle(active: track.isMuted, color: .cyan))
                Button("S") { projectState.toggleSolo(for: track) }
                    .buttonStyle(MixerButtonStyle(active: track.isSoloed, color: .yellow))
            }

            HStack(spacing: 6) {
                Text("Vol")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Slider(value: $track.volume, in: 0.0...1.5)
                    .accentColor(.cyan)
                    .onChange(of: track.volume) { _ in
                        projectState.audioEngine.updateMixerLevels(
                            tracks: projectState.tracks,
                            fxChannels: projectState.fxChannels
                        )
                    }
            }

            HStack(spacing: 6) {
                Text("Pan")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Slider(value: $track.pan, in: -1.0...1.0)
                    .accentColor(.green)
                    .onChange(of: track.pan) { _ in
                        projectState.audioEngine.updateMixerLevels(
                            tracks: projectState.tracks,
                            fxChannels: projectState.fxChannels
                        )
                    }
            }

            Menu {
                ForEach(projectState.pluginManager.availablePlugins) { plugin in
                    Button {
                        projectState.insertPlugin(plugin, into: track.id)
                    } label: {
                        HStack {
                            Text(plugin.menuDisplayName)
                        }
                    }
                }
            } label: {
                Label("Insert", systemImage: "plus.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

            if !track.plugins.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(track.plugins) { plugin in
                            HStack(spacing: 4) {
                                Button {
                                    projectState.togglePlugin(plugin.id, on: track.id)
                                } label: {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(plugin.enabled ? .green : .gray)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .accessibilityLabel(plugin.enabled ? "Disable plugin" : "Enable plugin")
                                PluginNameButton(
                                    name: plugin.menuDisplayName,
                                    pluginID: plugin.id,
                                    isUnavailable: projectState.audioEngine.isPluginUnavailable(plugin.id),
                                    canReorder: !projectState.audioEngine.isPlaying && !projectState.audioEngine.isRecording,
                                    onOpen: { projectState.openPluginUI(plugin.id, on: track.id) },
                                    onMove: { sourceID in
                                        projectState.movePlugin(sourceID, before: plugin.id, on: track.id)
                                    }
                                )
                                .help("Open AU plugin window")

                                Button {
                                    projectState.removePlugin(plugin.id, from: track.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }
                .frame(maxHeight: 90)
                .scrollIndicators(.visible)
            }

            if !projectState.fxChannels.isEmpty {
                Divider()
                Text("Sends")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(projectState.fxChannels) { fxChannel in
                            let send = track.fxSends.first(where: { $0.fxChannelID == fxChannel.id })
                            HStack(spacing: 3) {
                                Text(fxChannel.name)
                                    .font(.system(size: 8))
                                    .lineLimit(1)
                                Slider(
                                    value: Binding(
                                        get: { send?.level ?? 0.0 },
                                        set: { projectState.setSend(trackID: track.id, fxChannelID: fxChannel.id, level: $0) }
                                    ),
                                    in: 0.0...1.0
                                )
                                .accentColor(.purple)
                            }
                        }
                    }
                }
                .frame(maxHeight: 90)
                .scrollIndicators(.visible)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 185, height: 320, alignment: .top)
        .background(
            track.id == projectState.selectedTrackId
                ? Color(red: 0.18, green: 0.20, blue: 0.24)
                : Color(red: 0.13, green: 0.14, blue: 0.16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(track.color.opacity(0.45), lineWidth: 1)
        )
        .onTapGesture {
            projectState.selectedTrackId = track.id
        }
    }
}

struct MixerLevelMeter: View {
    let peak: Float
    let label: String

    private var decibels: Double {
        peak > 0.001 ? 20.0 * log10(Double(peak)) : -60.0
    }

    private var meterFraction: CGFloat {
        CGFloat(min(1.0, max(0.0, (decibels + 60.0) / 60.0)))
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
                        meterSegment(.green, fraction: 0.8, activeFraction: meterFraction, totalWidth: geometry.size.width)
                        meterSegment(.yellow, fraction: 0.1, activeFraction: meterFraction, startFraction: 0.8, totalWidth: geometry.size.width)
                        meterSegment(.red, fraction: 0.1, activeFraction: meterFraction, startFraction: 0.9, totalWidth: geometry.size.width)
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

private struct FXChannelView: View {
    @ObservedObject var channel: FXChannel
    @ObservedObject var projectState: ProjectState
    @ObservedObject var audioEngine: AudioEngineManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(channel.color)
                    .frame(width: 3, height: 16)
                Text(channel.name)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Button {
                    projectState.removeFXChannel(id: channel.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(PlainButtonStyle())
            }

            Text("STEREO RETURN")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.purple.opacity(0.8))

            HStack(spacing: 6) {
                Text("Vol")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Slider(value: $channel.volume, in: 0.0...1.5)
                    .accentColor(.purple)
                    .onChange(of: channel.volume) { _ in
                        projectState.audioEngine.updateMixerLevels(
                            tracks: projectState.tracks,
                            fxChannels: projectState.fxChannels
                        )
                    }
            }
            HStack(spacing: 6) {
                Text("Pan")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                Slider(value: $channel.pan, in: -1.0...1.0)
                    .accentColor(.purple)
                    .onChange(of: channel.pan) { _ in
                        projectState.audioEngine.updateMixerLevels(
                            tracks: projectState.tracks,
                            fxChannels: projectState.fxChannels
                        )
                    }
            }

            Menu {
                ForEach(projectState.pluginManager.availablePlugins) { plugin in
                    Button(plugin.menuDisplayName) {
                        projectState.insertPlugin(plugin, intoFX: channel.id)
                    }
                }
            } label: {
                Label("Insert FX", systemImage: "plus.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .disabled(audioEngine.isPlaying || audioEngine.isRecording)

            ScrollView(.vertical, showsIndicators: true) {
                ForEach(channel.plugins) { plugin in
                    HStack(spacing: 4) {
                        Button {
                            projectState.togglePlugin(plugin.id, onFX: channel.id)
                        } label: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundColor(plugin.enabled ? .green : .gray)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(plugin.enabled ? "Disable plugin" : "Enable plugin")
                        PluginNameButton(
                            name: plugin.menuDisplayName,
                            pluginID: plugin.id,
                            isUnavailable: projectState.audioEngine.isPluginUnavailable(plugin.id),
                            canReorder: !audioEngine.isPlaying && !audioEngine.isRecording,
                            onOpen: { projectState.audioEngine.openPluginUI(pluginID: plugin.id) },
                            onMove: { sourceID in
                                projectState.movePlugin(sourceID, before: plugin.id, onFX: channel.id)
                            }
                        )
                        Button {
                            projectState.removePlugin(plugin.id, fromFX: channel.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .frame(maxHeight: 90)
            .scrollIndicators(.visible)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 185, height: 320, alignment: .top)
        .background(Color(red: 0.16, green: 0.12, blue: 0.20))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(channel.color.opacity(0.6), lineWidth: 1)
        )
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
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .black))
            .foregroundColor(active ? .black : color.opacity(0.75))
            .frame(width: 24, height: 18)
            .background(active ? color : Color.white.opacity(0.08))
            .cornerRadius(3)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
