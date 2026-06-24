import Foundation

/// Downloads a Hugging Face model repo's files directly via `URLSession` into a
/// local directory, so the model can be loaded with a directory-based
/// `ModelConfiguration` (no Hugging Face Hub client involved).
///
/// Why not swift-transformers' Hub downloader: it treats an **"expensive"**
/// network (personal hotspot / tethering) as offline and refuses to download —
/// there is no override. Plain `URLSession` has no such restriction (the ASR model
/// downloads the same way), and we control progress, resume-by-skip and verification.
///
/// Files land flat in `~/Library/Application Support/FlowTranslate/models/<repo>/`
/// (Application Support is not TCC-protected, unlike `~/Documents`). Progress is
/// driven by a **session-level** download delegate so the large weights file
/// reports bytes as they arrive.
final class MLXModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum DownloadError: LocalizedError {
        case listFailed(Int)
        case fileFailed(String, Int)
        var errorDescription: String? {
            switch self {
            case .listFailed(let c): return "Could not list model files (HTTP \(c))."
            case .fileFailed(let n, let c): return "Download failed for \(n) (HTTP \(c))."
            }
        }
    }

    let repoId: String
    let directory: URL
    private let endpoint = "https://huggingface.co"

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var continuation: CheckedContinuation<URL, Error>?
    private var byteHandler: ((Int64) -> Void)?

    init(repoId: String) {
        self.repoId = repoId
        directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(component: "FlowTranslate")
            .appending(component: "models")
            .appending(component: repoId.replacingOccurrences(of: "/", with: "_"))
    }

    /// Core files present (config + tokenizer + at least one weights shard).
    var isComplete: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file("config.json").path),
              fm.fileExists(atPath: file("tokenizer.json").path),
              let items = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return items.contains { $0.hasSuffix(".safetensors") }
    }

    private func file(_ n: String) -> URL { directory.appending(component: n) }
    private func resolveURL(_ n: String) -> URL { URL(string: "\(endpoint)/\(repoId)/resolve/main/\(n)")! }

    /// Download every needed file (skips files already present at the expected size).
    func download(progress: ((Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = try await listFiles().filter(Self.isNeeded)

        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        for n in names {
            let s = (try? await headSize(n)) ?? 0
            sizes[n] = s
            total += max(s, 0)
        }

        var completed: Int64 = 0
        for n in names {
            let dest = file(n)
            let expected = sizes[n] ?? 0
            if expected > 0,
               let cur = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64,
               cur == expected {
                completed += expected
                progress?(total > 0 ? Double(completed) / Double(total) : 0)
                continue
            }
            let base = completed
            try await downloadOne(n, to: dest) { written in
                if total > 0 { progress?(Double(base + written) / Double(total)) }
            }
            completed += expected
        }
        progress?(1.0)
    }

    private static func isNeeded(_ name: String) -> Bool {
        if name.contains("/") { return false }   // top-level files only
        return name.hasSuffix(".json") || name.hasSuffix(".safetensors")
            || name == "merges.txt" || name.hasSuffix(".model") || name == "vocab.txt"
    }

    private func listFiles() async throws -> [String] {
        let url = URL(string: "\(endpoint)/api/models/\(repoId)/revision/main")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw DownloadError.listFailed(code) }
        struct Response: Decodable {
            struct Sibling: Decodable { let rfilename: String }
            let siblings: [Sibling]
        }
        return try JSONDecoder().decode(Response.self, from: data).siblings.map(\.rfilename)
    }

    private func headSize(_ name: String) async throws -> Int64 {
        var req = URLRequest(url: resolveURL(name))
        req.httpMethod = "HEAD"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return 0 }
        return http.expectedContentLength > 0 ? http.expectedContentLength : 0
    }

    private func downloadOne(_ name: String, to dest: URL, onBytes: @escaping (Int64) -> Void) async throws {
        let stableTemp: URL = try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.byteHandler = onBytes
            self.session.downloadTask(with: resolveURL(name)).resume()
        }
        byteHandler = nil
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: stableTemp, to: dest)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        byteHandler?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "?"
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: DownloadError.fileFailed(name, http.statusCode))
            continuation = nil
            return
        }
        // `location` is deleted right after this returns — move it out synchronously.
        let stable = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {   // success is handled in didFinishDownloadingTo
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
