import SwiftUI

public struct TrackHeaderView: View {
    @ObservedObject public var track: AudioTrack
    @ObservedObject public var projectState: ProjectState
    public let isSelected: Bool

    @State private var isEditingName: Bool = false
    @State private var resizeStartHeight: CGFloat?

    public init(track: AudioTrack, projectState: ProjectState, isSelected: Bool) {
        self.track = track
        self.projectState = projectState
        self.isSelected = isSelected
    }

    public static func rowHeight(for track: AudioTrack) -> CGFloat {
        max(120.0, track.trackHeight) * 1.0
    }

    public var body: some View {
        let meterPeak = track.isRecordArmed ? track.currentInputPeak : track.currentOutputPeak
        HStack(spacing: 0) {
            // Track Color Bar
            Rectangle()
                .fill(track.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                // Top Row: Track Name & Channel Mode & Delete
                HStack(spacing: 6) {
                    if isEditingName {
                        TextField("Track Name", text: $track.name, onCommit: {
                            isEditingName = false
                        })
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(3)
                    } else {
                        Text(track.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                isEditingName = true
                            }
                    }

                    Spacer()

                    // Mono / Stereo Badge
                    Menu {
                        Button("Mono") { track.channelMode = .mono }
                        Button("Stereo") { track.channelMode = .stereo }
                    } label: {
                        Text(track.channelMode == .mono ? "1" : "2")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 18, height: 16)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(3)
                    }
                    .menuStyle(BorderlessButtonMenuStyle())
                    .disabled(!track.clips.isEmpty)
                    .frame(width: 22)

                    // Delete Track Button
                    Button(action: {
                        projectState.deleteTrack(id: track.id)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                // Middle Row: R / M / S buttons & Input Selector
                HStack(spacing: 5) {
                    // Record Arm [R] (Record Mode vs Playback Mode)
                    Button(action: {
                        projectState.toggleRecordArm(for: track)
                    }) {
                        Text("R")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(track.isRecordArmed ? .white : .red.opacity(0.7))
                            .frame(width: 22, height: 20)
                            .background(
                                track.isRecordArmed
                                    ? Color.red
                                    : Color.white.opacity(0.08)
                            )
                            .cornerRadius(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.red.opacity(track.isRecordArmed ? 1.0 : 0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(track.isRecordArmed ? "Recording Mode (Armed)" : "Playback Mode (Click to Arm Record)")

                    // Mute [M]
                    Button(action: {
                        projectState.toggleMute(for: track)
                    }) {
                        Text("M")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(track.isMuted ? .black : .cyan.opacity(0.7))
                            .frame(width: 22, height: 20)
                            .background(
                                track.isMuted
                                    ? Color.cyan
                                    : Color.white.opacity(0.08)
                            )
                            .cornerRadius(3)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Mute Track")

                    // Solo [S]
                    Button(action: {
                        projectState.toggleSolo(for: track)
                    }) {
                        Text("S")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(track.isSoloed ? .black : .yellow.opacity(0.7))
                            .frame(width: 22, height: 20)
                            .background(
                                track.isSoloed
                                    ? Color.yellow
                                    : Color.white.opacity(0.08)
                            )
                            .cornerRadius(3)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Solo Track")

                    Spacer()

                    // Input Channel Selector Menu
                    let channelOptions = projectState.deviceManager.channels(for: track.channelMode)
                    Menu {
                        ForEach(channelOptions) { opt in
                            Button(opt.name) {
                                track.inputChannelIndex = opt.channelOffset
                            }
                        }
                    } label: {
                        let selectedName = channelOptions.first(where: { $0.channelOffset == track.inputChannelIndex })?.name ?? "In \(track.inputChannelIndex + 1)"
                        HStack(spacing: 2) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 8))
                            Text(selectedName)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(track.isRecordArmed ? .orange : .white.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                    }
                    .menuStyle(BorderlessButtonMenuStyle())
                }

                MixerLevelMeter(
                    peak: meterPeak,
                    label: track.isRecordArmed ? "REC IN" : "OUT"
                )

            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 230, height: Self.rowHeight(for: track) * projectState.trackHeightScale)
        .background(
            isSelected
                ? Color(red: 0.18, green: 0.20, blue: 0.24)
                : Color(red: 0.13, green: 0.14, blue: 0.16)
        )
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onTapGesture {
            projectState.selectedTrackId = track.id
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(height: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if resizeStartHeight == nil {
                                resizeStartHeight = track.trackHeight
                            }
                            track.trackHeight = max(
                                120.0,
                                (resizeStartHeight ?? track.trackHeight) + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            resizeStartHeight = nil
                        }
                )
                .help("Resize track height")
        }
    }
}

