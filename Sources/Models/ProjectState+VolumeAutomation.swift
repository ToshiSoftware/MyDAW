import AppKit

// MARK: - Volume automation (the [A] button and the blue line)

extension ProjectState {
    /// A dot may not reach its neighbour: the line stays a function of time.
    private static let minimumPointSpacing = 0.001

    public func toggleVolumeAutomation<Owner: VolumeAutomationOwner>(for owner: Owner) {
        owner.isVolumeAutomationEnabled.toggle()
        updateEngine(for: owner)
    }

    private func updateEngine<Owner: VolumeAutomationOwner>(for owner: Owner) {
        if let track = owner as? AudioTrack {
            audioEngine.updateVolumeAutomation(of: track)
        } else {
            audioEngine.updateMasterVolumeAutomation()
        }
    }

    /// Adds a dot on the line at `time`, leaving the line's shape as it is.
    /// Returns its id, or nil when a dot is already there.
    @discardableResult
    public func addVolumeAutomationPoint<Owner: VolumeAutomationOwner>(to owner: Owner, at time: Double) -> UUID? {
        guard !owner.volumeAutomation.contains(where: { abs($0.time - time) < Self.minimumPointSpacing }) else {
            return nil
        }
        let point = VolumeAutomationPoint(
            time: time,
            level: VolumeAutomationScale.level(at: time, in: owner.volumeAutomation)
        )
        owner.volumeAutomation.insert(
            point,
            at: owner.volumeAutomation.firstIndex { $0.time > time } ?? owner.volumeAutomation.count
        )
        updateEngine(for: owner)
        return point.id
    }

    /// Moves a dot, keeping it between its neighbours.
    public func moveVolumeAutomationPoint<Owner: VolumeAutomationOwner>(of owner: Owner, id: UUID, time: Double, level: Double) {
        guard let index = owner.volumeAutomation.firstIndex(where: { $0.id == id }) else { return }
        var earliest = 0.0
        var latest = Double.infinity
        if index > 0 { earliest = owner.volumeAutomation[index - 1].time + Self.minimumPointSpacing }
        if index + 1 < owner.volumeAutomation.count {
            latest = owner.volumeAutomation[index + 1].time - Self.minimumPointSpacing
        }
        var point = owner.volumeAutomation[index]
        point.time = min(latest, max(earliest, time))
        point.level = VolumeAutomationScale.clamped(level)
        guard point != owner.volumeAutomation[index] else { return }
        owner.volumeAutomation[index] = point
        updateEngine(for: owner)
    }

    public func deleteVolumeAutomationPoint<Owner: VolumeAutomationOwner>(of owner: Owner, id: UUID) {
        beginClipEdit()
        owner.volumeAutomation.removeAll { $0.id == id }
        endClipEdit()
        updateEngine(for: owner)
    }

    /// From a dot's right-click menu: asks for the level in dB.
    public func enterVolumeAutomationLevel<Owner: VolumeAutomationOwner>(of owner: Owner, id: UUID) {
        guard let point = owner.volumeAutomation.first(where: { $0.id == id }) else { return }
        let field = NSTextField(string: Self.editableText(forLevel: point.level))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 22)

        let alert = NSAlert()
        alert.messageText = String(localized: "Automation Gain")
        alert.informativeText = String(localized: "Enter a level in dB, from +12 down to -inf.")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field

        while alert.runModal() == .alertFirstButtonReturn {
            guard let level = VolumeAutomationScale.level(parsing: field.stringValue) else {
                NSSound.beep()
                continue
            }
            beginClipEdit()
            moveVolumeAutomationPoint(of: owner, id: id, time: point.time, level: level)
            endClipEdit()
            return
        }
    }

    /// The level as the field shows it: the number alone, ready to overtype.
    private static func editableText(forLevel level: Double) -> String {
        VolumeAutomationScale.text(forLevel: level).replacingOccurrences(of: " dB", with: "")
    }
}
