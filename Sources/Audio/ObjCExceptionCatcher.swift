import Foundation

@_silgen_name("MyDAWCatchObjCException")
private func myDAWCatchObjCException(
    _ body: @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ context: UnsafeMutableRawPointer?,
    _ reason: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Bool

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
