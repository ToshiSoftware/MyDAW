import Foundation
import SwiftUI

@MainActor
public final class FXChannel: Identifiable, ObservableObject {
    public let id: UUID
    @Published public var name: String
    @Published public var volume: Float
    @Published public var pan: Float
    @Published public var plugins: [TrackPluginDescriptor]
    @Published public var color: Color

    public init(
        id: UUID = UUID(),
        name: String = "FX 1",
        volume: Float = 1.0,
        pan: Float = 0.0,
        plugins: [TrackPluginDescriptor] = [],
        color: Color = .purple
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.pan = pan
        self.plugins = plugins
        self.color = color
    }

    public func insertPlugin(_ descriptor: TrackPluginDescriptor) {
        if let index = plugins.firstIndex(where: { $0.id == descriptor.id }) {
            plugins[index].enabled = true
        } else {
            plugins.append(descriptor)
        }
    }

    public func removePlugin(id: UUID) {
        plugins.removeAll { $0.id == id }
    }

    public func movePlugin(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = plugins.firstIndex(where: { $0.id == id }),
              let targetIndex = plugins.firstIndex(where: { $0.id == targetID }) else { return }
        let plugin = plugins.remove(at: sourceIndex)
        let adjustedTargetIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        plugins.insert(plugin, at: adjustedTargetIndex)
    }
}

public struct FXSend: Identifiable, Codable, Hashable {
    public let id: UUID
    public let fxChannelID: UUID
    public var level: Float
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        fxChannelID: UUID,
        level: Float = 0.0,
        enabled: Bool = true
    ) {
        self.id = id
        self.fxChannelID = fxChannelID
        self.level = level
        self.enabled = enabled
    }
}
