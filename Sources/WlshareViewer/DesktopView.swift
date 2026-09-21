import AppKit
import MetalKit

/// The desktop on screen, and every event that goes back to it.
///
/// The view draws only when it is told to — `isPaused` with
/// `enableSetNeedsDisplay` — because a remote desktop that has not changed has
/// nothing to redraw, and the core wakes it when it has.
final class DesktopView: MTKView {
    private let client: Client
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var queue: MTLCommandQueue?

    /// The desktop as a texture, and which framebuffer it was made for. A
    /// generation that has moved is a desktop of a new size.
    private var desktop: MTLTexture?
    private var generation: UInt64 = .max

    /// The RFB button mask as it stands, so that a drag carries the buttons
    /// that are down and a wheel notch does not let go of them.
    private var buttons: UInt8 = 0
    /// The keysym each held key went down with. A key must be let go with the
    /// one it was pressed with: Shift released first would otherwise turn an
    /// `A` going up into an `a` that was never down.
    private var held: [UInt16: UInt32] = [:]

    private var cursorGeneration: UInt64 = 0
    private var remoteCursor: NSCursor?
    /// The scale `remoteCursor` was built at. An `NSCursor` is measured in
    /// points, so a window that moved between a retina screen and one that is
    /// not needs the same shape built again.
    private var cursorScale: Double = 0
    /// Where the pointer was last sent, so that letting go of its buttons does
    /// not also move it to the corner of the desktop.
    private var lastPosition: (x: UInt16, y: UInt16) = (0, 0)
    private var surface = Client.Surface(width: 0, height: 0, scale: 1)

    /// The modifiers worth forwarding, and the bit of `NSEvent.modifierFlags`
    /// that says whether each is down. These are the device-dependent masks,
    /// which is the only way to tell the left key from the right one.
    ///
    /// Caps Lock is not among them on purpose: a character keysym reaches the
    /// server already cased, and a Caps Lock the desktop also latched would
    /// case it a second time.
    private static let modifiers: [UInt16: UInt] = [
        0x38: 0x0002, // Shift_L
        0x3c: 0x0004, // Shift_R
        0x3b: 0x0001, // Control_L
        0x3e: 0x2000, // Control_R
        0x3a: 0x0020, // Alt_L
        0x3d: 0x0040, // Alt_R
        0x37: 0x0008, // Super_L
        0x36: 0x0010, // Super_R
    ]

    init(client: Client, device: MTLDevice) {
        self.client = client
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        // Nothing animates: the session says when there is a new frame.
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        layer?.isOpaque = true
        queue = device.makeCommandQueue()
        makePipeline(device)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not loaded from a nib")
    }

    private func makePipeline(_ device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "desktop_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "desktop_fragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)

        let filter = MTLSamplerDescriptor()
        // Linear only matters while a resize is in flight and the desktop is
        // briefly not the window's size; at rest it is a pixel-for-pixel copy.
        filter.minFilter = .linear
        filter.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: filter)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let queue, let pipeline, let sampler,
              let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer()
        else { return }

        client.withFrame { frame in upload(frame) }
        takeCursor()

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let desktop {
            var fit = self.fit(desktop: desktop)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&fit, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(desktop, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// Where the desktop goes in clip space: the whole drawable when the two
    /// agree, which is the steady state, and the largest rectangle of the right
    /// shape inside it when they do not.
    private func fit(desktop: MTLTexture) -> SIMD4<Float> {
        let drawable = drawableSize
        guard drawable.width > 0, drawable.height > 0, desktop.width > 0, desktop.height > 0 else {
            return SIMD4<Float>(-1, -1, 2, 2)
        }
        let scale = min(drawable.width / Double(desktop.width), drawable.height / Double(desktop.height))
        let width = Float(Double(desktop.width) * scale / drawable.width)
        let height = Float(Double(desktop.height) * scale / drawable.height)
        return SIMD4<Float>(-width, -height, 2 * width, 2 * height)
    }

    /// Take the framebuffer's damage into the texture. Called with the
    /// framebuffer's lock held, so it copies and returns.
    private func upload(_ frame: WlshareFrame) {
        guard let pixels = frame.pixels, frame.width > 0, frame.height > 0 else {
            desktop = nil
            generation = .max
            return
        }
        let width = Int(frame.width)
        let height = Int(frame.height)
        let stride = Int(frame.stride)

        if desktop == nil || generation != frame.generation {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = device?.hasUnifiedMemory == true ? .shared : .managed
            descriptor.usage = .shaderRead
            desktop = device?.makeTexture(descriptor: descriptor)
            generation = frame.generation
            // A texture that has just been made holds nothing, whatever the
            // damage says, so the whole framebuffer goes into it.
            desktop?.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: stride
            )
            return
        }
        guard frame.damaged else { return }
        let x = Int(frame.damage_x)
        let y = Int(frame.damage_y)
        let w = min(Int(frame.damage_width), width - x)
        let h = min(Int(frame.damage_height), height - y)
        guard w > 0, h > 0 else { return }
        desktop?.replace(
            region: MTLRegionMake2D(x, y, w, h),
            mipmapLevel: 0,
            withBytes: pixels.advanced(by: y * stride + x * 4),
            bytesPerRow: stride
        )
    }

    // MARK: - The pointer's shape

    /// wlshare never paints the pointer into a frame, so the one on screen is
    /// this one or there is none.
    private func takeCursor() {
        var changed = false
        client.withCursor { cursor in
            guard cursor.generation != cursorGeneration || surface.scale != cursorScale else { return }
            cursorGeneration = cursor.generation
            cursorScale = surface.scale
            remoteCursor = Self.cursor(cursor, scale: surface.scale)
            changed = true
        }
        if changed {
            window?.invalidateCursorRects(for: self)
        }
    }

    private static func cursor(_ cursor: WlshareCursor, scale: Double) -> NSCursor? {
        guard cursor.present, let rgba = cursor.rgba, cursor.width > 0, cursor.height > 0 else { return nil }
        let width = Int(cursor.width)
        let height = Int(cursor.height)
        let data = Data(bytes: rgba, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  // Premultiplied RGBA, as the core hands it over; read as
                  // straight, every antialiased edge and shadow would be
                  // multiplied by its alpha a second time and come out dark.
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }

        // The shape arrives in the desktop's pixels, which are the window's
        // backing pixels; an NSImage is measured in points.
        let scale = scale > 0 ? scale : 1
        let size = NSSize(width: Double(width) / scale, height: Double(height) / scale)
        let bitmap = NSImage(cgImage: image, size: size)
        let hotspot = NSPoint(x: Double(cursor.hotspot_x) / scale, y: Double(cursor.hotspot_y) / scale)
        return NSCursor(image: bitmap, hotSpot: hotspot)
    }

    /// A pointer that is not there. `NSCursor.hide()` is the other way and the
    /// wrong one: it is process-wide, it stacks, and it would have to be undone
    /// on every path out of the view.
    private static let nothing = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
        hotSpot: .zero
    )

    override func resetCursorRects() {
        // No shape has arrived at all — the session is still connecting — so the
        // window keeps the arrow it came with. Once one has, a shape that is
        // gone is the server saying there is no pointer to draw: an arrow of our
        // own would be a pointer the desktop does not have, and the framebuffer
        // never carries one.
        addCursorRect(bounds, cursor: remoteCursor ?? (cursorGeneration == 0 ? .arrow : Self.nothing))
    }

    // MARK: - The window's backing store

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        postSurface()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        postSurface()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        postSurface()
        addTrackingArea()
    }

    /// Tell the session what this window is now, so it can ask the desktop to
    /// be the same. Posting the same one twice is free — the session drops it.
    private func postSurface() {
        let backing = convertToBacking(bounds).size
        // The scale comes from the same conversion as the size, not from
        // `window.backingScaleFactor`: this runs once before the view has a
        // window, and a view with no window still knows its backing store but
        // has no window to ask. Reading the two from different places sent a
        // retina window's pixel count with a density of 1, and the desktop
        // drew a 2048-pixel-wide picture of a 2048-point desktop.
        let scale = bounds.width > 0 ? Double(backing.width / bounds.width) : Double(window?.backingScaleFactor ?? 1)
        let now = Client.Surface(
            width: UInt16(clamping: Int(backing.width.rounded())),
            height: UInt16(clamping: Int(backing.height.rounded())),
            scale: scale
        )
        guard now != surface else { return }
        surface = now
        client.surface(now)
        // The shape was built for the old scale, in points, so it is built
        // again rather than only re-set.
        takeCursor()
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Clicking an unfocused window should reach the desktop, not just raise
        // the window and be swallowed.
        true
    }

    private var tracking: NSTrackingArea?

    private func addTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    /// Where an event happened, in the desktop's pixels — which are this
    /// window's backing pixels, the view being flipped so both count down.
    ///
    /// Scaled by hand rather than through `convertToBacking`: the backing store
    /// counts up the screen whatever the view does, so a flipped view's point
    /// comes back with its y negated, and every event landed on the top row.
    private func position(_ event: NSEvent) -> (UInt16, UInt16) {
        let point = convert(event.locationInWindow, from: nil)
        let scale = surface.scale
        return (UInt16(clamping: Int((point.x * scale).rounded())), UInt16(clamping: Int((point.y * scale).rounded())))
    }

    private func send(_ event: NSEvent) {
        lastPosition = position(event)
        client.pointer(buttons: buttons, x: lastPosition.x, y: lastPosition.y)
    }

    private func button(_ event: NSEvent, _ bit: UInt8, down: Bool) {
        buttons = down ? buttons | bit : buttons & ~bit
        send(event)
    }

    private func bit(of event: NSEvent) -> UInt8 {
        switch event.buttonNumber {
        case 0: UInt8(WLSHARE_BUTTON_LEFT)
        case 1: UInt8(WLSHARE_BUTTON_RIGHT)
        default: UInt8(WLSHARE_BUTTON_MIDDLE)
        }
    }

    override func mouseDown(with event: NSEvent) { button(event, UInt8(WLSHARE_BUTTON_LEFT), down: true) }
    override func mouseUp(with event: NSEvent) { button(event, UInt8(WLSHARE_BUTTON_LEFT), down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, UInt8(WLSHARE_BUTTON_RIGHT), down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, UInt8(WLSHARE_BUTTON_RIGHT), down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, bit(of: event), down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, bit(of: event), down: false) }
    override func mouseMoved(with event: NSEvent) { send(event) }
    override func mouseDragged(with event: NSEvent) { send(event) }
    override func rightMouseDragged(with event: NSEvent) { send(event) }
    override func otherMouseDragged(with event: NSEvent) { send(event) }

    override func scrollWheel(with event: NSEvent) {
        lastPosition = position(event)
        let (x, y) = lastPosition
        // RFB has no scroll event: a notch is a press and release of a button
        // above the real three, and the core says how many a scroll comes to.
        for notch in client.wheel(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) {
            client.pointer(buttons: buttons | notch, x: x, y: y)
            client.pointer(buttons: buttons, x: x, y: y)
        }
    }

    override func keyDown(with event: NSEvent) {
        // The desktop repeats keys itself; forwarding AppKit's repeats too
        // would type everything twice as fast as it was asked for.
        guard !event.isARepeat else { return }
        let typed = event.charactersIgnoringModifiers?.unicodeScalars.first
        guard let keysym = Client.keysym(keyCode: event.keyCode, character: typed) else { return }
        held[event.keyCode] = keysym
        client.key(down: true, keysym: keysym)
    }

    /// Every chord is the desktop's while it has the keyboard. ⌘C, ⌘H, ⌘Q —
    /// all of them are Super and a key here, because a chord the menu bar
    /// takes is one the desktop never sees, and the desktop is what is being
    /// typed at. The window offers a key equivalent to its views before the
    /// menu bar sees it, so claiming it here is what keeps it from the menu.
    ///
    /// What is left to the Mac is what the Mac keeps for itself before the app
    /// is offered anything — ⌘Tab, ⌘Space, the screenshot chords — and the
    /// menu bar, which is still there to be clicked for the items whose chords
    /// have gone to the desktop. Only chords come through here: a plain key,
    /// an Option chord, Return and Escape all go straight to `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard let keysym = held.removeValue(forKey: event.keyCode) else { return }
        client.key(down: false, keysym: keysym)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let mask = Self.modifiers[event.keyCode],
              let keysym = Client.keysym(keyCode: event.keyCode, character: nil)
        else { return }
        let down = event.modifierFlags.rawValue & mask != 0
        // Held like any other key, because the key-up may never come here:
        // Command-N opens the connection panel, and the window that took the
        // keyboard gets the release. What is held is what is let go of.
        if down {
            held[event.keyCode] = keysym
        } else {
            held.removeValue(forKey: event.keyCode)
        }
        client.key(down: down, keysym: keysym)
    }

    /// Let go of everything this window is holding — it is losing the keyboard,
    /// and a modifier left down on the desktop sticks there.
    override func resignFirstResponder() -> Bool {
        for (_, keysym) in held {
            client.key(down: false, keysym: keysym)
        }
        held.removeAll()
        if buttons != 0 {
            buttons = 0
            client.pointer(buttons: 0, x: lastPosition.x, y: lastPosition.y)
        }
        return super.resignFirstResponder()
    }
}
