import SwiftUI

private let automationBlue = Color(red: 0.25, green: 0.62, blue: 1.0)

private let automationScaleMarks: [Double] = [12, 6, 0, -6, -12, -24, -48]

/// Where levels lie in a lane, with room for a dot at the top and bottom.
private struct AutomationLaneScale {
    static let inset: CGFloat = 6
    let height: CGFloat

    func y(forLevel level: Double) -> CGFloat {
        Self.inset + CGFloat(1.0 - level) * max(1, height - Self.inset * 2)
    }

    func level(forY y: CGFloat) -> Double {
        VolumeAutomationScale.clamped(1.0 - Double((y - Self.inset) / max(1, height - Self.inset * 2)))
    }
}

/// The line through the dots: flat before the first and after the last.
private func automationLinePath(
    points: [VolumeAutomationPoint],
    width: CGFloat,
    pixelsPerSecond: CGFloat,
    scale: AutomationLaneScale
) -> Path {
    var path = Path()
    let startLevel = points.first?.level ?? VolumeAutomationScale.unityLevel
    let endLevel = points.last?.level ?? VolumeAutomationScale.unityLevel
    path.move(to: CGPoint(x: 0, y: scale.y(forLevel: startLevel)))
    for point in points {
        path.addLine(to: CGPoint(x: CGFloat(point.time) * pixelsPerSecond, y: scale.y(forLevel: point.level)))
    }
    path.addLine(to: CGPoint(x: width, y: scale.y(forLevel: endLevel)))
    return path
}

/// Only a band around the line takes clicks; the rest of the lane stays
/// with the clips below.
private struct AutomationLineHitShape: Shape {
    let points: [VolumeAutomationPoint]
    let pixelsPerSecond: CGFloat
    let scale: AutomationLaneScale

    func path(in rect: CGRect) -> Path {
        automationLinePath(points: points, width: rect.width, pixelsPerSecond: pixelsPerSecond, scale: scale)
            .strokedPath(StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
    }
}

/// The [A] line of one lane: the dB scale, the line, and its dots.
struct VolumeAutomationOverlay<Owner: VolumeAutomationOwner>: View {
    /// Zoom: observed so the line follows it wherever the lane is.
    @EnvironmentObject var timelineGeometry: TimelineGeometry
    @EnvironmentObject var waveformDrawWindow: DrawWindowState
    @ObservedObject var owner: Owner
    let projectState: ProjectState
    let timelineWidth: CGFloat
    let rowHeight: CGFloat

    @State private var draggedPointID: UUID?
    @State private var dragLabel: (x: CGFloat, y: CGFloat, text: String)?
    @State private var pointDragStart: (time: Double, level: Double)?

    var body: some View {
        let pixelsPerSecond = projectState.pixelsPerSecond
        let scale = AutomationLaneScale(height: rowHeight)
        let points = owner.volumeAutomation
        let window = waveformDrawWindow.range

        ZStack(alignment: .topLeading) {
            AutomationLineView(
                scroll: projectState.timelineScroll,
                points: points,
                pixelsPerSecond: pixelsPerSecond,
                timelineWidth: timelineWidth,
                viewportWidth: projectState.timelineViewportWidth,
                rowHeight: rowHeight
            )
            .allowsHitTesting(false)

            AutomationScaleLabels(
                scroll: projectState.timelineScroll,
                pixelsPerSecond: pixelsPerSecond,
                marks: rowHeight >= 110 ? automationScaleMarks : [12, 0, -24],
                scale: scale
            )
            .allowsHitTesting(false)

            Color.clear
                .frame(width: timelineWidth, height: rowHeight)
                .contentShape(AutomationLineHitShape(points: points, pixelsPerSecond: pixelsPerSecond, scale: scale))
                .gesture(lineGesture(pixelsPerSecond: pixelsPerSecond, scale: scale))

            ForEach(points.filter { window.contains($0.time) || $0.id == draggedPointID }) { point in
                Circle()
                    .fill(automationBlue)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                    .frame(width: 11, height: 11)
                    // A larger target than the dot itself.
                    .frame(width: 17, height: 17)
                    .contentShape(Circle())
                    .gesture(pointGesture(point, pixelsPerSecond: pixelsPerSecond, scale: scale))
                    .position(x: CGFloat(point.time) * pixelsPerSecond, y: scale.y(forLevel: point.level))
            }

            if let dragLabel {
                Text(dragLabel.text)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(3)
                    .fixedSize()
                    .position(x: dragLabel.x + 32, y: max(10, dragLabel.y - 12))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: timelineWidth, height: rowHeight, alignment: .topLeading)
        .coordinateSpace(name: "automationLane")
    }

    /// A press on the line adds a dot there; dragging on moves that dot.
    private func lineGesture(pixelsPerSecond: CGFloat, scale: AutomationLaneScale) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("automationLane"))
            .onChanged { value in
                if pointDragStart == nil {
                    projectState.beginClipEdit()
                    let time = projectState.snappedTimelineTime(Double(value.startLocation.x / pixelsPerSecond))
                    // With snap on, the press may land on a dot already there.
                    draggedPointID = projectState.addVolumeAutomationPoint(to: owner, at: time)
                        ?? owner.volumeAutomation.first { abs($0.time - time) < 0.001 }?.id
                    let level = VolumeAutomationScale.level(at: time, in: owner.volumeAutomation)
                    pointDragStart = (time, level)
                }
                guard let id = draggedPointID, let start = pointDragStart else { return }
                drag(id: id, from: start, translation: value.translation, pixelsPerSecond: pixelsPerSecond, scale: scale)
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private func pointGesture(
        _ point: VolumeAutomationPoint,
        pixelsPerSecond: CGFloat,
        scale: AutomationLaneScale
    ) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("automationLane"))
            .onChanged { value in
                if pointDragStart == nil {
                    projectState.beginClipEdit()
                    draggedPointID = point.id
                    pointDragStart = (point.time, point.level)
                }
                guard let start = pointDragStart else { return }
                drag(id: point.id, from: start, translation: value.translation, pixelsPerSecond: pixelsPerSecond, scale: scale)
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private func drag(
        id: UUID,
        from start: (time: Double, level: Double),
        translation: CGSize,
        pixelsPerSecond: CGFloat,
        scale: AutomationLaneScale
    ) {
        let startX = CGFloat(start.time) * pixelsPerSecond
        let startY = scale.y(forLevel: start.level)
        let time = translation.width == 0
            ? start.time
            : projectState.snappedTimelineTime(Double((startX + translation.width) / pixelsPerSecond))
        // The two last pixels at the bottom reach silence for sure.
        var level = scale.level(forY: startY + translation.height)
        if scale.y(forLevel: level) >= rowHeight - AutomationLaneScale.inset - 2 { level = 0 }
        projectState.moveVolumeAutomationPoint(of: owner, id: id, time: time, level: level)
        guard let moved = owner.volumeAutomation.first(where: { $0.id == id }) else { return }
        dragLabel = (
            CGFloat(moved.time) * pixelsPerSecond,
            scale.y(forLevel: moved.level),
            VolumeAutomationScale.text(forLevel: moved.level)
        )
    }

    private func endDrag() {
        projectState.endClipEdit()
        pointDragStart = nil
        draggedPointID = nil
        dragLabel = nil
    }
}

/// The line and the dB grid, drawn only around the visible part of the lane.
/// A Canvas as wide as the whole timeline stopped being redrawn past a certain
/// zoom (the master lane kept the old zoom's picture under the new dots).
/// The band moves in half-screen steps, so scrolling rarely redraws it.
private struct AutomationLineView: View {
    @ObservedObject var scroll: TimelineScrollPosition
    let points: [VolumeAutomationPoint]
    let pixelsPerSecond: CGFloat
    let timelineWidth: CGFloat
    let viewportWidth: CGFloat
    let rowHeight: CGFloat

    var body: some View {
        let step = max(600, viewportWidth / 2)
        let offset = scroll.trackOffset ?? CGFloat(scroll.time) * pixelsPerSecond
        let left = max(0, min(floor(offset / step) * step, timelineWidth - step))
        AutomationLineBand(
            points: points,
            pixelsPerSecond: pixelsPerSecond,
            timelineWidth: timelineWidth,
            left: left,
            // Whatever is in view lies within two steps of an offset less
            // than one step past `left`.
            width: max(1, min(step * 3, timelineWidth - left)),
            rowHeight: rowHeight
        )
        .equatable()
    }
}

private struct AutomationLineBand: View, Equatable {
    let points: [VolumeAutomationPoint]
    let pixelsPerSecond: CGFloat
    let timelineWidth: CGFloat
    let left: CGFloat
    let width: CGFloat
    let rowHeight: CGFloat

    var body: some View {
        let scale = AutomationLaneScale(height: rowHeight)
        Canvas { context, size in
            context.translateBy(x: -left, y: 0)
            let startX = left
            let endX = left + size.width
            var marks = Path()
            for db in automationScaleMarks where db != 0 {
                let y = scale.y(forLevel: VolumeAutomationScale.level(forDB: db))
                marks.move(to: CGPoint(x: startX, y: y))
                marks.addLine(to: CGPoint(x: endX, y: y))
            }
            context.stroke(marks, with: .color(automationBlue.opacity(0.10)), lineWidth: 1)
            var unity = Path()
            let unityY = scale.y(forLevel: VolumeAutomationScale.unityLevel)
            unity.move(to: CGPoint(x: startX, y: unityY))
            unity.addLine(to: CGPoint(x: endX, y: unityY))
            context.stroke(unity, with: .color(automationBlue.opacity(0.28)), lineWidth: 1)
            context.stroke(
                automationLinePath(points: points, width: timelineWidth, pixelsPerSecond: pixelsPerSecond, scale: scale),
                with: .color(automationBlue),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: width, height: rowHeight)
        // A new layer at each zoom, so the old zoom's picture cannot stay.
        .id(pixelsPerSecond)
        .offset(x: left)
    }
}

/// The dB numbers, staying at the left edge of the visible lane.
private struct AutomationScaleLabels: View {
    @ObservedObject var scroll: TimelineScrollPosition
    let pixelsPerSecond: CGFloat
    let marks: [Double]
    let scale: AutomationLaneScale

    var body: some View {
        let x = (scroll.trackOffset ?? CGFloat(scroll.time) * pixelsPerSecond) + 4
        ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { db in
                label(db > 0 ? "+\(Int(db))" : "\(Int(db))", y: scale.y(forLevel: VolumeAutomationScale.level(forDB: db)))
            }
            label("-∞", y: scale.y(forLevel: 0))
        }
        .offset(x: x)
    }

    private func label(_ text: String, y: CGFloat) -> some View {
        Text(verbatim: text)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(automationBlue.opacity(0.75))
            .fixedSize()
            .offset(y: y - 5)
    }
}

/// The header's automation gain: the line's value at the playhead.
struct VolumeAutomationReadout<Owner: VolumeAutomationOwner>: View {
    @ObservedObject var clock: TransportClock
    @ObservedObject var owner: Owner

    var body: some View {
        let isOn = owner.isVolumeAutomationEnabled
        Text(verbatim: isOn
            ? VolumeAutomationScale.text(forLevel: VolumeAutomationScale.level(at: clock.time, in: owner.volumeAutomation))
            : "-- dB")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(isOn ? automationBlue : .white.opacity(0.3))
            .lineLimit(1)
            .frame(width: 54, height: 20)
            .background(Color.black.opacity(0.3))
            .cornerRadius(3)
    }
}

/// The master's [A] button, on its mixer strip and in its lane.
struct MasterAutomationToggle: View {
    @ObservedObject var automation: MasterVolumeAutomation
    let projectState: ProjectState

    var body: some View {
        Button(action: { projectState.toggleVolumeAutomation(for: automation) }) {
            HeaderToggleLabel(title: "A", isOn: automation.isVolumeAutomationEnabled, color: automationBlue)
        }
        .buttonStyle(PlainButtonStyle())
        .help("Volume Automation")
    }
}

/// A right-click on a dot: the commands for that dot.
enum VolumeAutomationMenu {
    /// The menu for a click at `location` in `owner`'s lane; nil off the dots.
    @MainActor
    static func menu<Owner: VolumeAutomationOwner>(
        at location: CGPoint,
        owner: Owner,
        projectState: ProjectState,
        rowHeight: CGFloat
    ) -> NSMenu? {
        guard owner.isVolumeAutomationEnabled else { return nil }
        let scale = AutomationLaneScale(height: rowHeight)
        let pixelsPerSecond = projectState.pixelsPerSecond
        let hit = owner.volumeAutomation.first { point in
            hypot(
                CGFloat(point.time) * pixelsPerSecond - location.x,
                scale.y(forLevel: point.level) - location.y
            ) <= 9
        }
        guard let id = hit?.id else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(String(localized: "Enter Value…"), symbol: "number", enabled: true) {
            projectState.enterVolumeAutomationLevel(of: owner, id: id)
        })
        menu.addItem(ClosureMenuItem(String(localized: "Delete"), symbol: "trash", enabled: true) {
            projectState.deleteVolumeAutomationPoint(of: owner, id: id)
        })
        return menu
    }
}
