import Foundation
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
    /// Bound the Metal buffer cache once at launch. 384 MB keeps generation fast
    /// (buffers are reused within a run) while preventing unbounded growth.
    static func configureAtLaunch() {
        MLX.GPU.set(cacheLimit: 384 * 1024 * 1024)
    }

    /// Return all currently-cached Metal buffers to the OS. Call at lifecycle
    /// boundaries (after unloading a model, after a summary), never mid-generation.
    static func reclaim() {
        MLX.GPU.clearCache()
    }
}
