import Foundation

/// Timeline extent of one clip, in layer order (later clips are on top).
public struct ClipLayerSpan: Sendable, Equatable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let fadeIn: Double
    public let fadeOut: Double
    public let isMuted: Bool

    public init(id: UUID, start: Double, end: Double, fadeIn: Double, fadeOut: Double, isMuted: Bool) {
        self.id = id
        self.start = start
        self.end = end
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.isMuted = isMuted
    }
}

/// Overlap rules shared by playback and drawing: where clips overlap, the
/// upper (later) clip plays and the lower one is silenced. Across the upper
/// clip's fades the lower clip gets the complementary fade, so the upper
/// clip's fade handles act as crossfades. Nothing is stored; it is derived
/// from clip positions, so moving or deleting the upper clip restores the
/// lower one.
public enum ClipLayering {
    public enum SegmentKind: Equatable {
        /// Clip plays untouched (unity envelope).
        case plain
        /// Fully covered by an upper clip: not scheduled at all.
        case hidden
        /// Needs a per-sample envelope (own fades and/or crossfades).
        case shaped
    }

    public struct Segment: Equatable {
        public let start: Double
        public let end: Double
        public let kind: SegmentKind
    }

    @MainActor
    public static func spans(for clips: [AudioClip]) -> [ClipLayerSpan] {
        clips.map { clip in
            let available = clip.originalDuration > 0.0
                ? min(clip.duration, max(0.0, clip.originalDuration - clip.sourceStartTime))
                : clip.duration
            return ClipLayerSpan(
                id: clip.id,
                start: clip.startTime,
                end: clip.startTime + max(0.0, available),
                fadeIn: clip.fadeInDuration,
                fadeOut: clip.fadeOutDuration,
                isMuted: clip.isMuted
            )
        }
    }

    // MARK: - Envelopes

    private static func clamp01(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private static func fadeInRamp(_ span: ClipLayerSpan, _ t: Double) -> Double {
        span.fadeIn > 0 ? clamp01((t - span.start) / span.fadeIn) : 1.0
    }

    private static func fadeOutRamp(_ span: ClipLayerSpan, _ t: Double) -> Double {
        span.fadeOut > 0 ? clamp01((span.end - t) / span.fadeOut) : 1.0
    }

    /// A fade that crosses audio of a lower clip is an equal-power crossfade;
    /// a fade against silence keeps the plain linear shape.
    private static func isCrossfade(_ spans: [ClipLayerSpan], _ index: Int, atStart: Bool) -> Bool {
        let span = spans[index]
        let from = atStart ? span.start : span.end - span.fadeOut
        let to = atStart ? span.start + span.fadeIn : span.end
        return spans[..<index].contains { lower in
            !lower.isMuted && lower.start < max(to, from + 1e-6) && lower.end > from
        }
    }

    private static func shaped(_ ramp: Double, equalPower: Bool) -> Double {
        equalPower ? sin(ramp * .pi / 2) : ramp
    }

    private static func complement(_ ramp: Double, equalPower: Bool) -> Double {
        equalPower ? cos(ramp * .pi / 2) : 1.0 - ramp
    }

    /// The clip's own fade envelope at `t` (1 outside its fades).
    private static func ownGain(_ spans: [ClipLayerSpan], _ index: Int, _ t: Double) -> Double {
        let span = spans[index]
        let fadeIn = shaped(fadeInRamp(span, t), equalPower: isCrossfade(spans, index, atStart: true))
        let fadeOut = shaped(fadeOutRamp(span, t), equalPower: isCrossfade(spans, index, atStart: false))
        return min(fadeIn, fadeOut)
    }

    /// How much of a lower clip an upper clip lets through at `t`.
    private static func mask(_ spans: [ClipLayerSpan], upper index: Int, _ t: Double) -> Double {
        let upper = spans[index]
        guard !upper.isMuted, t >= upper.start, t < upper.end else { return 1.0 }
        let throughIn = complement(fadeInRamp(upper, t), equalPower: isCrossfade(spans, index, atStart: true))
        let throughOut = complement(fadeOutRamp(upper, t), equalPower: isCrossfade(spans, index, atStart: false))
        return max(throughIn, throughOut)
    }

    /// Full envelope of the clip at `t`: own fades times every upper clip's mask.
    public static func gain(_ spans: [ClipLayerSpan], clip id: UUID, at t: Double) -> Double {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return 1.0 }
        let span = spans[index]
        guard t >= span.start, t < span.end else { return 0.0 }
        var value = ownGain(spans, index, t)
        for upperIndex in spans.indices where upperIndex > index {
            value *= mask(spans, upper: upperIndex, t)
            if value == 0 { break }
        }
        return value
    }

    // MARK: - Segmentation

    /// Splits the clip's audible range into plain / hidden / shaped pieces so
    /// playback can stream plain parts straight from the file, skip hidden
    /// ones, and render envelopes only where needed.
    public static func segments(_ spans: [ClipLayerSpan], clip id: UUID) -> [Segment] {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return [] }
        let span = spans[index]
        guard span.end > span.start else { return [] }
        let uppers = spans[(index + 1)...].filter { !$0.isMuted && $0.start < span.end && $0.end > span.start }

        var cuts: [Double] = [span.start, span.end, span.start + span.fadeIn, span.end - span.fadeOut]
        for upper in uppers {
            cuts += [upper.start, upper.start + upper.fadeIn, upper.end - upper.fadeOut, upper.end]
        }
        let points = Array(Set(cuts.filter { $0 > span.start && $0 < span.end } + [span.start, span.end])).sorted()

        var result: [Segment] = []
        for (a, b) in zip(points, points.dropFirst()) where b - a > 1e-9 {
            let kind: SegmentKind
            if uppers.contains(where: { $0.start + $0.fadeIn <= a && b <= $0.end - $0.fadeOut }) {
                kind = .hidden
            } else if uppers.allSatisfy({ $0.end <= a || $0.start >= b }),
                      a >= span.start + span.fadeIn, b <= span.end - span.fadeOut {
                kind = .plain
            } else {
                kind = .shaped
            }
            if let last = result.last, last.kind == kind, abs(last.end - a) < 1e-9 {
                result[result.count - 1] = Segment(start: last.start, end: b, kind: kind)
            } else {
                result.append(Segment(start: a, end: b, kind: kind))
            }
        }
        return result
    }

    /// True when the clip's edge (start or end) sits under an upper clip, so
    /// its fade there is driven by that clip and must not be edited.
    public static func isEdgeCovered(_ spans: [ClipLayerSpan], clip id: UUID, atStart: Bool) -> Bool {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return false }
        let span = spans[index]
        let edge = atStart ? span.start : span.end
        return spans[(index + 1)...].contains { upper in
            !upper.isMuted && upper.start <= edge && edge <= upper.end
        }
    }
}
