import Foundation
import Metal
import MLX

/// Central control of MLX's Metal buffer cache so freed model weights / KV caches
/// are actually returned to the OS instead of lingering in MLX's allocator pool.
///
/// Without this, setting a `ModelContainer` to `nil` frees its tensors into MLX's
/// internal cache (kept for reuse; the default limit is large), so resident memory
/// stays high after a meeting or a translation-backend switch — the main reason the
/// app could sit at many GB. Bounding the cache and clearing it at lifecycle
/// boundaries returns that memory to the system. See [[mlx-summarizer-model-id]].
enum MLXMemory {
    /// Bound MLX's memory once at launch: the buffer cache, and the total.
    ///
    /// **The total is not a tuning knob.** MLX defaults its memory limit to *1.5×*
    /// the device's `recommendedMaxWorkingSetSize` — around 10.6 GB on a 16 GB M1
    /// Pro, so the default lands near the whole machine and MLX never pushes back.
    /// It allocates through the point where macOS swaps and on to a failed
    /// allocation, and a failure inside MLX's global compiler cache is a null
    /// dereference rather than an error (`EXC_BAD_ACCESS` at `0x0` in
    /// `CompilerCache::find`, mid-`TokenIterator.step`).
    ///
    /// Setting the limit to the recommended working set — dropping the 1.5×, not
    /// inventing a number — makes `malloc` wait on scheduled work and free cached
    /// buffers first. `relaxed: true` so a genuine overshoot degrades to swap
    /// rather than throwing: a hard failure mid-meeting is worse than a slow
    /// sentence.
    ///
    /// 384 MB of cache keeps generation fast (buffers are reused within a run)
    /// while preventing unbounded growth — MLX otherwise defaults the cache to the
    /// *memory* limit.
    static func configureAtLaunch() {
        MLX.GPU.set(cacheLimit: 384 * 1024 * 1024)
        MLX.GPU.set(memoryLimit: workingSetLimit, relaxed: true)
    }

    /// Metal's own recommendation for this machine. The fallback is a share of
    /// physical memory rather than a constant, so it is not wrong on every Mac
    /// that is not the 16 GB one this app targets.
    private static var workingSetLimit: Int {
        if let device = MTLCreateSystemDefaultDevice(), device.recommendedMaxWorkingSetSize > 0 {
            return Int(device.recommendedMaxWorkingSetSize)
        }
        return Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.65)
    }

    /// Return all currently-cached Metal buffers to the OS. Call at lifecycle
    /// boundaries (after unloading a model, after a summary), never mid-generation.
    static func reclaim() {
        MLX.GPU.clearCache()
    }
}
