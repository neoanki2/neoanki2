#!/usr/bin/env python3
"""Exercise the actual shell runner with fake SDK tools; no Simulator is launched."""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
FAKE_TOOL = '''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
with open(os.environ['FAKE_COMMANDS'], 'a') as f: f.write(json.dumps([pathlib.Path(sys.argv[0]).name,*args])+'\\n')
if pathlib.Path(sys.argv[0]).name=='xcodebuild':
 if args==['-version']: print('Fake Xcode\\nBuild version TEST')
 else:
  pathlib.Path(args[args.index('-resultBundlePath')+1]).mkdir()
  print('Actual runner lifecycle was invoked')
  sys.exit(int(os.environ['FAKE_TEST_STATUS']))
elif args[:3]==['simctl','list','runtimes']:
 print(json.dumps({'runtimes':[{'isAvailable':True,'identifier':'fake.SimRuntime.iOS-26-5','version':'26.5'}]}))
elif args[:3]==['simctl','list','devicetypes']:
 print(json.dumps({'devicetypes':[{'name':'Test iPhone','identifier':'fake.type'}]}))
elif args[:2]==['simctl','create']: print('OWNED-SIMULATOR')
elif args[:2]==['simctl','ui'] and len(args)==4: print('enabled')
elif args[:4]==['xcresulttool','get','test-results','summary']: print(os.environ['FAKE_SUMMARY'])
'''


class IOSRunnerLifecycleTests(unittest.TestCase):
    def exercise(self, status=0, **summary):
        summary = {"result": "Passed", "totalTestCount": 2, "passedTests": 2,
                   "failedTests": 0, "skippedTests": 0, **summary}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts, tools = root / "Scripts", root / "fake-tools"
            scripts.mkdir(); tools.mkdir()
            for name in ["run-ios-ui-tests.sh", "classify-ios-ui-result.jq"]:
                shutil.copy2(SCRIPTS / name, scripts / name)
            for name in ["xcodebuild", "xcrun"]:
                path = tools / name; path.write_text(FAKE_TOOL); path.chmod(0o755)
            artifact = root / ".build/ios-ui-artifact"; artifact.mkdir(parents=True)
            archive = artifact / "build-products.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                data = b"fake xctestrun"
                entry = tarfile.TarInfo(".build/ios-ui-derived-data/Build/Products/test.xctestrun")
                entry.size = len(data); output.addfile(entry, io.BytesIO(data))
            (artifact / "metadata.json").write_text(json.dumps({"schema_version": 1,
                "commit_sha": "test-revision", "xcode_version": "Fake Xcode;Build version TEST",
                "architecture": platform.machine(), "workspace_path": str(root),
                "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}))
            commands = root / "commands.jsonl"
            env = dict(os.environ, PATH=str(tools)+os.pathsep+os.environ["PATH"], DEVICE="Test iPhone",
                GITHUB_SHA="test-revision", NEOANKI_IOS_UI_SHARD="lifecycle",
                NEOANKI_IOS_UI_ONLY_TESTING="Bundle/Case/first,Bundle/Case/second",
                NEOANKI_IOS_UI_PARALLEL_WORKERS="1", FAKE_COMMANDS=str(commands),
                FAKE_TEST_STATUS=str(status), FAKE_SUMMARY=json.dumps(summary))
            result = subprocess.run(["bash", str(scripts / "run-ios-ui-tests.sh")], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=20)
            calls = [json.loads(line) for line in commands.read_text().splitlines()]
            tests = [c for c in calls if "test-without-building" in c]
            self.assertEqual(len(tests), 1, result.stdout+result.stderr)
            self.assertIn("-only-testing:Bundle/Case/first", tests[0])
            self.assertIn("-only-testing:Bundle/Case/second", tests[0])
            self.assertLess(calls.index(["xcrun", "simctl", "bootstatus", "OWNED-SIMULATOR", "-b"]), calls.index(tests[0]))
            self.assertIn(["xcrun", "simctl", "delete", "OWNED-SIMULATOR"], calls)
            self.assertTrue((root / ".build/ios-ui-results/attempt-1.xcresult").exists())
            self.assertTrue((root / ".build/ios-ui-results/attempt-1.log").exists())
            self.assertFalse((root / ".build/ios-ui-results/attempt-2.xcresult").exists())
            return result

    def test_all_selected_cases_pass_once(self):
        result = self.exercise()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_infrastructure_or_assertion_failure_is_not_automatically_retried(self):
        for message in ["test runner exited with code 74", "XCTAssertTrue failed"]:
            result = self.exercise(status=65, result="Failed", passedTests=1, failedTests=1,
                                   testFailures=[{"failureText": message}])
            self.assertEqual(result.returncode, 65, result.stdout+result.stderr)

    def test_zero_missing_selected_or_skipped_cases_fail_even_if_xcode_exits_zero(self):
        for summary in [{"totalTestCount": 0, "passedTests": 0},
                        {"totalTestCount": 1, "passedTests": 1},
                        {"passedTests": 1, "skippedTests": 1}]:
            result = self.exercise(**summary)
            self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)


if __name__ == "__main__": unittest.main()
