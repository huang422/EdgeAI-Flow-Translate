import Foundation
import FlowTranslateCore
import os

/// Persists the symbol rulebook, separately from `CaptionSettings`.
///
/// Kept apart on purpose: `CaptionSettings` has a `didSet` that re-runs the whole
/// `applySettings` chain (gain, overlay, translation availability). Editing a
/// rule has nothing to do with any of that, and folding it in would make every
/// keystroke in the rulebook editor cancel and relaunch the translation
/// availability probe.
enum RulebookStore {
    private static let key = "FlowTranslate.PromptRulebook"
    private static let log = Logger(subsystem: "dev.flowtranslate.app", category: "prompt")

    static func load() -> PromptRulebook {
        guard let data = UserDefaults.standard.data(forKey: key) else { return PromptStdlib.all }
        guard let decoded = try? JSONDecoder().decode(PromptRulebook.self, from: data) else {
            log.error("symbol rulebook failed to decode; falling back to the bundled stdlib")
            return PromptStdlib.all
        }
        // An empty stored rulebook is almost certainly a bad write rather than a
        // deliberate choice, and starting from nothing makes the feature look broken.
        guard !decoded.rules.isEmpty else { return PromptStdlib.all }
        guard decoded.stdlibVersion < PromptStdlib.version else { return decoded }

        // The saved book predates the current bundled rules. Reconcile once and
        // write the result back, so this costs nothing on every later launch.
        //
        // Without this the store was write-once-read-forever: the first save
        // froze that install's rules, and every later improvement to the bundled
        // library — new phrasings, fixed phrasings, disambiguated ones — reached
        // nobody who had ever opened the editor. The rules the user actually
        // edited survive; the rest come from the app.
        let upgraded = PromptRulebook.upgrading(decoded, to: PromptStdlib.all)
        log.info("upgraded saved rulebook \(decoded.stdlibVersion) → \(PromptStdlib.version)")
        write(upgraded)
        return upgraded
    }

    static func save(_ rulebook: PromptRulebook) {
        // Stamp which rules differ from the bundle on the way out, so the next
        // upgrade knows what it may replace and what belongs to the user.
        write(rulebook.stampingUserEdits(against: PromptStdlib.all))
    }

    private static func write(_ rulebook: PromptRulebook) {
        guard let data = try? JSONEncoder().encode(rulebook) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
