import Foundation
import AppKit
import AVFoundation

@_silgen_name("MyDAWVST3Create")
private func myDAWVST3Create(_ bundlePath: UnsafePointer<CChar>, _ pluginUID: UnsafePointer<CChar>, _ sampleRate: Double, _ maxFrames: Int32) -> UnsafeMutableRawPointer?
@_silgen_name("MyDAWVST3ProcessStereo")
private func myDAWVST3ProcessStereo(_ instance: UnsafeMutableRawPointer?, _ inputLeft: UnsafePointer<Float>, _ inputRight: UnsafePointer<Float>, _ outputLeft: UnsafeMutablePointer<Float>, _ outputRight: UnsafeMutablePointer<Float>, _ frames: Int32) -> Int32
@_silgen_name("MyDAWVST3GetLatencySamples")
private func myDAWVST3GetLatencySamples(_ instance: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("MyDAWVST3GetState")
private func myDAWVST3GetState(_ instance: UnsafeMutableRawPointer?, _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("MyDAWVST3SetState")
private func myDAWVST3SetState(_ instance: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer, _ size: Int32) -> Int32
@_silgen_name("MyDAWVST3FreeState")
private func myDAWVST3FreeState(_ data: UnsafeMutableRawPointer?)
@_silgen_name("MyDAWVST3AttachEditor")
private func myDAWVST3AttachEditor(_ instance: UnsafeMutableRawPointer?, _ parentView: UnsafeMutableRawPointer, _ width: UnsafeMutablePointer<Int32>, _ height: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("MyDAWVST3GetEditorSize")
private func myDAWVST3GetEditorSize(_ instance: UnsafeMutableRawPointer?, _ width: UnsafeMutablePointer<Int32>, _ height: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("MyDAWVST3SetResizeCallback")
private func myDAWVST3SetResizeCallback(_ instance: UnsafeMutableRawPointer?, _ callback: (@convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void)?, _ context: UnsafeMutableRawPointer?) -> Void
@_silgen_name("MyDAWVST3RemoveEditor")
private func myDAWVST3RemoveEditor(_ instance: UnsafeMutableRawPointer?)
@_silgen_name("MyDAWVST3Destroy")
private func myDAWVST3Destroy(_ instance: UnsafeMutableRawPointer?)

public final class VST3NativeInstance: @unchecked Sendable {
    private var handle: UnsafeMutableRawPointer?
    private let maxFrames: Int
    public let latencySamples: Int

    /// プラグインが IPlugFrame::resizeView() を呼んできたときに通知するコールバック。
    /// メインスレッドで呼ばれる。
    public var onResizeRequest: ((NSSize) -> Void)?

    public init?(descriptor: TrackPluginDescriptor, sampleRate: Double, maxFrames: Int) {
        guard descriptor.kind == .vst3, let bundlePath = descriptor.bundleURL,
              let pluginUID = descriptor.pluginUID, maxFrames > 0 else { return nil }
        let createdHandle = bundlePath.withCString { path in
            pluginUID.withCString { uid in myDAWVST3Create(path, uid, sampleRate, Int32(maxFrames)) }
        }
        guard let createdHandle else { return nil }
        handle = createdHandle
        self.maxFrames = maxFrames
        latencySamples = Int(myDAWVST3GetLatencySamples(createdHandle))
    }

    /// Real-time safe; called from the audio render thread. Outputs must not
    /// alias inputs. Splits into blocks of at most `maxFrames`.
    public func processStereo(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frames: Int
    ) -> Bool {
        guard let handle else { return false }
        var offset = 0
        while offset < frames {
            let blockFrames = min(maxFrames, frames - offset)
            guard myDAWVST3ProcessStereo(
                handle,
                inputLeft + offset,
                inputRight + offset,
                outputLeft + offset,
                outputRight + offset,
                Int32(blockFrames)
            ) == 0 else { return false }
            offset += blockFrames
        }
        return true
    }

    public func captureState() -> Data? {
        var statePointer: UnsafeMutableRawPointer?
        var stateSize: Int32 = 0
        guard myDAWVST3GetState(handle, &statePointer, &stateSize) == 0,
              let statePointer, stateSize > 0 else { return nil }
        defer { myDAWVST3FreeState(statePointer) }
        return Data(bytes: statePointer, count: Int(stateSize))
    }

    @discardableResult
    public func restoreState(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return myDAWVST3SetState(handle, baseAddress, Int32(data.count)) == 0
        }
    }

    /// プラグインのカスタムエディタを parentView にアタッチし、
    /// 確定したビューサイズを返す。
    ///
    /// 処理順序:
    ///   1. attached() を呼ぶ（プラグインによってはここでサイズが確定）
    ///   2. attached() 後に getSize() を再取得
    ///   3. プラグインが attached() 中に resizeView() を呼んでいた場合は
    ///      plugFrame に記録された値を優先（C++ 側で処理済み）
    ///   4. 以降プラグインが resizeView() を呼んできたら onResizeRequest で通知
    public func attachEditor(to parentView: NSView) -> NSSize? {
        guard let handle else { return nil }
        var width: Int32 = 0
        var height: Int32 = 0
        let result = myDAWVST3AttachEditor(handle, Unmanaged.passUnretained(parentView).toOpaque(), &width, &height)
        guard result == 0 else {
            print("VST3 editor attach failed with code \(result)")
            return nil
        }

        // resizeView コールバックを登録する。
        // プラグインが後から IPlugFrame::resizeView() を呼んできたときに
        // Swift 側でウィンドウをリサイズできるようにする。
        let unmanaged = Unmanaged.passRetained(self)
        myDAWVST3SetResizeCallback(handle, { context, w, h in
            guard let context else { return }
            let instance = Unmanaged<VST3NativeInstance>.fromOpaque(context).takeUnretainedValue()
            let size = NSSize(width: Int(w), height: Int(h))
            DispatchQueue.main.async {
                instance.onResizeRequest?(size)
            }
        }, unmanaged.toOpaque())
        // コールバック登録後に unmanaged を release（コールバック内は takeUnretainedValue なので所有権は別管理）
        unmanaged.release()

        return NSSize(width: Int(width), height: Int(height))
    }

    /// attached() 後にプラグインが確定したサイズを再取得する。
    /// resizeView() 経由でサイズが変わっている場合も正しい値を返す。
    public func currentEditorSize() -> NSSize? {
        guard let handle else { return nil }
        var width: Int32 = 0
        var height: Int32 = 0
        guard myDAWVST3GetEditorSize(handle, &width, &height) == 0 else { return nil }
        return NSSize(width: Int(width), height: Int(height))
    }

    public func removeEditor() {
        myDAWVST3RemoveEditor(handle)
    }

    deinit {
        myDAWVST3RemoveEditor(handle)
        myDAWVST3Destroy(handle)
    }
}
