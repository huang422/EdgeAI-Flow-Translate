import AVFoundation
import FlowTranslateCore

/// Microphone capture (AVAudioEngine), emitting 16 kHz mono Float32 AudioChunks (T029).
public final class MicCapture: AudioCapturing, @unchecked Sendable {
    public let source: AudioSourceType = .microphone
    public private(set) var isCapturing: Bool = false
    public var onChunk: ((AudioChunk) -> Void)?

    // No voice processing here, and that is a decision rather than an omission.
    //
    // `setVoiceProcessingEnabled(true)` gives Apple's echo cancellation, noise
    // suppression and automatic gain — the chain the system's own dictation is
    // fed through — and it was switched on for dictation for exactly that
    // reason. It stopped audio reaching the recognizer altogether: enabling it
    // turns the engine into a VPIO graph, which opens the output device and pulls
    // its render cycle from there, and this engine has no output chain at all —
    // only a tap on the input node. The engine starts, reports no error, and
    // never delivers a buffer.
    //
    // Making it work needs a real graph (input connected through to a silent
    // mixer) so the I/O cycle has something to pull, which is a change to how
    // capture is built and not a flag. Until then the raw microphone is what
    // every source uses, and it is what works.

    /// Recreated on demand, not created once.
    ///
    /// An `AVAudioEngine` binds to the input device it saw at build time. When
    /// that device changes — AirPods connect, a dock is unplugged, or the user
    /// has just granted microphone access — the existing engine's input node can
    /// keep reporting a format with **no channels**, and there is no way to make
    /// it re-look. A fresh engine asks the system again.
    private var engine = AVAudioEngine()
    private let converter = AudioConverter()
    private let startTime = Date()

    /// Guards `engine` and `stopRequested`.
    ///
    /// `start()` gained a suspension point when the retry below was added, and
    /// `AudioRouter` is `@unchecked Sendable` with no isolation of its own — so
    /// `stop()` can now genuinely run on another thread while `start()` is parked
    /// mid-way through, reading `engine` as the other reassigns it.
    private let lock = NSLock()
    /// Set by `stop()` so a `start()` suspended across the retry can notice it.
    ///
    /// Without it the stop was a silent no-op: it hit `guard isCapturing` while
    /// that was still false, returned, and `start()` then resumed and installed
    /// the tap anyway — leaving the microphone and its recording indicator live
    /// with no session left to turn them off. The window is exactly the case the
    /// retry exists for: the first ⌃⌥Space after granting microphone access.
    private var stopRequested = false
    /// Whether a tap is currently installed on the engine's input bus.
    ///
    /// Set the moment `installTap` returns, which is earlier than `isCapturing`
    /// — and that gap is exactly where a concurrent `stop()` lands. It is what
    /// `stop()` decides on, so "there is something to tear down" and "the session
    /// is fully up" stop being the same question.
    private var tapInstalled = false

    public init() {}

    public func start() async throws {
        guard !isCapturing else { return }
        lock.withLock { stopRequested = false }

        // Validated before the tap goes on, because `installTap` does not fail —
        // it raises an **Objective-C exception**, which Swift cannot catch, so an
        // invalid format is an immediate `abort()`. That is a real crash from the
        // field: `MicCapture.start` → `installTapOnBus` → `objc_exception_throw`
        // → `abort`, on the first ⌃⌥Space of a fresh install.
        //
        // The old guard checked the sample rate alone, and the sample rate is not
        // the one that goes wrong: a node with no usable input reports 44100 Hz
        // and **zero channels**, which passes that check and raises inside
        // AVFoundation. Both the node's own format and the hardware format have
        // to be complete, since the engine validates the tap against both.
        var input = lock.withLock { engine.inputNode }
        if !Self.isUsable(input) {
            // One retry on a rebuilt engine. Immediately after the permission
            // dialog is accepted the old engine still holds the pre-grant device
            // state, and this is the moment the crash was reported at.
            input = lock.withLock {
                engine = AVAudioEngine()
                return engine.inputNode
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Re-checked after the only suspension point in this method: a `stop()`
        // that arrived while we slept found `isCapturing` still false and did
        // nothing, so carrying on here would open a microphone nobody can close.
        guard !lock.withLock({ stopRequested }) else {
            throw AudioCaptureError.noInputAvailable
        }
        guard Self.isUsable(input) else {
            throw AudioCaptureError.noInputAvailable
        }
        try openTap(on: input)
        isCapturing = true
        // Re-checked once more: `engine.start()` is not instant, and a `stop()`
        // that ran entirely before this line would otherwise leave the microphone
        // open behind it. Exactly one of the two tears the session down.
        if lock.withLock({ stopRequested }) {
            stop()
            throw AudioCaptureError.noInputAvailable
        }
    }

    /// Install the tap and start the engine — or leave nothing behind.
    ///
    /// One unit of work, because the two steps are only correct together: a
    /// failed engine start must not leave a tap on the bus for the next attempt
    /// to collide with.
    private func openTap(on input: AVAudioInputNode) throws {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let samples = self.converter.convertToMono16k(buffer), !samples.isEmpty
            else { return }
            // No gain here. Every consumer reaches this capture through
            // `AudioRouter`, which boosts each chunk with the source's own
            // processor — doing it in both places would apply it twice.
            let chunk = AudioChunk(
                samples: samples,
                source: .microphone,
                timestamp: Date().timeIntervalSince(self.startTime)
            )
            self.onChunk?(chunk)
        }
        lock.withLock { tapInstalled = true }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Don't leave the tap installed on a failed start — a later retry
            // would try to install a second tap on the same bus.
            input.removeTap(onBus: 0)
            lock.withLock { tapInstalled = false }
            throw error
        }
    }

    public func stop() {
        // Recorded even when there is nothing to stop yet, so a `start()` parked
        // in its retry sleep aborts instead of opening a microphone the caller
        // has already given up on.
        //
        // The teardown is gated on the **tap**, not on `isCapturing`. Gating it
        // on `isCapturing` was the bug the flag was added to fix, still in place:
        // `start()` sets that only after `installTap` and the multi-millisecond
        // `engine.start()`, so a `stop()` landing in between saw `false`, returned
        // without removing the tap, and left the microphone — and the menu-bar
        // recording indicator — live with no session left to close them.
        // `tapInstalled` is written the instant the tap goes on, so it covers
        // that window; and it still skips the work when nothing was ever
        // installed, which keeps `disable(.microphone)` on an idle capture from
        // instantiating an input node for no reason.
        let engine = lock.withLock { () -> AVAudioEngine? in
            stopRequested = true
            guard tapInstalled else { return nil }
            tapInstalled = false
            return self.engine
        }
        guard let engine else {
            isCapturing = false
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
    }

    /// Whether a tap can be installed on this node without raising.
    ///
    /// Both formats, both fields. `outputFormat` is what the tap is installed
    /// with; `inputFormat` is the hardware behind it, and the engine checks the
    /// tap against that too — a mismatch or an empty hardware format raises just
    /// as surely as an empty tap format.
    private static func isUsable(_ input: AVAudioInputNode) -> Bool {
        let output = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        return output.sampleRate > 0 && output.channelCount > 0
            && hardware.sampleRate > 0 && hardware.channelCount > 0
    }
}

public enum AudioCaptureError: Error {
    case noInputAvailable
    case permissionDenied
    case systemAudioUnavailable
}
