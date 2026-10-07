import SwiftUI
import AppKit

/// dB conversions and the fader/meter taper shared by every mixer control.
enum MixerScale {
    /// Studio One-style travel (measured from its fader): 0 dB sits at 84%,
    /// the region around unity is widest, low levels are compressed.
    private static let taper: [(db: Double, fraction: Double)] = [
        (-96, 0.0), (-72, 0.04), (-48, 0.126), (-36, 0.231), (-24, 0.391),
        (-12, 0.551), (-6, 0.68), (0, 0.84), (6, 1.0)
    ]
    static let ticks: [Double] = [6, 0, -6, -12, -24, -36, -48, -72]
    static let floorDecibels = -96.0

    static func decibels(forGain gain: Float) -> Double {
        gain > 0 ? 20 * log10(Double(gain)) : -.infinity
    }

    static func gain(forDecibels db: Double) -> Float {
        db <= floorDecibels ? 0 : Float(pow(10, db / 20))
    }

    static func fraction(forDecibels db: Double) -> Double {
        guard db > taper[0].db else { return 0 }
        guard db < taper[taper.count - 1].db else { return 1 }
        for (lower, upper) in zip(taper, taper.dropFirst()) where db <= upper.db {
            return lower.fraction + (db - lower.db) / (upper.db - lower.db) * (upper.fraction - lower.fraction)
        }
        return 1
    }

    static func decibels(forFraction fraction: Double) -> Double {
        guard fraction > 0 else { return -.infinity }
        guard fraction < 1 else { return taper[taper.count - 1].db }
        for (lower, upper) in zip(taper, taper.dropFirst()) where fraction <= upper.fraction {
            return lower.db + (fraction - lower.fraction) / (upper.fraction - lower.fraction) * (upper.db - lower.db)
        }
        return taper[taper.count - 1].db
    }

    static func fraction(forGain gain: Float) -> Double {
        fraction(forDecibels: decibels(forGain: gain))
    }

    static func gain(forFraction fraction: Double) -> Float {
        let db = decibels(forFraction: fraction)
        return db.isFinite ? gain(forDecibels: db) : 0
    }

    static func label(forGain gain: Float) -> String {
        let db = decibels(forGain: gain)
        guard db.isFinite, db > floorDecibels else { return "-∞" }
        if abs(db) < 0.05 { return "0dB" }
        return String(format: db > 0 ? "+%.1f" : "%.1f", db)
    }

    /// Accepts "-3.5", "+2", "0", "-inf", "-∞".
    static func gain(parsing text: String) -> Float? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "db", with: "")
        if trimmed.contains("inf") || trimmed.contains("∞") { return 0 }
        guard let db = Double(trimmed) else { return nil }
        return gain(forDecibels: db)
    }

    static func panLabel(_ pan: Float) -> String {
        let amount = Int((abs(pan) * 100).rounded())
        if amount == 0 { return "<C>" }
        return pan < 0 ? "L\(amount)" : "R\(amount)"
    }

    /// Accepts "C", "L56", "R20", or -100...100.
    static func pan(parsing text: String) -> Float? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        if trimmed == "C" || trimmed.isEmpty { return 0 }
        let sign: Float = trimmed.hasPrefix("L") ? -1 : 1
        let digits = trimmed.hasPrefix("L") || trimmed.hasPrefix("R") ? String(trimmed.dropFirst()) : trimmed
        guard let value = Float(digits) else { return nil }
        return max(-1, min(1, sign * value / 100))
    }
}

/// Text that turns into a field on double-click; Return commits, Esc cancels.
struct EditableValueText: View {
    let text: String
    let onCommit: (String) -> Void
    var font: Font = .system(size: 10, weight: .semibold, design: .monospaced)
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(font)
                    .focused($focused)
                    .onSubmit { finish(commit: true) }
                    .onExitCommand { finish(commit: false) }
                    .onChange(of: focused) { isFocused in
                        if !isFocused { finish(commit: true) }
                    }
                    .background(Color.black.opacity(0.6))
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        draft = text
                        isEditing = true
                        DispatchQueue.main.async { focused = true }
                    }
                    // A single click stays here too, so it does not reach
                    // the mixer channel behind (and change its selection).
                    .onTapGesture {}
            }
        }
        .foregroundColor(.white.opacity(0.9))
    }

    private func finish(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        if commit { onCommit(draft) }
    }
}

/// Vertical volume fader on the dB taper. Drag is relative (clicking does
/// not jump), ⌘-drag is fine, ⌥-click resets to 0 dB. A click is taken
/// here too, so it never reaches the channel behind (which would select it).
struct VolumeFader: View {
    @Binding var gain: Float
    var tint: Color = .cyan
    var onChange: () -> Void = {}
    /// After a drag or a ⌥-click.
    var onEnd: () -> Void = {}
    @State private var dragStartFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            let capHeight: CGFloat = 30
            let travel = max(1, geometry.size.height - capHeight)
            let fraction = MixerScale.fraction(forGain: gain)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 4)
                    .padding(.vertical, capHeight / 2)
                faderCap
                    .frame(height: capHeight)
                    .offset(y: CGFloat(1 - fraction) * travel)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard dragStartFraction != nil || value.translation.height != 0 else { return }
                        let start = dragStartFraction ?? MixerScale.fraction(forGain: gain)
                        if dragStartFraction == nil { dragStartFraction = start }
                        let fine = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                        let next = min(1, max(0, start - Double(value.translation.height / travel) * fine))
                        gain = MixerScale.gain(forFraction: next)
                        onChange()
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                        onEnd()
                    }
            )
            .simultaneousGesture(
                TapGesture().modifiers(.option).onEnded {
                    gain = MixerGain.unity
                    onChange()
                    onEnd()
                }
            )
        }
    }

    private var faderCap: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.45), tint.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { index in
                        Rectangle()
                            .fill(index == 2 ? Color.white : Color.black.opacity(0.35))
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 22)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

/// dB labels aligned with the fader/meter taper.
struct FaderScale: View {
    var capHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - capHeight)
            ForEach(MixerScale.ticks, id: \.self) { db in
                Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(db == 0 ? 0.85 : 0.5))
                    .frame(width: geometry.size.width, alignment: .trailing)
                    .position(
                        x: geometry.size.width / 2,
                        y: capHeight / 2 + CGFloat(1 - MixerScale.fraction(forDecibels: db)) * travel
                    )
            }
        }
    }
}

/// L/R level bars on the same taper as the fader, with peak hold.
struct StereoMeter: View {
    let peak: StereoPeak
    var capHeight: CGFloat = 30
    @State private var hold = StereoPeak.zero
    @State private var holdSince = Date()

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - capHeight)
            HStack(spacing: 1) {
                bar(level: peak.left, hold: hold.left, travel: travel)
                bar(level: peak.right, hold: hold.right, travel: travel)
            }
            .padding(.vertical, capHeight / 2)
        }
        .onChange(of: peak) { newPeak in
            let now = Date()
            if newPeak.left >= hold.left || newPeak.right >= hold.right || now.timeIntervalSince(holdSince) > 1.5 {
                hold = now.timeIntervalSince(holdSince) > 1.5 ? newPeak : hold.merged(with: newPeak)
                holdSince = now
            }
        }
    }

    private func height(_ level: Float, _ travel: CGFloat) -> CGFloat {
        CGFloat(MixerScale.fraction(forGain: level)) * travel
    }

    private func bar(level: Float, hold: Float, travel: CGFloat) -> some View {
        let yellow = MixerScale.fraction(forDecibels: -12)
        let red = MixerScale.fraction(forDecibels: -6)
        return ZStack(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.75))
            LinearGradient(
                stops: [
                    .init(color: .green, location: 0),
                    .init(color: .green, location: yellow),
                    .init(color: .yellow, location: yellow),
                    .init(color: .yellow, location: red),
                    .init(color: .red, location: red),
                    .init(color: .red, location: 1)
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: travel)
            .mask(alignment: .bottom) {
                Rectangle().frame(height: height(level, travel))
            }
            if hold > 0.0001 {
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(height: 1)
                    .offset(y: -height(hold, travel))
            }
        }
        .frame(width: 5, height: travel)
    }
}

/// Horizontal pan bar: fill grows from the centre, drag sideways,
/// ⌥-click centres.
struct PanControl: View {
    @Binding var pan: Float
    var tint: Color = .cyan
    var onChange: () -> Void = {}
    /// After a drag or a ⌥-click.
    var onEnd: () -> Void = {}
    @State private var dragStartPan: Float?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let center = width / 2
            let x = center + CGFloat(pan) * center
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.75))
                Rectangle()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(1, abs(x - center)))
                    .offset(x: min(x, center))
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2)
                    .offset(x: x - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard dragStartPan != nil || value.translation.width != 0 else { return }
                        let start = dragStartPan ?? pan
                        if dragStartPan == nil { dragStartPan = start }
                        let fine: Float = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                        pan = max(-1, min(1, start + Float(value.translation.width / center) * fine))
                        onChange()
                    }
                    .onEnded { _ in
                        dragStartPan = nil
                        onEnd()
                    }
            )
            .simultaneousGesture(
                TapGesture().modifiers(.option).onEnded {
                    pan = 0
                    onChange()
                    onEnd()
                }
            )
        }
        .frame(height: 10)
    }
}

/// Horizontal send level on the same dB taper as the faders.
struct SendLevelBar: View {
    let gain: Float
    var tint: Color = .purple
    let onSet: (Float) -> Void
    /// After a drag or a ⌥-click.
    var onEnd: () -> Void = {}
    @State private var dragStartFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = MixerScale.fraction(forGain: gain)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.75))
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.9))
                    .frame(width: CGFloat(fraction) * width)
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1)
                    .offset(x: CGFloat(MixerScale.fraction(forDecibels: 0)) * width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard dragStartFraction != nil || value.translation.width != 0 else { return }
                        let start = dragStartFraction ?? fraction
                        if dragStartFraction == nil { dragStartFraction = start }
                        let fine = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                        let next = min(1, max(0, start + Double(value.translation.width / width) * fine))
                        onSet(MixerScale.gain(forFraction: next))
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                        onEnd()
                    }
            )
            .simultaneousGesture(
                TapGesture().modifiers(.option).onEnded {
                    onSet(MixerGain.unity)
                    onEnd()
                }
            )
        }
        .frame(height: 6)
    }
}
