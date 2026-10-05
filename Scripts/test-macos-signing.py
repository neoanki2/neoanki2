#!/usr/bin/env python3
"""Release regressions: production capability validation and cleanup on failure."""
import datetime as dt
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('mac_signing', Path(__file__).with_name('sign-macos-app.py'))
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


def profile():
    return {
        'ExpirationDate': dt.datetime(2040, 1, 1),
        'TeamIdentifier': ['TEAM123'], 'ProvisionsAllDevices': True, 'Platform': ['OSX'],
        'DeveloperCertificates': [b'certificate'],
        'Entitlements': {
            'com.apple.application-identifier': 'TEAM123.com.neoanki2.app',
            'com.apple.developer.team-identifier': 'TEAM123',
            'com.apple.developer.icloud-container-identifiers': [signing.CONTAINER],
            'com.apple.developer.icloud-services': '*',
            'com.apple.developer.icloud-container-environment': 'Production',
            'com.apple.developer.aps-environment': 'production',
            'com.apple.developer.ubiquity-kvstore-identifier': 'TEAM123.*',
        },
    }


class SigningTests(unittest.TestCase):
    def test_accepts_real_profile_and_expands_signed_entitlements(self):
        p = profile()
        team = signing.validate_profile(p, b'certificate')
        e = signing.entitlements_for(team)
        signing.validate_entitlements(e, team)
        self.assertEqual(e['com.apple.developer.ubiquity-kvstore-identifier'], 'TEAM123.com.neoanki2.app')
        self.assertNotIn('$(TeamIdentifierPrefix)', plistlib.dumps(e).decode())

    def test_rejects_expired_wrong_team_bundle_certificate_or_distribution(self):
        changes = [('ExpirationDate', dt.datetime(2000, 1, 1)), ('TeamIdentifier', []),
                   ('ProvisionsAllDevices', False), ('Platform', ['iOS']),
                   ('DeveloperCertificates', [b'other'])]
        for key, value in changes:
            with self.subTest(key=key):
                p = profile()
                p[key] = value
                with self.assertRaises(signing.SigningError):
                    signing.validate_profile(p, b'certificate')
        for key, value in [('com.apple.application-identifier', 'TEAM123.other'),
                           ('com.apple.developer.team-identifier', 'OTHER'),
                           ('get-task-allow', True)]:
            with self.subTest(key=key):
                p = profile()
                p['Entitlements'][key] = value
                with self.assertRaises(signing.SigningError):
                    signing.validate_profile(p)

    def test_requires_every_production_cloud_capability(self):
        for key in ('com.apple.developer.icloud-container-identifiers',
                    'com.apple.developer.icloud-services',
                    'com.apple.developer.icloud-container-environment',
                    'com.apple.developer.aps-environment',
                    'com.apple.developer.ubiquity-kvstore-identifier'):
            with self.subTest(key=key):
                p = profile()
                del p['Entitlements'][key]
                with self.assertRaises(signing.SigningError):
                    signing.validate_profile(p)
        p = profile()
        p['Entitlements']['com.apple.developer.icloud-container-environment'] = 'Development'
        with self.assertRaises(signing.SigningError):
            signing.validate_profile(p)

    def test_signed_entitlements_cannot_enable_debugger(self):
        e = signing.entitlements_for('TEAM123')
        e['com.apple.security.get-task-allow'] = True
        with self.assertRaises(signing.SigningError):
            signing.validate_entitlements(e, 'TEAM123')

    def test_keychain_cleanup_preserves_concurrent_search_list_on_failure(self):
        calls = []
        keychain = None

        def run(args, timeout=60):
            nonlocal keychain
            calls.append(args)
            if args[:2] == ['openssl', 'pkcs12']:
                Path(args[args.index('-out') + 1]).touch()
            if args[:2] == ['security', 'create-keychain']:
                keychain = args[-1]
            if args[:2] == ['security', 'list-keychains'] and '-s' not in args:
                return f'"login"\n"{keychain}"\n"concurrent"'.encode()
            return b''

        with patch.object(signing, 'run', run):
            with self.assertRaisesRegex(RuntimeError, 'fixture'):
                with signing.signing_keychain(types.SimpleNamespace(directory=Path('/fixture'))):
                    raise RuntimeError('fixture')
        self.assertIn(['security', 'delete-keychain', keychain], calls)
        self.assertIn(['security', 'list-keychains', '-d', 'user', '-s', 'login', 'concurrent'], calls)
        self.assertFalse(any('NeoAnki2-signing.keychain-db' in arg for args in calls for arg in args))

    def test_rejected_notarization_cannot_staple_or_verify(self):
        calls = []
        def run(args, timeout=60):
            calls.append(args)
            if args[:2] == ['openssl', 'pkcs12']:
                Path(args[args.index('-out') + 1]).touch()
            if args[:3] == ['xcrun', 'notarytool', 'submit']:
                return b'{"id":"fixture-id","status":"Invalid"}'
            return b''
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            app = base / 'NeoAnki2.app'
            (app / 'Contents').mkdir(parents=True)
            (base / 'Mac-DeveloperID.provisionprofile').write_bytes(b'fixture')
            material = types.SimpleNamespace(directory=base, team='TEAM123', profile=profile(),
                                             identity='fixture-identity', notary_args=[])
            with patch.object(signing, 'run', run), patch.object(signing, 'verify') as verify:
                with self.assertRaises(signing.SigningError):
                    signing.sign(app, material)
                verify.assert_not_called()
            self.assertTrue((base / 'notarization.json').exists())
        self.assertFalse(any(args[:3] == ['xcrun', 'stapler', 'staple'] for args in calls))
        self.assertTrue(any(args[:3] == ['xcrun', 'notarytool', 'log'] for args in calls))

    def test_release_cannot_opt_out_or_silently_fallback(self):
        import os
        with tempfile.TemporaryDirectory() as folder:
            env = dict(os.environ, NEOANKI_RELEASE_SIGNED='0', NEOANKI_RELEASE_BUILD_NUMBER='999',
                       NEOANKI_RELEASE_VERSION='1.0.999', NEOANKI_SIGNING_DIR=folder)
            result = subprocess.run([str(signing.ROOT / 'Scripts/build-release-artifact.sh'), folder],
                                    env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'require Developer ID', result.stderr)
            env.pop('NEOANKI_RELEASE_SIGNED')
            result = subprocess.run([str(signing.ROOT / 'Scripts/build-release-artifact.sh'), folder],
                                    env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'Missing signing material', result.stderr)
            self.assertFalse(list(Path(folder).glob('*.dmg')))

    def test_notarization_timeout_keeps_submission_id_without_accepting_app(self):
        import json
        calls = []
        def run(args, timeout=60):
            calls.append(args)
            if args[:2] == ['openssl', 'pkcs12']:
                Path(args[args.index('-out') + 1]).touch()
            if args[:3] == ['xcrun', 'notarytool', 'submit']:
                return b'{"id":"pending-id","status":"In Progress"}'
            if args[:3] == ['xcrun', 'notarytool', 'wait']:
                raise signing.SigningError('notarization timed out')
            return b''
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            app = base / 'NeoAnki2.app'
            (app / 'Contents').mkdir(parents=True)
            (base / 'Mac-DeveloperID.provisionprofile').write_bytes(b'fixture')
            (base / 'notarization.json').write_text('{"id":"stale","status":"Accepted"}')
            material = types.SimpleNamespace(directory=base, team='TEAM123', profile=profile(),
                                             identity='fixture-identity', notary_args=[])
            with patch.object(signing, 'run', run), patch.object(signing, 'verify') as verify:
                with self.assertRaisesRegex(signing.SigningError, 'timed out'):
                    signing.sign(app, material)
                verify.assert_not_called()
            receipt = json.loads((base / 'notarization.json').read_text())
            self.assertEqual(receipt['id'], 'pending-id')
            self.assertEqual(receipt['status'], 'In Progress')
        self.assertFalse(any(args[:3] == ['xcrun', 'stapler', 'staple'] for args in calls))


if __name__ == '__main__':
    unittest.main()
