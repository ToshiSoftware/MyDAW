import Foundation

@_silgen_name("MyDAWCatchObjCException")
private func myDAWCatchObjCException(
    _ body: @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ context: UnsafeMutableRawPointer?,
    _ reason: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Bool

/// `MainActor.assumeIsolated` without its executor check, for code that is on
/// the main thread by construction (main run loop timers, main-queue
/// notifications). An Objective-C exception that AppKit swallows while a
/// MainActor task runs leaves the runtime's record of the current executor
/// pointing at freed stack, and that check then crashes, far from the cause.
/// Escaping on purpose, like `ObjCExceptionCatcher.run`.
func onMainThread<T>(_ body: @escaping @MainActor () -> T) -> T {
    typealias Unchecked = () -> T
    return unsafeBitCast(body, to: Unchecked.self)()
}

extension Int64 {
    /// A frame or tick count from a Double that may be anything (a project
    /// file, a plug-in's report, a typed number). `Int64(Double)` ends the
    /// app on NaN, infinity and huge values; here NaN is 0 and the result
    /// stays within ±1e15, so arithmetic on it cannot overflow either.
    init(saturating value: Double) {
        self = value.isNaN ? 0 : Int64(Swift.min(Swift.max(value, -1e15), 1e15))
    }
}

/// Runs code that reports failure by raising an Objective-C exception
/// (AVAudioEngine's connect, disconnect, detach and tap calls). Swift cannot
/// catch those, so they ended the app; here the call is abandoned instead
/// and the reason returned. The native side is VST3Host/ObjCExceptionCatcher.mm.
enum ObjCExceptionCatcher {
    private final class Box {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
    }

    /// Runs `body`; returns "name: reason" if it raised, nil otherwise.
    /// Escaping on purpose: an exception unwinds past the closure, leaking
    /// what it retained, which `withoutActuallyEscaping` would trap on.
    @discardableResult
    static func run(_ body: @escaping () -> Void) -> String? {
        let box = Box(body)
        var reason = [CChar](repeating: 0, count: 512)
        let finished = withExtendedLifetime(box) {
            reason.withUnsafeMutableBufferPointer { buffer in
                myDAWCatchObjCException({ context in
                    guard let context else { return }
                    Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().body()
                }, Unmanaged.passUnretained(box).toOpaque(), buffer.baseAddress, Int32(buffer.count))
            }
        }
        return finished ? nil : String(cString: reason)
    }

    /// Like `run`, for a call that returns a value; `fallback` if it raised.
    static func value<T>(_ fallback: T, _ body: @escaping () -> T) -> (T, String?) {
        var result = fallback
        let failure = run { result = body() }
        return (failure == nil ? result : fallback, failure)
    }
}
