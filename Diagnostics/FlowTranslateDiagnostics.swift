import AVFoundation
import FlowTranslateCore
import Foundation
import FluidAudio

/// Exercises the production ASR service with a local audio file. No microphone,
/// screen recording, permission resets, UI fixtures, or model downloads.
@main struct FlowTranslateDiagnostics {
    static func log(_ message: String) {
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, message)
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    @MainActor static func main() async {
        do { try await run() }
        catch { log("FAIL: \(error)"); exit(1) }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count >= 2 else {
            throw NSError(domain: "Diagnostics: provide a local audio file", code: 1)
        }
        func option(_ name: String, default fallback: String) -> String {
            guard let index = CommandLine.arguments.firstIndex(of: name),
                  index + 1 < CommandLine.arguments.count else { return fallback }
            return CommandLine.arguments[index + 1]
        }
        let language = option("--language", default: "en-US")
        let tier = option("--tier", default: "560ms")
        guard NemotronStreamingService.variantPresent(language: language, tier: tier),
              NemotronStreamingService.vadModelPresent else {
            throw NSError(domain: "Diagnostics: cached ASR and VAD required; no download attempted", code: 2)
        }
        if CommandLine.arguments[1] == "--cancel-regression" {
            try await testColdCancellation()
            return
        }
        if CommandLine.arguments[1] == "--variant-regression" {
            try await testVariantIdentity()
            try await testRapidPresetChanges()
            return
        }
        if CommandLine.arguments[1] == "--router-regression" {
            try await testCaptureOwnership()
            return
        }
        if CommandLine.arguments[1] == "--retry-regression" {
            let attempts = VariantLoads()
            let service = NemotronStreamingService(sharedLoader: { directory in
                await attempts.record(directory.path)
                throw NSError(domain: "Expected synthetic load failure", code: 1)
            })
            service.currentLanguage = "en-US"
            try await service.loadModels(tier: "560ms")
            try await service.startStream()
            try await waitForFailedLoad(service)
            let silence = AudioChunk(samples: Array(repeating: 0, count: 640),
                                     source: .system, timestamp: 0)
            for _ in 0..<8 {
                service.feed(silence)
                try await Task.sleep(for: .milliseconds(10))
            }
            guard await attempts.directories.count == 1 else {
                throw NSError(domain: "Audio retriggered a failed weight load", code: 19)
            }
            service.cancelStream(keepModelsResident: true)
            try await service.startStream()
            try await waitForFailedLoad(service)
            let count = await attempts.directories.count
            service.cancelStream()
            guard count == 2 else { throw NSError(domain: "A failed shared load poisoned retry: \(count) attempts", code: 18) }
            log("PASS: failed load is visible, audio does not retry it, and a new Start retries once")
            return
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Diagnostics: invalid audio", code: 3)
        }
        try file.read(into: buffer)
        guard let speech = AudioConverter().convertToMono16k(buffer), !speech.isEmpty else {
            throw NSError(domain: "Diagnostics: conversion failed", code: 4)
        }
        let audio = speech + Array(repeating: Float.zero, count: 16_000)
        let coldStop = CommandLine.arguments.contains("--cold-stop")
        let asr = coldStop ? NemotronStreamingService(sharedLoader: { directory in
            let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory)
            // Keep this deterministic even on machines with fast cached loads.
            try await Task.sleep(for: .milliseconds(750))
            return shared
        }) : NemotronStreamingService()
        asr.currentLanguage = language
        let diarization = CommandLine.arguments.contains("--diarization")
        guard !diarization || NemotronStreamingService.diarizationModelPresent else {
            throw NSError(domain: "Diagnostics: cached diarization required; no download attempted", code: 20)
        }
        asr.diarizationEnabled = diarization
        asr.onDiarizationUnavailable = { log("DIARIZATION ERROR: \($0)") }
        asr.onModelLoading = { loading in log("weights loading: \(loading)") }
        asr.onVadUnavailable = { log("VAD ERROR: \($0)") }
        var finals = 0
        asr.onEvent = { event in
            let segments: [ASRSegment]
            switch event {
            case .interim, .previewFinal: return
            case .finalized(let segment): segments = [segment]
            case .finalizedGroups(let groups): segments = groups
            }
            for segment in segments {
                finals += 1
                log("FINAL \(segment.source): \(segment.text)")
            }
        }
        for cycle in 1...2 {
            let began = ContinuousClock.now
            log("cycle \(cycle): prepare")
            if cycle == 1, CommandLine.arguments.contains("--source-prewarm") {
                asr.prewarmCachedVariant(language: language, tier: tier)
            }
            try await asr.loadModels(tier: tier)
            log("cycle \(cycle): disk/speaker preparation \(ContinuousClock.now - began), diarization=\(diarization)")
            try await asr.startStream()
            if !coldStop || cycle == 2 {
                await asr.warmUpWeights()
                guard asr.isWarm else { throw NSError(domain: "ASR failed to warm", code: 5) }
            }
            let ready = ContinuousClock.now - began
            log("cycle \(cycle): preparation \(ready); feeding synthetic speech; coldStop=\(coldStop)")
            if cycle == 2, ready > .seconds(2) {
                throw NSError(domain: "Resident weights were reloaded between meetings", code: 7)
            }
            for offset in stride(from: 0, to: audio.count, by: 640) {
                let samples = Array(audio[offset..<min(offset + 640, audio.count)])
                for source in [AudioSourceType.system, .microphone] {
                    asr.feed(AudioChunk(samples: samples, source: source, timestamp: Double(offset) / 16_000))
                }
                if !coldStop || cycle == 2 { try await Task.sleep(for: .milliseconds(40)) }
            }
            let before = finals
            log("cycle \(cycle): stop/drain")
            let stopped = ContinuousClock.now
            asr.stopStream(keepModelsResident: true)
            await asr.drain()
            let drainTime = ContinuousClock.now - stopped
            log("cycle \(cycle): drained after \(drainTime); finals=\(finals), trailing=\(finals - before)")
            if coldStop && cycle == 1 {
                guard drainTime > .milliseconds(600), finals >= 2 else {
                    throw NSError(domain: "Cold stop lost delayed final events", code: 10)
                }
            }
        }
        guard finals >= 4 else { throw NSError(domain: "No final output for both sources/cycles", code: 6) }
        log("PASS: two real ASR sessions, both sources, stop/drain/restart")
        if language == "en-US" {
            asr.prewarmCachedVariant(language: "es-ES", tier: tier)
            asr.currentLanguage = "es-ES"
            try await asr.loadModels(tier: tier)
            guard asr.isWarm else {
                throw NSError(domain: "Same physical ASR variant was reloaded across languages", code: 22)
            }
            log("PASS: English and Spanish share the same resident Latin weights at this tier")
        }
        asr.releaseModels()
    }

    private static func waitForFailedLoad(_ service: NemotronStreamingService) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while service.modelLoadFailure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard service.modelLoadFailure != nil, !service.isWarm else {
            throw NSError(domain: "Synthetic failure left the ASR load unresolved", code: 21)
        }
    }

    @MainActor static func testVariantIdentity() async throws {
        guard NemotronStreamingService.variantPresent(language: "auto", tier: "1120ms") else {
            throw NSError(domain: "Variant regression requires cached multilingual1120; no download attempted", code: 11)
        }
        let loads = VariantLoads()
        let asr = NemotronStreamingService(sharedLoader: { directory in
            await loads.record(directory.path)
            throw CancellationError()
        })
        asr.prewarmCachedVariant(language: "en-US", tier: "560ms")
        try await waitForFailedLoad(asr)
        asr.prewarmCachedVariant(language: "auto", tier: "1120ms")
        try await waitForFailedLoad(asr)
        let directories = await loads.directories
        guard directories.count == 2,
              directories[0].hasSuffix("latin/560ms"),
              directories[1].hasSuffix("multilingual/1120ms") else {
            throw NSError(domain: "Prewarm reused obsolete variant: \(directories)", code: 12)
        }
        asr.cancelStream()
        log("PASS: changing variant replaces the shared weight loader and preserves matching cache identity")
    }

    @MainActor static func testRapidPresetChanges() async throws {
        for tier in ["1120ms", "2240ms"] {
            guard NemotronStreamingService.variantPresent(language: "auto", tier: tier) else {
                throw NSError(domain: "Rapid preset regression requires cached multilingual variants", code: 23)
            }
        }
        let gate = LoadGate()
        let entered = LoadGate()
        let loads = VariantLoads()
        let service = NemotronStreamingService(sharedLoader: { directory in
            await loads.record(directory.path)
            if directory.path.hasSuffix("latin/560ms") {
                await entered.release()
                await gate.wait()
            }
            throw CancellationError()
        })
        service.prewarmCachedVariant(language: "en-US", tier: "560ms")
        await entered.wait()
        service.prewarmCachedVariant(language: "auto", tier: "1120ms")
        service.prewarmCachedVariant(language: "auto", tier: "2240ms")
        try await Task.sleep(for: .milliseconds(40))
        let beforeRelease = await loads.directories
        await gate.release()
        try await waitForFailedLoad(service)
        let directories = await loads.directories
        service.cancelStream()
        guard beforeRelease.count == 1, directories.count == 2,
              directories[1].hasSuffix("multilingual/2240ms") else {
            throw NSError(domain: "Obsolete or concurrent native load: \(directories)", code: 24)
        }
        log("PASS: cached launch preload serializes native work and skips the intermediate preset")
    }

    @MainActor static func testCaptureOwnership() async throws {
        for source in [AudioSourceType.microphone, .system] {
            let old = GatedCapture(source: source)
            let duplicate = GatedCapture(source: source)
            let new = GatedCapture(source: source)
            let factory = CaptureQueue([old, duplicate, new])
            let router = AudioRouter(capturerFactory: { _ in try factory.take() })
            let first = Task { try await router.enable(source) }
            await old.entered.wait()
            do {
                try await router.enable(source)
                throw NSError(domain: "Pending capture falsely reported enabled", code: 13)
            } catch is CancellationError { /* expected: pending is not active */ }
            router.disable(source)
            let replacement = Task { try await router.enable(source) }
            await new.entered.wait()
            await new.ready.release()
            try await replacement.value
            await old.ready.release()
            do {
                try await first.value
                throw NSError(domain: "Obsolete capture start succeeded", code: 14)
            } catch is CancellationError { /* expected */ }
            guard router.activeSources.contains(source), new.isCapturing, !old.isCapturing else {
                throw NSError(domain: "Old capture disabled its replacement", code: 15)
            }
            router.disable(source)
            guard router.activeSources.isEmpty, !new.isCapturing else {
                throw NSError(domain: "Capture remained active after disable", code: 16)
            }
        }
        log("PASS: real router rejects duplicate pending starts; old completion cannot stop replacement sources")
    }

    @MainActor static func testColdCancellation() async throws {
        let gate = LoadGate()
        let asr = NemotronStreamingService(sharedLoader: { _ in
            await gate.wait()
            throw CancellationError()
        })
        asr.currentLanguage = "en-US"
        try await asr.loadModels(tier: "560ms")
        try await asr.startStream()
        asr.feed(AudioChunk(samples: Array(repeating: 0, count: 640), source: .microphone, timestamp: 0))
        let waiting = Task { await asr.warmUpWeights() }
        try await Task.sleep(for: .milliseconds(30))
        asr.stopStream(keepModelsResident: true)
        let began = ContinuousClock.now
        waiting.cancel()
        await waiting.value
        asr.cancelStream(keepModelsResident: true)
        try await asr.loadModels(tier: "560ms")
        try await asr.startStream()
        guard ContinuousClock.now - began < .seconds(1) else {
            throw NSError(domain: "Cancelled cold setup blocked next session", code: 8)
        }
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        guard !asr.isWarm else { throw NSError(domain: "Abandoned setup published readiness", code: 9) }
        asr.cancelStream()
        log("PASS: cancel cold creation, cancel weight waiter, restart without joining obsolete load")
    }
}

private final class GatedCapture: AudioCapturing, @unchecked Sendable {
    let source: AudioSourceType
    let entered = LoadGate()
    let ready = LoadGate()
    private let lock = NSLock()
    private var capturing = false
    var isCapturing: Bool { lock.withLock { capturing } }
    var onChunk: ((AudioChunk) -> Void)?
    init(source: AudioSourceType) { self.source = source }
    func start() async {
        await entered.release()
        await ready.wait()
        lock.withLock { capturing = true }
    }
    func stop() { lock.withLock { capturing = false } }
}

private final class CaptureQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [GatedCapture]
    init(_ captures: [GatedCapture]) { self.captures = captures }
    func take() throws -> GatedCapture {
        try lock.withLock {
            guard !captures.isEmpty else { throw NSError(domain: "Unexpected capture creation", code: 17) }
            return captures.removeFirst()
        }
    }
}

private actor VariantLoads {
    private(set) var directories: [String] = []
    func record(_ directory: String) { directories.append(directory) }
}

private actor LoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
