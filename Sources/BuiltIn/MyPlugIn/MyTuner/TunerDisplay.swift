import Foundation
import SwiftUI

/// What the editor shows, advanced once per display frame (Docs/MyTuner.md
/// §1.3–1.5): the needle glides to the detected cents, a note is held for
/// 0.5 s after the sound stops and then fades out, and the strobe band
/// moves in proportion to how far off the note is.
public struct TunerDisplayState: Equatable {
    static let holdSeconds = 0.5
    static let fadeSeconds = 0.5
    static let needleTimeConstant = 0.08
    /// Within this many cents the note counts as in tune.
    public static let inTuneCents = 2.0
    /// Stripes the strobe band moves per second for each cent off.
    static let strobeStripesPerCent = 0.1

    /// The last detected pitch; nil once the display has faded out.
    public private(set) var frequency: Double?
    /// The needle's position, -50 to +50 cents.
    public private(set) var needleCents = 0.0
    /// 1 while sounding and held, falling to 0 as the display fades out.
    public private(set) var brightness = 0.0
    /// Offset of the strobe stripes, 0 to 1 of a stripe.
    public private(set) var strobePhase = 0.0
    private var isSounding = false
    private var silentSeconds = 0.0
    private var midiNote: Int?

    public init() {}

    public func note(calibration: Double, mode: TunerMode) -> TunerNote? {
        frequency.flatMap { TunerNote(frequency: $0, calibration: calibration, mode: mode) }
    }

    public var isInTune: Bool {
        frequency != nil && abs(needleCents) <= Self.inTuneCents
    }

    public mutating func advance(_ update: TunerAnalyzer.Update, calibration: Double, mode: TunerMode,
                                 interval: Double) {
        switch update {
        case .pitch(let detected):
            frequency = detected
            isSounding = true
            silentSeconds = 0
            brightness = 1
        case .silence:
            isSounding = false
        case .none:
            break
        }
        if !isSounding, frequency != nil {
            silentSeconds += interval
            if silentSeconds > Self.holdSeconds {
                brightness = max(0, 1 - (silentSeconds - Self.holdSeconds) / Self.fadeSeconds)
                if brightness == 0 {
                    frequency = nil
                    midiNote = nil
                    needleCents = 0
                }
            }
        }
        guard let note = note(calibration: calibration, mode: mode) else { return }
        let target = min(max(note.cents, TunerNote.centsRange.lowerBound), TunerNote.centsRange.upperBound)
        if note.midiNote != midiNote {
            // A new note: no glide across the scale from the last one.
            midiNote = note.midiNote
            needleCents = target
        } else {
            needleCents += (target - needleCents) * (1 - exp(-interval / Self.needleTimeConstant))
        }
        if isSounding {
            strobePhase += needleCents * Self.strobeStripesPerCent * interval
            strobePhase -= strobePhase.rounded(.down)
        }
    }
}

/// Polls the analyzer 60 times a second while the editor is visible and
/// publishes the display state; tells the kernel to capture only then.
/// Main thread only.
final class TunerDisplayModel: ObservableObject {
    @Published private(set) var state = TunerDisplayState()

    private static let interval = 1.0 / 60
    private let kernel: TunerKernel
    private let analyzer: TunerAnalyzer
    private let isVisible: () -> Bool
    private let calibration: () -> Double
    private let mode: () -> TunerMode
    private var timer: Timer?
    private var lastTick: Date?

    init(kernel: TunerKernel, isVisible: @escaping () -> Bool,
         calibration: @escaping () -> Double, mode: @escaping () -> TunerMode) {
        self.kernel = kernel
        analyzer = TunerAnalyzer(kernel: kernel)
        self.isVisible = isVisible
        self.calibration = calibration
        self.mode = mode
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        kernel.isAnalyzing = false
    }

    private func tick() {
        let visible = isVisible()
        kernel.isAnalyzing = visible
        guard visible else { return }
        let now = Date()
        var next = state
        if let lastTick, now.timeIntervalSince(lastTick) > TunerDisplayState.holdSeconds {
            // Hidden for a while: don't show what was playing back then.
            next = TunerDisplayState()
        }
        lastTick = now
        next.advance(analyzer.update(), calibration: calibration(), mode: mode(), interval: Self.interval)
        if next != state {
            state = next
        }
    }
}
