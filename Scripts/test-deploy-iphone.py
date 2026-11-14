#!/usr/bin/env python3
"""Deployment invariants without a device, credentials, or external mutations."""
import copy
import contextlib
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
from types import SimpleNamespace
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("deploy_iphone", Path(__file__).with_name("deploy-iphone.py"))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


def device(name="Phone", identifier="device-1"):
    return {"identifier": identifier,
            "hardwareProperties": {"deviceType": "iPhone", "reality": "physical", "udid": "registered"},
            "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "disconnected"},
            "deviceProperties": {"name": name, "developerModeStatus": "enabled"}}


def profile():
    return {"ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
            "TeamIdentifier": ["TEAM"], "ProvisionedDevices": ["registered"],
            "DeveloperCertificates": [b"certificate"],
            "Entitlements": {"application-identifier": "TEAM." + deploy.APP_ID,
                             "com.apple.developer.team-identifier": "TEAM", "get-task-allow": False,
                             "com.apple.security.application-groups": ["group.com.neoanki2.shared"],
                             "aps-environment": "production",
                             "com.apple.developer.icloud-container-environment": ["Development", "Production"],
                             "com.apple.developer.icloud-container-identifiers": ["iCloud.com.neoanki2.app"],
                             "com.apple.developer.icloud-services": "*"}}


class DeploymentTests(unittest.TestCase):
    def test_release_delivery_persists_intent_before_each_device_mutation(self):
        for failure in (None, 'install', 'launch', 'widget-version'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); output = root / 'output'; output.mkdir()
                signing = root / 'signing'; signing.mkdir()
                for name in ('Apple-Distribution.cert.pem', 'Apple-Distribution.key.pem', 'AppleWWDRCAG3.cer',
                             'iOS-AdHoc.mobileprovision', 'Widget-AdHoc.mobileprovision'):
                    (signing / name).touch()
                for name in ('Platforms/iOS/NeoAnki2.entitlements', 'Platforms/iOSWidget/NeoAnkiWidget.entitlements'):
                    path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(plistlib.dumps({}))
                flow = deploy.Workflow(output, root); mutations = []
                args = SimpleNamespace(signing_dir=signing, device=None, version='1.0.400', build='401', prepare_only=False)
                def run(command, **kwargs):
                    if command[:3] == ['openssl', 'x509', '-in']:
                        return b'certificate'
                    if command[:3] == ['security', 'cms', '-D']:
                        p = profile()
                        if command[-1].endswith('Widget-AdHoc.mobileprovision'):
                            p['Entitlements']['application-identifier'] = 'TEAM.' + deploy.WIDGET_ID
                        return plistlib.dumps(p)
                    if command[0] == 'xcodebuild':
                        app = output / 'DerivedData/Build/Products/Release-iphoneos/NeoAnki2.app'
                        widget = app / 'PlugIns/NeoAnki2Widget.appex'; widget.mkdir(parents=True)
                        for path, bundle in ((app, deploy.APP_ID), (widget, deploy.WIDGET_ID)):
                            version = '1.0.0' if failure == 'widget-version' and path == widget else '1.0.400'
                            (path / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle,
                                'CFBundleShortVersionString': version, 'CFBundleVersion': '401'}))
                        (app / 'NeoAnki2').write_bytes(b'executable')
                    if command[:2] == ['git', 'rev-parse']:
                        return b'merged-sha\n'
                    return b''
                def device_command(name, command, *unused):
                    if name == 'devices':
                        return {'result': {'devices': [device()]}}
                    receipt = json.loads((output / 'deployment.json').read_text())
                    self.assertEqual(receipt['phase'], name)
                    self.assertEqual(receipt['installed'], name == 'launch')
                    self.assertFalse(receipt['launched'])
                    mutations.append(name)
                    if name == failure:
                        raise deploy.DeploymentError('injected ' + name + ' failure')
                    result = {'deviceIdentifier': 'device-1'}
                    if name == 'install':
                        result['installedApplications'] = [{'bundleID': deploy.APP_ID}]
                    else:
                        result['process'] = {'processIdentifier': 42, 'executable': '/NeoAnki2.app/NeoAnki2'}
                    return {'info': {'outcome': 'success'}, 'result': result}
                def codesign(command, **kwargs):
                    kind = 'widget' if command[-1].endswith('.appex') else 'app'
                    return subprocess.CompletedProcess(command, 0, (output / (kind + '-entitlements.plist')).read_bytes(), b'')
                with patch.object(flow, 'run', side_effect=run), patch.object(flow, 'device_command', side_effect=device_command), \
                     patch.object(flow, 'signing_keychain', return_value=contextlib.nullcontext(Path('temporary-keychain'))), \
                     patch.object(deploy.subprocess, 'run', side_effect=codesign):
                    if failure:
                        with self.assertRaises(deploy.DeploymentError):
                            flow.execute(args)
                    else:
                        flow.execute(args)
                self.assertEqual(mutations, [] if failure == 'widget-version' else ['install'] if failure == 'install' else ['install', 'launch'])
                if not failure:
                    receipt = json.loads((output / 'deployment.json').read_text())
                    self.assertTrue(receipt['installed'] and receipt['launched'])
                    self.assertEqual(receipt['sourceRevision'], 'merged-sha')
                    self.assertEqual((receipt['version'], receipt['build']), ('1.0.400', '401'))

    def test_release_build_uses_pinned_source_and_version_for_app_and_widget(self):
        flow = deploy.Workflow(Path('/output'), Path('/pinned-source'))
        command = flow.build_command(SimpleNamespace(version='1.0.400', build='401'), Path('/output/DerivedData'))
        self.assertEqual(command[command.index('-project') + 1], '/pinned-source/Xcode/NeoAnkiiOS.xcodeproj')
        self.assertIn('MARKETING_VERSION=1.0.400', command)
        self.assertIn('CURRENT_PROJECT_VERSION=401', command)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', command)

    def test_standalone_build_keeps_project_versions(self):
        command = deploy.Workflow(Path('unused')).build_command(SimpleNamespace(version=None, build=None), Path('derived'))
        self.assertFalse(any(c.startswith(('MARKETING_VERSION=', 'CURRENT_PROJECT_VERSION=')) for c in command))

    def test_incomplete_or_invalid_release_version_stops_before_device_access(self):
        for args in (['--version', '1.0.400'], ['--build', '401'],
                     ['--version', 'bad', '--build', '401'], ['--version', '1.0.400', '--build', '0']):
            with self.subTest(args=args), patch.object(deploy.Workflow, 'execute', side_effect=AssertionError('device accessed')):
                with self.assertRaises(SystemExit) as caught:
                    deploy.main(args)
                self.assertEqual(caught.exception.code, 2)

    def test_single_wired_phone_with_closed_tunnel_is_available(self):
        self.assertEqual(deploy.select_device([device()])["identifier"], "device-1")

    def test_multiple_phones_require_explicit_selection(self):
        phones = [device(), device("Second", "device-2")]
        with self.assertRaisesRegex(deploy.DeploymentError, "Multiple"):
            deploy.select_device(phones)
        self.assertEqual(deploy.select_device(phones, "Second")["identifier"], "device-2")

    def test_unpaired_simulator_and_wireless_offline_are_rejected(self):
        for variant in ("unpaired", "simulator", "offline"):
            d = device()
            if variant == "unpaired":
                d["connectionProperties"]["pairingState"] = "unpaired"
            elif variant == "simulator":
                d["hardwareProperties"]["reality"] = "simulated"
            else:
                d["connectionProperties"]["transportType"] = "network"
            with self.subTest(variant=variant), self.assertRaises(deploy.DeploymentError):
                deploy.select_device([d])

    def test_developer_mode_must_be_enabled(self):
        d = device(); d["deviceProperties"]["developerModeStatus"] = "disabled"
        with self.assertRaisesRegex(deploy.DeploymentError, "Developer Mode"):
            deploy.select_device([d])

    def test_registered_distribution_profile_is_accepted(self):
        self.assertEqual(deploy.validate_profile(profile(), deploy.APP_ID, "registered", b"certificate"), "TEAM")

    def test_invalid_profiles_stop_before_build_or_install(self):
        for field, value in (("ExpirationDate", dt.datetime(2020, 1, 1)),
                             ("ProvisionedDevices", []), ("DeveloperCertificates", [b"other"]),
                             ("TeamIdentifier", ["OTHER"])):
            p = profile(); p[field] = value
            with self.subTest(field=field), self.assertRaises(deploy.DeploymentError):
                deploy.validate_profile(p, deploy.APP_ID, "registered", b"certificate")
        p = profile(); p["Entitlements"]["get-task-allow"] = True
        with self.assertRaises(deploy.DeploymentError):
            deploy.validate_profile(p, deploy.APP_ID, "registered", b"certificate")

    def test_entitlements_keep_production_cloud_and_app_group(self):
        source = {"aps-environment": "development",
                  "com.apple.security.application-groups": ["group.com.neoanki2.shared"],
                  "com.apple.developer.icloud-container-identifiers": ["iCloud.com.neoanki2.app"],
                  "com.apple.developer.icloud-services": ["CloudKit"]}
        e = deploy.make_entitlements(source, profile(), "TEAM", deploy.APP_ID)
        self.assertEqual(e["aps-environment"], "production")
        self.assertEqual(e["com.apple.developer.icloud-container-environment"], "Production")
        self.assertEqual(e["com.apple.developer.ubiquity-kvstore-identifier"], "TEAM." + deploy.APP_ID)
        self.assertEqual(e["keychain-access-groups"], ["TEAM." + deploy.APP_ID])
        self.assertEqual(source["aps-environment"], "development")
        for missing in ("com.apple.security.application-groups", "com.apple.developer.icloud-container-identifiers",
                        "com.apple.developer.icloud-container-environment", "aps-environment"):
            p = profile(); del p["Entitlements"][missing]
            with self.subTest(missing=missing), self.assertRaises(deploy.DeploymentError):
                deploy.make_entitlements(source, p, "TEAM", deploy.APP_ID)

    def test_install_receipt_requires_target_device_and_app(self):
        data = {"info": {"outcome": "success"}, "result": {"deviceIdentifier": "device-1",
                "installedApplications": [{"bundleID": deploy.APP_ID}]}}
        deploy.validate_receipt(data, "device-1", "Install")
        for d in ("other-device",):
            with self.assertRaises(deploy.DeploymentError):
                deploy.validate_receipt(data, d, "Install")
        bad = copy.deepcopy(data); bad["result"]["installedApplications"][0]["bundleID"] = "another.app"
        with self.assertRaises(deploy.DeploymentError):
            deploy.validate_receipt(bad, "device-1", "Install")

    def test_launch_receipt_requires_success_and_actual_app_process(self):
        data = {"info": {"outcome": "success"}, "result": {"deviceIdentifier": "device-1",
                "process": {"processIdentifier": 100, "executable": "file:///bundle/NeoAnki2.app/NeoAnki2"}}}
        deploy.validate_receipt(data, "device-1", "Launch")
        bad = copy.deepcopy(data); bad["info"]["outcome"] = "failure"
        with self.assertRaises(deploy.DeploymentError):
            deploy.validate_receipt(bad, "device-1", "Launch")
        bad = copy.deepcopy(data); bad["result"]["process"]["processIdentifier"] = 0
        with self.assertRaises(deploy.DeploymentError):
            deploy.validate_receipt(bad, "device-1", "Launch")

    def test_password_is_redacted_and_timeout_does_not_echo_argv(self):
        flow = deploy.Workflow(Path("unused")); flow.passwords = ["synthetic-secret"]
        with patch.object(deploy.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"synthetic-secret denied")):
            with self.assertRaises(deploy.DeploymentError) as caught:
                flow.run(["security", "-p", "synthetic-secret"])
            self.assertNotIn("synthetic-secret", str(caught.exception))
        with patch.object(deploy.subprocess, "run", side_effect=subprocess.TimeoutExpired(["security", "synthetic-secret"], 30)):
            with self.assertRaises(deploy.DeploymentError) as caught:
                flow.run(["security", "synthetic-secret"])
            self.assertNotIn("synthetic-secret", str(caught.exception))

    def test_signing_failure_removes_only_temporary_keychain(self):
        self.check_signing_cleanup()

    def test_keychain_delete_failure_still_removes_search_entry(self):
        self.check_signing_cleanup(deletion_fails=True)

    def check_signing_cleanup(self, deletion_fails=False):
        flow = deploy.Workflow(Path("unused")); calls = []; temporary = []
        def run(args, **kwargs):
            calls.append(args)
            if args[:2] == ["openssl", "pkcs12"]:
                Path(args[args.index("-out") + 1]).touch()
            if args[:2] == ["security", "create-keychain"]:
                temporary.append(Path(args[-1])); temporary[0].touch()
            if args[:2] == ["security", "delete-keychain"]:
                if deletion_fails:
                    raise deploy.DeploymentError("injected delete failure")
                temporary[0].unlink()
            if args == ["security", "list-keychains", "-d", "user"]:
                return ('"/existing/login"\n"/existing/concurrent"\n"' + str(temporary[0]) + '"\n').encode()
            return b""
        with patch.object(flow, "run", side_effect=run):
            with self.assertRaisesRegex(deploy.DeploymentError, "cleanup failed" if deletion_fails else "sign failed"):
                with flow.signing_keychain(Path("fixture-signing")):
                    raise deploy.DeploymentError("sign failed")
        self.assertFalse(temporary[0].exists())
        self.assertIn(["security", "list-keychains", "-d", "user", "-s", "/existing/login", "/existing/concurrent"], calls)
        self.assertFalse(any("NeoAnki2-signing.keychain-db" in arg for args in calls for arg in args))


if __name__ == "__main__":
    unittest.main()
