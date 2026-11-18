#!/usr/bin/env python3
"""Hermetic fixture-proof checks; no app, simulator, or Swift build is invoked."""
import importlib.util
from pathlib import Path
import unittest
import uuid

SPEC = importlib.util.spec_from_file_location("editor_ui", Path(__file__).with_name("run-editor-save-ui.py"))
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class EditorFixtureProofTests(unittest.TestCase):
    def setUp(self):
        self.nonce = str(uuid.uuid4()).upper()
        self.item = str(uuid.uuid4()).upper()
        self.original = "Original answer"
        self.armed = dict(version=1, nonce=self.nonce, phase="armed", itemID=None,
                          fieldID=module.FIELD, originalPrompt="Original study question " + self.nonce, originalText=self.original)
        self.held = dict(self.armed, phase="held", itemID=self.item, observedText=self.original + " corrected")
        self.persisted = dict(itemID=self.item, text=self.held["observedText"])

    def verify(self):
        return module.validate_receipts(self.armed, self.held, self.nonce, self.persisted)

    def test_only_matching_armed_and_held_durable_transition_is_proof(self):
        self.assertTrue(self.verify()["durableCorrection"])

    def test_compiled_out_or_unreached_fixture_is_not_a_pass(self):
        self.held = None
        with self.assertRaisesRegex(ValueError, "EDITOR_FIXTURE_PROOF"): self.verify()

    def test_held_without_armed_cannot_pass(self):
        self.armed = None
        with self.assertRaisesRegex(ValueError, "missing armed"): self.verify()

    def test_wrong_nonce_cannot_reuse_receipt_from_an_earlier_run(self):
        self.held["nonce"] = str(uuid.uuid4()).upper()
        with self.assertRaisesRegex(ValueError, "nonce"): self.verify()

    def test_wrong_item_or_unsaved_draft_cannot_prove_a_commit(self):
        self.persisted["itemID"] = str(uuid.uuid4()).upper()
        with self.assertRaisesRegex(ValueError, "durable item"): self.verify()
        self.persisted = dict(itemID=self.item, text=self.original)
        with self.assertRaisesRegex(ValueError, "durable item"): self.verify()

    def test_wrong_field_or_inactive_phase_cannot_pass(self):
        self.held["fieldID"] = str(uuid.uuid4())
        with self.assertRaisesRegex(ValueError, "watched field"): self.verify()
        self.held["fieldID"] = module.FIELD
        self.held["phase"] = "armed"
        with self.assertRaisesRegex(ValueError, "phase"): self.verify()


if __name__ == "__main__": unittest.main()
