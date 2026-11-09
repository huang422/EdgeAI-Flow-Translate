#!/usr/bin/env python3
"""Replay production SwiftUI caption/summary code in isolated native windows.

Run after a Release build. No app installation, audio, models, privacy reset or
user preferences are involved. Compiler scratch files are removed on exit.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def declaration(source, signature):
    """Copy the current declaration verbatim, without maintaining a UI clone."""
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-dir", type=Path, help="Keep test-only animation frames here")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    products = root / "build/release/Build/Products/Release"
    core = products / "FlowTranslateCore.o"
    if not core.exists():
        parser.error("Run bash Scripts/build-release.sh first (Release core is missing).")
    content = (root / "FlowTranslate/UI/ContentView.swift").read_text()
    pane = declaration(content, "private var captionsPane: some View")
    pane = pane.replace(".frame(height: summary)", '.frame(height: summary).measured("summary")')
    pane = pane.replace(".frame(height: controls)", '.frame(height: controls).measured("controlsViewport")')
    pane = pane.replace(".frame(height: details)", '.frame(height: details).measured("footerViewport")')
    summary = declaration(content, "private var summaryArea: some View")
    keys = "\n".join(declaration(content, "private struct " + name + ": PreferenceKey")
                     for name in ("CaptionControlsHeight", "CaptionDetailsHeight"))
    overlay = (root / "FlowTranslate/UI/OverlayCaptionWindow.swift").read_text()
    # Colour real paragraph blocks only in the generated test copy. Pixel
    # positions and fading measure the real transition rather than mock boxes.
    marker = "bandLineView(line)\n                    .onGeometryChange"
    assert marker in overlay, "Update the diagnostic marker after overlay refactoring."
    overlay = overlay.replace(marker, "bandLineView(line)\n"
                              "                    .background(line.english.hasPrefix(\"FIRST\") ? Color.red "
                              ": line.english.hasPrefix(\"SECOND\") ? Color.green : Color.blue)\n"
                              "                    .onGeometryChange")
    # Observe the real NSPanel while keeping diagnostic windows behind the desktop.
    overlay = overlay.replace("private var panel: NSPanel?", "fileprivate var panel: NSPanel?")
    overlay = overlay.replace("panel?.orderFrontRegardless()", "panel?.alphaValue = 0; panel?.orderBack(nil)")
    fixture = (root / "Diagnostics/CaptionLayoutDiagnostics.swift.in").read_text()
    for name, value in (("captionsPane", pane), ("summaryArea", summary), ("preferenceKeys", keys)):
        marker = "// INSERT: " + name
        assert fixture.count(marker) == 1, f"Missing unique fixture marker: {name}"
        fixture = fixture.replace(marker, value)
    vm = (root / "FlowTranslate/UI/CaptureViewModel.swift").read_text()
    fixture = fixture.replace("// INSERT: handleFinalized", declaration(vm, "private func handleFinalized("))
    fixture = declaration(vm, "struct CaptionLine: Identifiable, Equatable") + "\n" + fixture
    source = (root / "FlowTranslate/Translation/TranslationService.swift").read_text() + "\n" + (root / "FlowTranslate/UI/CaptionTheme.swift").read_text() + "\n" + overlay + "\n" + fixture
    settings = (root / "FlowTranslate/UI/SettingsView.swift").read_text()
    settings = settings.replace('.keyboardShortcut(.defaultAction)', '.keyboardShortcut(.defaultAction).settingsProbe("done")')
    settings = settings.replace('.pickerStyle(.segmented)\n            .padding(12)', '.pickerStyle(.segmented).settingsProbe("sectionPicker")\n            .padding(12)', 1)
    settings = settings.replace(".formStyle(.grouped)", '.formStyle(.grouped).settingsProbe("promptForm")', 2)
    settings = settings.replace('.settingsProbe("promptForm")', '.settingsProbe("captionsForm")', 1)
    settings_fixture = (root / "Diagnostics/SettingsLayoutFixture.swift.in").read_text()
    for method in ("toggleSystem", "resetPrivacyPermissions", "prepareForTermination", "bindMainWindow"):
        settings_fixture = settings_fixture.replace("// INSERT: " + method,
            declaration(vm, "    func " + method + "("))
    for method in ("handleWindowClosed", "beginClosingResources"):
        settings_fixture = settings_fixture.replace("// INSERT: " + method,
            declaration(vm, "    private func " + method + "("))
    for name in ("titleBar", "brand", "subtitle", "titleActions"):
        view = declaration(content, "private var " + name + ": some View")
        view = view.replace('.help("設定 Settings")', '.help("設定 Settings").settingsProbe("entry")')
        settings_fixture = settings_fixture.replace("// INSERT: " + name, view)
    router = (root / "FlowTranslate/AudioCapture/AudioRouter.swift").read_text()
    source += "\n" + settings + "\n" + router + "\n" + settings_fixture

    if args.report_dir:
        args.report_dir = args.report_dir.resolve()
        args.report_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="flowtranslate-ui-", suffix=".noindex") as scratch:
        scratch = Path(scratch)
        swift = scratch / "main.swift"
        swift.write_text(source)
        executable = scratch / "caption-layout-check"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path",
                        str(scratch / "module-cache"), "-I", str(products),
                        str(swift), str(core), "-o", str(executable)], cwd=root, check=True)
        command = [str(executable)]
        if args.report_dir:
            command.append(str(args.report_dir))
        subprocess.run(command, cwd=root, check=True, timeout=30)


if __name__ == "__main__":
    main()
