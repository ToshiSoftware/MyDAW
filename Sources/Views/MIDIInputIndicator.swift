import SwiftUI

/// Status bar item: the devices being received, each with a light that shows
/// while MIDI arrives from it ("MIDI: ● A-Series Keyboard ● Audio Interface").
struct MIDIInputIndicator: View {
    @ObservedObject var status: MIDIInputStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.devices.isEmpty {
                Text("MIDI not connected")
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            } else {
                Text(verbatim: "MIDI:")
                    .foregroundColor(.white.opacity(0.85))
                ForEach(status.devices) { device in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(status.receivingDeviceIDs.contains(device.id) ? Color.green : Color.white.opacity(0.18))
                            .frame(width: 7, height: 7)
                        Text(verbatim: device.name)
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(device.portNames.joined(separator: "\n"))
                }
            }
        }
        .font(.system(size: 10, weight: .semibold))
    }
}
