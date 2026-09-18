import AVFoundation

/// The desktop's sound, on the Mac's default output.
///
/// The core decodes the server's FLAC frames into a buffer of its own; this is
/// the other end of it, an engine whose one source pulls from that buffer on
/// the audio device's clock. 48 kHz stereo is what the session asks the server
/// for, and the mixer converts it to whatever the device runs at.
///
/// Made once the session says the sound is on, and stopped before the `Client`
/// is let go, since the render thread reads from it until the engine stops.
@MainActor
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    init?(client: Client) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return nil }
        let source = Self.source(client: client, format: format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // No engine, no `AudioOutput`: the window makes one again on its next
        // status rather than holding one that never plays.
        guard start() else { return nil }
        // A new default output — headphones in, a display's speakers chosen —
        // stops the engine, and it has to be started again on the new one.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.start() }
        }
    }

    /// Made outside the main actor on purpose: a closure written in a
    /// main-actor context is isolated to it, and Swift checks that on entry —
    /// on the audio device's thread, where it would fail every render.
    private nonisolated static func source(client: Client, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            client.readAudio(left: left, right: right, frames: Int(frames))
            return noErr
        }
    }

    /// Whether the engine is running afterwards.
    @discardableResult
    private func start() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("the desktop's sound cannot be played: %@", error.localizedDescription)
            return false
        }
    }

    /// Stop the engine, which waits for a render in progress. Nothing reads
    /// from the client after this.
    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        engine.stop()
    }
}
