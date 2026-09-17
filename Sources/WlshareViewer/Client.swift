import Foundation

/// The Rust core, as Swift.
///
/// A thin wrapper and deliberately nothing more: the session, the decoders and
/// the framebuffer live on the other side of `wlshare_client.h`, and this file
/// exists to turn C pointers into Swift values and closures into context
/// pointers. Every rule in that header holds here — a callback runs with a lock
/// held and must not block, and the pointers it is given last only for the
/// length of the call.
///
/// `@unchecked Sendable` because it is: the core takes its own locks and is
/// built to be called from any thread. What Swift cannot see is on the other
/// side of the header, and the header says so.
final class Client: @unchecked Sendable {
    private let handle: OpaquePointer
    private let wake = Wake()
    private let context: UnsafeMutableRawPointer

    /// Called on the main queue when the session has something new to draw.
    @MainActor var onChange: (() -> Void)? {
        get { wake.onChange }
        set { wake.onChange = newValue }
    }

    /// What the wake callback is handed, and the reason it is not the `Client`
    /// itself: the session can put a redraw on the main queue a moment before
    /// it is told to stop, and that block must have something to land on after
    /// the `Client` has gone. This outlives it by one hop of the main queue.
    ///
    /// `@unchecked Sendable` because the session's thread does no more with it
    /// than carry it to the main queue; the callback inside is read and written
    /// there and nowhere else.
    private final class Wake: @unchecked Sendable {
        /// Main queue only, which is where every hand that touches it runs.
        nonisolated(unsafe) var onChange: (() -> Void)?
    }

    init(host: String, port: UInt16, username: String, password: String, surface: Surface) {
        handle = wlshare_client_connect(host, port, username, password, surface.width, surface.height, surface.scale)
        context = Unmanaged.passRetained(wake).toOpaque()
        // The trampoline hops to the main queue, so the session's thread is
        // never held up by a redraw and the header's "must not block" is kept
        // whatever the window does.
        wlshare_client_on_frame(handle, { ctx in
            guard let ctx else { return }
            let wake = Unmanaged<Wake>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Taken out first: the callback may end the session, and a
                    // closure must not be freed while it is running.
                    let onChange = wake.onChange
                    onChange?()
                }
            }
        }, context)
    }

    deinit {
        // Clears the callback and joins the session's thread, so nothing can
        // call back into a half-deallocated object.
        wlshare_client_close(handle)
        wake.onChange = nil
        // The wake is let go behind whatever the session queued on its way
        // out: the main queue is serial, so a block put there now runs after
        // every block that was already waiting on it.
        let context = self.context
        DispatchQueue.main.async { Unmanaged<Wake>.fromOpaque(context).release() }
    }

    /// A window's backing store: its size in device pixels and the scale it is
    /// drawn at.
    struct Surface: Equatable {
        var width: UInt16
        var height: UInt16
        var scale: Double
    }

    enum State {
        case connecting
        case ready
        case closed
    }

    struct Status {
        var state: State
        var desktop: (width: Int, height: Int)
        var scale: Double
        var name: String
        var error: String?
    }

    var status: Status {
        var raw = WlshareStatus(state: 0, width: 0, height: 0, scale: 1)
        wlshare_client_status(handle, &raw)
        let state: State =
            switch raw.state {
            case WLSHARE_STATE_READY: .ready
            case WLSHARE_STATE_CLOSED: .closed
            default: .connecting
            }
        let error = string { wlshare_client_error(handle, $0, $1) }
        return Status(
            state: state,
            desktop: (Int(raw.width), Int(raw.height)),
            scale: raw.scale,
            name: string { wlshare_client_name(handle, $0, $1) },
            error: error.isEmpty ? nil : error
        )
    }

    /// Read a string out of the core, which writes as much as fits and says how
    /// long it is; anything longer is asked for again with room.
    private func string(_ read: (UnsafeMutablePointer<CChar>, Int) -> Int) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        var length = buffer.withUnsafeMutableBufferPointer { read($0.baseAddress!, $0.count) }
        if length >= buffer.count {
            buffer = [CChar](repeating: 0, count: length + 1)
            length = buffer.withUnsafeMutableBufferPointer { read($0.baseAddress!, $0.count) }
        }
        let bytes = buffer.prefix(min(length, buffer.count - 1)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Pixels

    /// The framebuffer, for the length of the call, with its damage taken.
    func withFrame(_ body: (WlshareFrame) -> Void) {
        withoutActuallyEscaping(body) { body in
            var box = body
            withUnsafeMutablePointer(to: &box) { ctx in
                wlshare_client_with_frame(handle, { ctx, frame in
                    guard let ctx, let frame else { return }
                    ctx.assumingMemoryBound(to: ((WlshareFrame) -> Void).self).pointee(frame.pointee)
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    /// The pointer's shape, for the length of the call.
    func withCursor(_ body: (WlshareCursor) -> Void) {
        withoutActuallyEscaping(body) { body in
            var box = body
            withUnsafeMutablePointer(to: &box) { ctx in
                wlshare_client_with_cursor(handle, { ctx, cursor in
                    guard let ctx, let cursor else { return }
                    ctx.assumingMemoryBound(to: ((WlshareCursor) -> Void).self).pointee(cursor.pointee)
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    /// The whole framebuffer must be uploaded again — the window lost its
    /// texture, or is making a new one.
    func damageAll() {
        wlshare_client_damage_all(handle)
    }

    // MARK: - Input

    func pointer(buttons: UInt8, x: UInt16, y: UInt16) {
        wlshare_client_pointer(handle, buttons, x, y)
    }

    func key(down: Bool, keysym: UInt32) {
        wlshare_client_key(handle, down, keysym)
    }

    func surface(_ surface: Surface) {
        wlshare_client_surface(handle, surface.width, surface.height, surface.scale)
    }

    /// The wheel notches a scroll comes to, as button-mask bits to click.
    func wheel(dx: Double, dy: Double, precise: Bool) -> [UInt8] {
        var notches = [UInt8](repeating: 0, count: 16)
        let count = notches.withUnsafeMutableBufferPointer {
            wlshare_client_wheel(handle, dx, dy, precise, $0.baseAddress, $0.count)
        }
        return Array(notches.prefix(count))
    }

    /// The X11 keysym for a key press, or nil for a key not worth sending.
    static func keysym(keyCode: UInt16, character: Unicode.Scalar?) -> UInt32? {
        let keysym = wlshare_keysym(keyCode, character?.value ?? 0)
        return keysym == 0 ? nil : keysym
    }
}
