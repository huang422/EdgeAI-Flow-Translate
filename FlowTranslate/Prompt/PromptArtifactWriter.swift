import AppKit
import Foundation
import FlowTranslateCore

/// Installs rendered artifacts into a project, and syncs the symbol rulebook.
///
/// The rulebook goes to `.claude/rules/flow-translate-symbols.md` — a file this
/// app owns outright. That is why it can be written wholesale with no merge
/// logic and no marker parsing: nothing here ever reads, rewrites or appends to
/// the user's own `CLAUDE.md`, so the entire class of "the tool mangled my
/// instructions" bugs cannot occur.
///
/// `.claude/rules/*.md` without `paths` frontmatter is loaded by Claude Code at
/// every session start, which is what makes a symbol resolvable everywhere in
/// the project.
enum PromptArtifactWriter {

    static let rulebookRelativePath = ".claude/rules/flow-translate-symbols.md"

    enum WriteError: LocalizedError {
        case noRelativePath
        case notADirectory(String)

        var errorDescription: String? {
            switch self {
            case .noRelativePath:
                return "This artifact is clipboard-only and has no file location."
            case let .notADirectory(path):
                return "\(path) is not a folder."
            }
        }
    }

    // MARK: - Folder selection

    /// Ask for the project folder. The app is not sandboxed, so a plain path is
    /// enough — no security-scoped bookmark to store or refresh.
    @MainActor
    static func chooseProjectFolder(startingAt current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇 Choose"
        panel.message = "選擇要安裝 Skill／指令／規則本的專案資料夾"
        if let current, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: - Writing

    /// Write an artifact and any companion files under `projectRoot`.
    /// Returns the absolute path of the primary file.
    @discardableResult
    static func write(_ artifact: PromptArtifact, toProjectAt projectRoot: String) throws -> String {
        guard let relative = artifact.relativePath else { throw WriteError.noRelativePath }
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        try requireDirectory(root)

        let primary = try writeFile(relative: relative, content: artifact.content, under: root)
        for companion in artifact.companions {
            try writeFile(relative: companion.relativePath, content: companion.content, under: root)
        }
        return primary
    }

    /// Which files a sync touched, so the UI can say exactly what changed
    /// rather than "done".
    struct SyncReport: Sendable, Equatable {
        var written: [String] = []
        var createdClaudeBridge = false
    }

    /// Sync the rulebook to every agent the project uses.
    ///
    /// Two files, because the two ecosystems genuinely do not read each other's:
    /// Claude Code loads `.claude/rules/` at session start and ignores
    /// `AGENTS.md`; Codex, Cursor, Copilot and Aider read `AGENTS.md` and know
    /// nothing about `.claude/`. Writing one and calling it done would leave
    /// half the user's tools unable to resolve a single symbol.
    @discardableResult
    static func syncRules(
        _ rulebook: PromptRulebook,
        language: PromptOutputLanguage,
        backends: Set<RuleBackend>,
        toProjectAt projectRoot: String,
        createClaudeBridge: Bool = false
    ) throws -> SyncReport {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        try requireDirectory(root)
        var report = SyncReport()

        if backends.contains(.claude) {
            let artifact = PromptRenderer.renderRulebook(rulebook, language: language)
            try writeFile(relative: artifact.relativePath ?? rulebookRelativePath,
                          content: artifact.content, under: root)
            report.written.append(artifact.relativePath ?? rulebookRelativePath)
            for companion in artifact.companions {
                try writeFile(relative: companion.relativePath, content: companion.content, under: root)
                report.written.append(companion.relativePath)
            }
        }

        if backends.contains(.codex) || backends.contains(.generic) {
            let path = AgentsFileRenderer.agentsRelativePath
            let url = root.appending(path: path)
            // Read before writing: everything outside the managed block is the
            // user's and must come back byte-for-byte.
            let existing = try? String(contentsOf: url, encoding: .utf8)
            let merged = AgentsFileRenderer.merge(
                rulebook, into: existing, backend: .codex, language: language
            )
            try writeFile(relative: path, content: merged, under: root)
            report.written.append(path)

            // Only offered when there is no CLAUDE.md at all — never overwrite
            // instructions the user already wrote.
            let claudeURL = root.appending(path: AgentsFileRenderer.claudeBridgeRelativePath)
            if createClaudeBridge, !FileManager.default.fileExists(atPath: claudeURL.path) {
                try writeFile(relative: AgentsFileRenderer.claudeBridgeRelativePath,
                              content: AgentsFileRenderer.claudeBridge, under: root)
                report.written.append(AgentsFileRenderer.claudeBridgeRelativePath)
                report.createdClaudeBridge = true
            }
        }
        return report
    }

    /// Whether the project already has a `CLAUDE.md`.
    static func hasClaudeFile(inProjectAt projectRoot: String) -> Bool {
        let url = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appending(path: AgentsFileRenderer.claudeBridgeRelativePath)
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    private static func writeFile(relative: String, content: String, under root: URL) throws -> String {
        let destination = root.appending(path: relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: destination, atomically: true, encoding: .utf8)
        return destination.path
    }

    private static func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else { throw WriteError.notADirectory(url.path) }
    }

    // MARK: - Reading back

    /// Which symbols the project can currently resolve.
    ///
    /// Read from disk rather than remembered in app state, because the project
    /// is shared: a teammate may have committed the rules file, or the user may
    /// have deleted it. The renderer uses this to decide whether bare symbols
    /// are safe, so a stale "yes" would produce a prompt Claude cannot resolve.
    static func syncedSymbols(inProjectAt projectRoot: String) -> Set<String> {
        let rulesDirectory = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appending(path: ".claude/rules")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rulesDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        var symbols = Set<String>()
        for file in files where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Parsing lives next to rendering in `PromptRenderer`, where the
            // write/read round-trip is unit-tested.
            symbols.formUnion(PromptRenderer.parseSymbols(from: content))
        }
        return symbols
    }

    /// Symbols the project can resolve across **every** agent file.
    ///
    /// A symbol defined only in `AGENTS.md` is still resolvable — by Codex and
    /// friends — so counting only `.claude/rules/` would understate what is
    /// safe to emit.
    static func allSyncedSymbols(inProjectAt projectRoot: String) -> Set<String> {
        var symbols = syncedSymbols(inProjectAt: projectRoot)
        let agents = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appending(path: AgentsFileRenderer.agentsRelativePath)
        if let content = try? String(contentsOf: agents, encoding: .utf8) {
            symbols.formUnion(AgentsFileRenderer.symbols(in: content))
        }
        return symbols
    }
}
