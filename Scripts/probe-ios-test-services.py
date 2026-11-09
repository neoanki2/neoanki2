#!/usr/bin/env python3
"""Observe owned Simulator service activation; this is diagnostic, not a UI gate."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--helper', type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        parser.error('Run only on an isolated GitHub-hosted Mac')
    args.output.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location('readiness', args.helper)
    readiness = importlib.util.module_from_spec(spec); spec.loader.exec_module(readiness)
    def run(command, timeout=60):
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    def checked(command, timeout=60):
        result = run(command, timeout)
        if result.returncode: raise RuntimeError('Diagnostic command failed: ' + command[0])
        return result.stdout
    runtimes = json.loads(checked(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
    runtime = max((v for v in runtimes if v['isAvailable'] and '.iOS-' in v['identifier']), key=lambda v: tuple(map(int, v['version'].split('.'))))
    types = json.loads(checked(['xcrun', 'simctl', 'list', 'devicetypes', '-j']))['devicetypes']
    device = next(v for v in types if v['name'] == 'iPad Pro 13-inch (M5)')
    identifier = checked(['xcrun', 'simctl', 'create', 'NeoAnki2-ServiceProbe-' + uuid.uuid4().hex[:12], device['identifier'], runtime['identifier']]).strip()
    proof = {'diagnostic_only': True, 'runtime': runtime, 'simulator_id': identifier, 'simulator_deleted': False,
             'helper_sha256': hashlib.sha256(args.helper.read_bytes()).hexdigest(), 'observations': []}
    path = args.output / 'probe.json'
    def save(): path.write_text(json.dumps(proof, indent=2) + '\n')
    save()
    services = [('com.apple.dt.automationmode-writer', 'com.apple.dt.automationmode.reader'), ('com.apple.testmanagerd', 'com.apple.testmanagerd.control')]
    prefix = ['xcrun', 'simctl', 'spawn', identifier, 'launchctl']
    def label(service): return 'user/' + str(os.getuid()) + '/' + service
    def kick(service):
        result = run([*prefix, 'kickstart', '-p', label(service)], 180)
        (args.output / (service + '-kickstart.txt')).write_text(result.stdout + result.stderr)
        if result.returncode: raise RuntimeError('kickstart failed: ' + service)
    def observe(stage):
        flags = []
        for service, endpoint in services:
            result = run([*prefix, 'print', label(service)])
            filename = str(len(proof['observations'])) + '-' + service + '.txt'
            (args.output / filename).write_text(result.stdout + result.stderr)
            ready = result.returncode == 0 and readiness.service_ready(result.stdout, endpoint)
            proof['observations'].append({'stage': stage, 'service': service, 'ready': ready, 'file': filename, 'observed_at': time.time()})
            flags.append(ready)
        save()
        print('IOS_SERVICE_DIAGNOSTIC=' + stage + ' ready=' + str(flags), flush=True)
        return all(flags)
    try:
        checked(['xcrun', 'simctl', 'boot', identifier])
        boot = checked(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], 300)
        (args.output / 'boot.txt').write_text(boot)
        kick(services[0][0]); observe('writer-only')
        kick(services[1][0])
        deadline = time.monotonic() + 240
        proof['both_services_ready'] = False
        while time.monotonic() < deadline:
            if observe('both-started'):
                proof['both_services_ready'] = True
                break
            time.sleep(5)
        # Keep raw states even when the old predicate is never satisfied.
        save()
    finally:
        run(['xcrun', 'simctl', 'shutdown', identifier], 60)
        deleted = run(['xcrun', 'simctl', 'delete', identifier], 60)
        proof['simulator_deleted'] = deleted.returncode == 0; save()
        if not proof['simulator_deleted']: raise RuntimeError('Owned diagnostic Simulator was not deleted')
    print('IOS_SERVICE_DIAGNOSTIC_RECEIPT=' + str(path), flush=True)


if __name__ == '__main__': main()
