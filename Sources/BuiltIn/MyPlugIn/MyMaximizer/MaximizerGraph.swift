import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// Colors of the history graph and its readouts.
enum MaximizerColors {
    /// Output level (Ozone-like teal).
    static let level = Color(red: 0.11, green: 0.55, blue: 0.68)
    static let levelEdge = Color(red: 0.35, green: 0.82, blue: 0.95)
    static let reduction = Color(red: 0.95, green: 0.25, blue: 0.22)
    static let upward = Color(red: 0.35, green: 0.85, blue: 0.4)
    static let upwardEdge = Color(red: 0.6, green: 1, blue: 0.62)
    static let graphBackground = Color(red: 0.05, green: 0.07, blue: 0.09)
}

/// Where the history graph draws a level: 0 dBFS at the top, -30 at the
/// bottom, the same scale for level, reduction and boost (4 px/dB at 120 px).
enum MaximizerGraphScale {
    static let range: Float = 30
    static let grid: [Float] = [-6, -12, -18, -24]

    /// Distance from the top for `decibels` (<= 0), as a fraction of the height.
    static func depth(_ decibels: Float) -> CGFloat {
        CGFloat(min(max(-decibels / range, 0), 1))
    }

    /// Height of an amount in dB, as a fraction of the height.
    static func height(_ decibels: Float) -> CGFloat {
        CGFloat(min(max(decibels / range, 0), 1))
    }

    /// The last `MaximizerHistory.viewColumns` points of `columns`, each
    /// merging `merge` columns (peak and reduction: the extreme; boost: the
    /// mean), oldest first; fewer when the history is shorter.
    ///
    /// Groups are fixed by the columns' numbers (`firstIndex` is the number
    /// of `columns[0]`) and only complete groups are shown, so a point never
    /// changes once drawn and the graph scrolls without shimmering however
    /// many columns arrive at a time.
    static func points(_ columns: [MaximizerColumn], firstIndex: Int = 0, merge: Int) -> [MaximizerColumn] {
        let merge = max(1, merge)
        let firstGroup = (firstIndex + merge - 1) / merge
        let endGroup = (firstIndex + columns.count) / merge
        let startGroup = max(firstGroup, endGroup - MaximizerHistory.viewColumns)
        guard endGroup > startGroup else { return [] }
        return (startGroup..<endGroup).map { group in
            var merged = MaximizerColumn()
            var bypassed = 0
            let start = group * merge - firstIndex
            for index in start..<(start + merge) {
                let column = columns[index]
                merged.peak = max(merged.peak, column.peak)
                merged.reduction = min(merged.reduction, column.reduction)
                merged.boost += column.boost / Float(merge)
                if column.isBypassed { bypassed += 1 }
            }
            merged.isBypassed = bypassed * 2 > merge
            return merged
        }
    }
}

/// The history graph, newest at the right edge, scrolling left: output
/// level (teal, from the bottom), limiter reduction (red, hanging from the
/// top) and UPWARD boost (green, from the bottom), with the OUTPUT ceiling
/// (white) and the limiter's THRESH (red, when below OUTPUT) as dotted
/// lines. Click to change the span.
///
/// Each layer is one outline whose vertical edges sit on device pixels, so
/// scrolling moves whole pixels and no seams or soft edges flicker.
struct MaximizerGraph: View {
    let columns: [MaximizerColumn]
    let firstIndex: Int
    let merge: Int
    let ceiling: Float
    let threshold: Float
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let scale = max(displayScale, 1)
            let step = width / CGFloat(MaximizerHistory.viewColumns)
            let points = MaximizerGraphScale.points(columns, firstIndex: firstIndex, merge: merge)
            let left = width - CGFloat(points.count) * step
            /// Left edge of point `index`, on a device pixel.
            func edgeX(_ index: Int) -> CGFloat {
                ((left + CGFloat(index) * step) * scale).rounded() / scale
            }

            // Grid.
            for db in MaximizerGraphScale.grid {
                let y = ((MaximizerGraphScale.depth(db) * height) * scale).rounded() / scale + 0.5 / scale
                context.stroke(Path { $0.addLines([CGPoint(x: 0, y: y), CGPoint(x: width, y: y)]) },
                               with: .color(.white.opacity(0.08)), lineWidth: 1 / scale)
            }

            if !points.isEmpty {
                var level = Path()
                var edge = Path()
                var reduction = Path()
                var boost = Path()
                var boostEdge = Path()
                var boostRun = false
                var bypassed = Path()
                let start = edgeX(0)
                let end = edgeX(points.count)
                level.move(to: CGPoint(x: start, y: height))
                reduction.move(to: CGPoint(x: start, y: 0))
                boost.move(to: CGPoint(x: start, y: height))
                for (index, point) in points.enumerated() {
                    let x0 = edgeX(index)
                    let x1 = edgeX(index + 1)
                    let db = point.peak > 1e-6 ? 20 * log10(point.peak) : -120
                    var top = MaximizerGraphScale.depth(db) * height
                    var drop = MaximizerGraphScale.height(-point.reduction) * height
                    var lift = MaximizerGraphScale.height(point.boost) * height
                    if point.isBypassed {
                        bypassed.addRect(CGRect(x: x0, y: top, width: x1 - x0, height: height - top))
                        top = height
                        drop = 0
                        lift = 0
                    }
                    level.addLine(to: CGPoint(x: x0, y: top))
                    level.addLine(to: CGPoint(x: x1, y: top))
                    if index == 0 { edge.move(to: CGPoint(x: x0, y: top)) } else { edge.addLine(to: CGPoint(x: x0, y: top)) }
                    edge.addLine(to: CGPoint(x: x1, y: top))
                    reduction.addLine(to: CGPoint(x: x0, y: drop))
                    reduction.addLine(to: CGPoint(x: x1, y: drop))
                    boost.addLine(to: CGPoint(x: x0, y: height - lift))
                    boost.addLine(to: CGPoint(x: x1, y: height - lift))
                    // The boost's outline, only where there is a boost (no line along the bottom).
                    if lift > 0 {
                        let from = CGPoint(x: x0, y: boostRun ? height - lift : height)
                        if boostRun { boostEdge.addLine(to: from) } else { boostEdge.move(to: from) }
                        boostEdge.addLine(to: CGPoint(x: x0, y: height - lift))
                        boostEdge.addLine(to: CGPoint(x: x1, y: height - lift))
                        boostRun = true
                    } else if boostRun {
                        boostEdge.addLine(to: CGPoint(x: x0, y: height))
                        boostRun = false
                    }
                }
                level.addLine(to: CGPoint(x: end, y: height))
                level.closeSubpath()
                reduction.addLine(to: CGPoint(x: end, y: 0))
                reduction.closeSubpath()
                boost.addLine(to: CGPoint(x: end, y: height))
                boost.closeSubpath()

                context.fill(level, with: .color(MaximizerColors.level.opacity(0.85)))
                context.stroke(edge, with: .color(MaximizerColors.levelEdge), lineWidth: 1)
                context.fill(bypassed, with: .color(.white.opacity(0.18)))
                context.fill(boost, with: .color(MaximizerColors.upward.opacity(0.55)))
                context.stroke(boostEdge, with: .color(MaximizerColors.upwardEdge), lineWidth: 1)
                context.fill(reduction, with: .color(MaximizerColors.reduction.opacity(0.75)))
            }

            // OUTPUT ceiling and, when below it, the limiter's THRESH.
            dottedLine(&context, at: MaximizerGraphScale.depth(ceiling) * height, width: width,
                       color: .white.opacity(0.6))
            if threshold < ceiling - 0.05 {
                dottedLine(&context, at: MaximizerGraphScale.depth(threshold) * height, width: width,
                           color: MaximizerColors.reduction.opacity(0.85))
            }

            // Scale.
            for db in [Float(0)] + MaximizerGraphScale.grid {
                let y = min(max(MaximizerGraphScale.depth(db) * height, 5), height - 5)
                context.draw(Text("\(Int(db))")
                                .font(.system(size: 7, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45)),
                             at: CGPoint(x: 2, y: y), anchor: .leading)
            }
        }
        .background(MaximizerColors.graphBackground)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func dottedLine(_ context: inout GraphicsContext, at y: CGFloat, width: CGFloat, color: Color) {
        let y = max(y, 0.5)
        context.stroke(Path { $0.addLines([CGPoint(x: 0, y: y), CGPoint(x: width, y: y)]) },
                       with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }
}
