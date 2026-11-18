#!/usr/bin/env python3
"""Exercise architecture gate exit handling without compiling or editing sources."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("validate-architecture.sh").resolve()


class ArchitectureGuardTests(unittest.TestCase):
    def exercise(self, rg_status=None):
        with tempfile.TemporaryDirectory(prefix="neoanki-architecture-test-") as directory:
            tools = Path(directory)
            log = tools / "scans.log"
            if rg_status is not None:
                # The scanner is simulated; all control flow is the real gate.
                rg = tools / "rg"
                rg.write_text('#!/bin/bash\nprintf "scan\\n" >> "$NEOANKI_ARCH_SCAN_LOG"\n'
                              + ('printf "source.swift:1:import SwiftUI\\n"\n' if rg_status == 0 else '')
                              + 'exit ' + str(rg_status) + '\n')
                rg.chmod(0o755)
                (tools / "dirname").symlink_to("/usr/bin/dirname")
            result = subprocess.run(["/bin/bash", str(SCRIPT)], capture_output=True, text=True,
                                    env={**os.environ, "PATH": str(tools), "NEOANKI_ARCH_SCAN_LOG": str(log)}, timeout=10)
            scans = log.read_text().splitlines() if log.exists() else []
            return result, scans

    def test_missing_ripgrep_fails_before_any_scan_or_success_message(self):
        result, scans = self.exercise()
        self.assertEqual(result.returncode, 127)
        self.assertIn("requires ripgrep", result.stderr)
        self.assertEqual(scans, [])
        self.assertNotIn("boundaries passed", result.stdout)

    def test_scanner_error_stops_immediately_and_cannot_look_like_no_matches(self):
        result, scans = self.exercise(2)
        self.assertEqual(result.returncode, 2)
        self.assertIn("could not scan", result.stderr)
        self.assertEqual(len(scans), 1)
        self.assertNotIn("boundaries passed", result.stdout)

    def test_no_matches_checks_every_boundary_and_succeeds(self):
        result, scans = self.exercise(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(scans), 16)
        self.assertIn("Architecture boundaries passed", result.stdout)

    def test_forbidden_matches_fail_and_preserve_all_boundary_checks(self):
        result, scans = self.exercise(0)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(scans), 16)
        self.assertEqual(result.stderr.count("Architecture violation:"), 16)
        self.assertIn("source.swift:1:import SwiftUI", result.stderr)
        self.assertNotIn("boundaries passed", result.stdout)


class PresentationBoundaryTests(unittest.TestCase):
    def exercise(self, relative_file, source):
        with tempfile.TemporaryDirectory(prefix="neoanki-presentation-guard-") as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            script = root / "Scripts/validate-architecture.sh"
            script.write_text(SCRIPT.read_text())
            for name in ["NeoAnkiApplication", "NeoAnkiFeatures", "NeoAnkiSharedUI", "NeoAnkiCloudSync",
                         "NeoAnkiDeckBuilderCore", "NeoAnkiAPI", "NeoAnki2", "NeoAnkiIOS", "NeoAnkiTextEditing"]:
                folder = root / "Sources" / name
                folder.mkdir(parents=True)
                (folder / "Empty.swift").write_text("// fixture\n")
            core = root / "NeoAnkiCore/Sources/NeoAnkiCore"
            core.mkdir(parents=True)
            (core / "Empty.swift").write_text("// fixture\n")
            for name in ["ContentView.swift", "NeoAnki2App.swift"]:
                (root / "Sources/NeoAnki2" / name).write_text("// fixture\n")
            (root / relative_file).write_text(source)
            return subprocess.run(["bash", str(script)], capture_output=True, text=True, timeout=10)

    def test_feature_state_can_keep_private_capabilities_but_cannot_publish_them(self):
        path = "Sources/NeoAnkiFeatures/Feature.swift"
        self.assertEqual(self.exercise(path, "private let library: any LibraryRepository").returncode, 0)
        rejected = self.exercise(path, "public let library: any LibraryRepository")
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("must not publicly vend", rejected.stderr)

    def test_presentation_uses_actions_instead_of_reaching_into_a_repository(self):
        path = "Sources/NeoAnkiSharedUI/Screen.swift"
        self.assertEqual(self.exercise(path, "let feature = model.features.makeSavedResponses()").returncode, 0)
        rejected = self.exercise(path, "let repository = model.library")
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("must not reach through", rejected.stderr)

    def test_native_text_documents_require_the_supported_policy(self):
        allowed = self.exercise("Sources/NeoAnkiTextEditing/NativeTextEditorPolicy.swift", "scroll.documentView = view")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        rejected = self.exercise("Sources/NeoAnki2/Editor.swift", "scroll.documentView = replacement")
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("must be installed by NativeTextEditorPolicy", rejected.stderr)
        reset = self.exercise("Sources/NeoAnki2/Editor.swift", "textView.isVerticallyResizable = false")
        self.assertEqual(reset.returncode, 1)
        factory = self.exercise("Sources/NeoAnki2/Editor.swift", "let scroll = NSTextView.scrollableTextView()")
        self.assertEqual(factory.returncode, 1)
        self.assertIn("must own their text system", factory.stderr)


if __name__ == "__main__": unittest.main()
