import SwiftUI
import FlowTranslateCore

/// Edits the rulebook — the vocabulary that lets a prompt say `NO_DEPS` instead
/// of spelling the constraint out every time.
///
/// Each rule is specified the way an RFC specifies a standard: a stable
/// identifier, a definition, worked examples, per-agent wording, and the source
/// it derives from. The two alias fields are separate on purpose — `aliases` are
/// alternate *identifiers*, `match` are natural-language *phrasings* the matcher
/// recognises — and it is `match` that lets "不要加套件" and "no new libraries"
/// resolve to the same rule.
struct RulebookEditorView: View {
    @Binding var rulebook: PromptRulebook
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var backend: RuleBackend = .claude
    @State private var showIssues = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView { list; detail }
            Divider()
            footer
        }
        .frame(width: 860, height: 620)
        .background(CaptionTheme.Palette.canvas)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("規則本 Rulebook").font(.system(size: 14, weight: .semibold))
            Text("\(rulebook.rules.count) rules").font(.caption)
                .foregroundStyle(CaptionTheme.Palette.inkTertiary)
            Spacer()
            Button("完成 Done") { dismiss() }
        }
        .padding(12)
    }

    // MARK: - List

    private var list: some View {
        // Bound once here, not read per row. It is a computed property that walks
        // every rule, and SwiftUI does not memoize those — reading it inside the
        // 52-row `ForEach` validated the whole rulebook 52 times per body pass,
        // on every keystroke in the detail pane.
        let invalidRuleIDs = rulebook.invalidRuleIDs
        return VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(RuleCategory.allCases) { category in
                    let rules = rulebook.rules(in: category)
                    if !rules.isEmpty {
                        Section(category.displayName) {
                            ForEach(rules) { rule in
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.symbol)
                                            .font(.system(size: 12, weight: .semibold,
                                                          design: .monospaced))
                                        Text(rule.description)
                                            .font(.system(size: 10))
                                            .foregroundStyle(CaptionTheme.Palette.inkTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    // So a reported problem can be found. The
                                    // footer names the rule; without this you
                                    // still had to open all 52 to see which.
                                    if invalidRuleIDs.contains(rule.id) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(CaptionTheme.Palette.stopRec)
                                    }
                                }
                                .tag(rule.id)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Button { addRule() } label: { Image(systemName: "plus") }
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Spacer()
                Button("重設為內建 Reset") { rulebook = PromptStdlib.all }
                    .font(.caption)
            }
            .padding(8)
        }
        .frame(minWidth: 240)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let index = rulebook.rules.firstIndex(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        field("符號 Symbol", symbolBinding(index), monospaced: true)
                        Picker("分類", selection: binding(index, \.category)) {
                            ForEach(RuleCategory.allCases) { Text($0.displayName).tag($0) }
                        }
                        .frame(width: 180)
                    }
                    if !PromptRulebook.isValidSymbol(rulebook.rules[index].symbol) {
                        Text("Symbols are UPPER_SNAKE_CASE: capitals, digits and underscores.")
                            .font(.caption).foregroundStyle(CaptionTheme.Palette.stopRec)
                    }

                    field("定義 Description", binding(index, \.description))

                    Picker("", selection: $backend) {
                        ForEach(RuleBackend.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    // Per-agent wording. Empty falls back to generic, then to
                    // the description — a rule is never rendered blank.
                    field(
                        "\(backend.displayName) 的措辭（留空則沿用通用或定義）",
                        Binding(
                            get: { rulebook.rules[index].backends[backend] ?? "" },
                            set: { rulebook.rules[index].backends[backend] = $0.isEmpty ? nil : $0 }
                        )
                    )

                    field("繁中措辭 Chinese wording", Binding(
                        get: { rulebook.rules[index].zhHant ?? "" },
                        set: { rulebook.rules[index].zhHant = $0.isEmpty ? nil : $0 }
                    ))

                    field("正面說法 Positive form（Claude 優先採用）", Binding(
                        get: { rulebook.rules[index].positiveForm ?? "" },
                        set: { rulebook.rules[index].positiveForm = $0.isEmpty ? nil : $0 }
                    ))
                    Text("Anthropic's guidance is that showing the wanted behaviour beats "
                        + "forbidding the unwanted one. When set, the Claude wording uses this "
                        + "instead of the prohibition — so it must carry everything the "
                        + "prohibition said.")
                        .font(.caption2).foregroundStyle(CaptionTheme.Palette.inkTertiary)

                    Toggle(isOn: binding(index, \.counterIntuitive)) {
                        Text("違反直覺 Counter-intuitive").font(.caption)
                    }
                    Text("Never compressed to a bare symbol: the full wording and its reason are "
                        + "emitted instead. From arXiv 2604.07192 — encoding makes no measurable "
                        + "difference to compliance, but counter-intuitive constraints are obeyed "
                        + "as rarely as 10% of the time where conventional ones reach 99%+. "
                        + "Saving four tokens on the rule most likely to be ignored is the worst "
                        + "trade available.")
                        .font(.caption2).foregroundStyle(CaptionTheme.Palette.inkTertiary)

                    if rulebook.rules[index].counterIntuitive {
                        field("理由 Rationale（會一起輸出）", Binding(
                            get: { rulebook.rules[index].rationale ?? "" },
                            set: { rulebook.rules[index].rationale = $0.isEmpty ? nil : $0 }
                        ))
                        if (rulebook.rules[index].rationale ?? "").isEmpty {
                            Text("A counter-intuitive rule without its reason is just a longer "
                                + "command — the reason is the part that works.")
                                .font(.caption).foregroundStyle(CaptionTheme.Palette.stopRec)
                        }
                    }

                    lines("口語變體 Match（每行一個，中英皆可 — 比對器用）",
                          binding(index, \.match), height: 70)
                    lines("替代識別碼 Aliases（每行一個 — 供人引用）",
                          binding(index, \.aliases), height: 44, monospaced: true)
                    lines("範例 Examples（每行一個）", binding(index, \.examples), height: 56)

                    field("來源 Source（必填）", binding(index, \.source))
                    if rulebook.rules[index].source.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Every rule needs a traceable source — a rule nobody can trace is "
                            + "a rule nobody should be asked to follow.")
                            .font(.caption).foregroundStyle(CaptionTheme.Palette.stopRec)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        lines("路徑範圍 Paths（選填 glob）", binding(index, \.paths),
                              height: 44, monospaced: true)
                        Text("Scoped rules load only while Claude reads a matching file, dropping "
                            + "their cost from every session to only when relevant. AGENTS.md has "
                            + "no equivalent, so a scoped rule is not written there.")
                            .font(.caption2).foregroundStyle(CaptionTheme.Palette.inkTertiary)
                    }
                }
                .padding(12)
            }
        } else {
            VStack {
                Spacer()
                Text("選一條規則來編輯 Select a rule")
                    .font(.caption).foregroundStyle(CaptionTheme.Palette.inkTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Field helpers

    private func binding<V>(_ index: Int, _ path: WritableKeyPath<PromptRule, V>) -> Binding<V> {
        Binding(
            get: { rulebook.rules[index][keyPath: path] },
            set: { rulebook.rules[index][keyPath: path] = $0 }
        )
    }

    private func symbolBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { rulebook.rules[index].symbol },
            set: { rulebook.rules[index].symbol = $0.uppercased() }
        )
    }

    private func field(_ title: String, _ text: Binding<String>, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(CaptionTheme.Palette.inkSecondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
        }
    }

    private func lines(
        _ title: String, _ items: Binding<[String]>, height: CGFloat, monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(CaptionTheme.Palette.inkSecondary)
            TextEditor(text: Binding(
                get: { items.wrappedValue.joined(separator: "\n") },
                set: {
                    items.wrappedValue = $0.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            ))
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .frame(height: height)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(CaptionTheme.Palette.surface))
        }
    }

    /// Every problem, not the count and the first one: the list is 52 rows, so
    /// "13 個問題" alone leaves no way to find the other twelve.
    private var footer: some View {
        let errors = rulebook.validationErrors()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if errors.isEmpty {
                    Label("\(rulebook.rules.count) 條規則 · 全部有效且可追溯 All valid",
                          systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(CaptionTheme.Palette.mic)
                } else {
                    Button {
                        showIssues.toggle()
                    } label: {
                        Label("\(errors.count) 個問題 Issues", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CaptionTheme.Palette.stopRec)

                    // Offered only when every problem is one this can actually
                    // fix. A rule with a missing source or a bad symbol needs a
                    // human, and a button that silently did nothing for those
                    // would be worse than no button.
                    if rulebook.issuesAreRepairable {
                        Button("修復 Fix") {
                            rulebook = rulebook.repairingPhrasings(using: PromptStdlib.all)
                        }
                        .font(.caption)
                        .help("把比對不到的口語變體換成內建規則庫修正後的版本。"
                            + "你自己加的變體與規則都不會被動到。")
                    }
                }
                Spacer()
            }
            if showIssues, !errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(errors, id: \.self) { error in
                            Text("• " + error)
                                .font(.caption2)
                                .foregroundStyle(CaptionTheme.Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(10)
    }

    // MARK: - Mutation

    private func addRule() {
        var name = "NEW_RULE"
        var suffix = 1
        while rulebook.symbols.contains(name) {
            suffix += 1
            name = "NEW_RULE_\(suffix)"
        }
        let rule = PromptRule(symbol: name, description: "", source: "")
        rulebook.rules.append(rule)
        selection = rule.id
    }

    private func removeSelected() {
        guard let selection else { return }
        rulebook.rules.removeAll { $0.id == selection }
        self.selection = nil
    }
}
