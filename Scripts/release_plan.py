"""Pure release planning: app dependency closures, input snapshots and versions."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


CHANNELS = ("ios", "mac", "homebrew")


def command(root, *args):
    return subprocess.check_output(args, cwd=root)


def version_tuple(value):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", value)
    if not match:
        raise ValueError("Expected a three-part version, received " + value)
    return tuple(map(int, match.groups()))


def next_version(versions):
    major, minor, patch = max(map(version_tuple, versions))
    return f"{major}.{minor}.{patch + 1}"


def tree(root, revision=None):
    """Use Git blob identities for both released trees and dirty local input."""
    if revision:
        result = {}
        for row in command(root, "git", "ls-tree", "-rz", "--full-tree", revision).split(b"\0"):
            if not row:
                continue
            header, path = row.split(b"\t", 1)
            mode, kind, oid = header.decode().split()
            if kind == "blob":
                result[os.fsdecode(path)] = mode + ":" + oid
        return result
    paths = command(root, "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    result = {}
    for raw in set(paths.split(b"\0")) - {b""}:
        name = os.fsdecode(raw)
        path = Path(root) / name
        if path.is_symlink():
            content, mode = os.fsencode(os.readlink(path)), "120000"
        elif path.is_file():
            content = path.read_bytes()
            mode = "100755" if path.stat().st_mode & 0o111 else "100644"
        else:
            continue
        oid = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        result[name] = mode + ":" + oid
    return result


class AppInputs:
    def __init__(self, packages, ios_products):
        self.targets = {}
        self.products = {}
        for prefix, package in packages.items():
            for product in package["products"]:
                self.products.setdefault(product["name"], []).extend(
                    prefix + name for name in product["targets"]
                )
            for target in package["targets"]:
                key = prefix + target["name"]
                default = ("Tests/" if target["type"] == "test" else "Sources/") + target["name"]
                self.targets[key] = dict(target, input_path=prefix + (target.get("path") or default))
        self.roots = {
            "mac": ["NeoAnki2"],
            "ios": [target for product in ios_products for target in self.products[product]],
        }
        self.closures = {platform: self.closure(roots, platform) for platform, roots in self.roots.items()}

    @classmethod
    def load(cls, root):
        packages = {}
        for prefix in ("", "NeoAnkiCore/"):
            packages[prefix] = json.loads(command(Path(root) / prefix, "swift", "package", "dump-package"))
        project = json.loads(command(root, "plutil", "-convert", "json", "-o", "-",
                                     "Xcode/NeoAnkiiOS.xcodeproj/project.pbxproj"))
        objects = project["objects"]
        # Read actual application/extension products, excluding the UI test target.
        ids = [product for obj in objects.values() if obj.get("productType") in (
            "com.apple.product-type.application", "com.apple.product-type.app-extension"
        ) for product in obj.get("packageProductDependencies", [])]
        products = {objects[identifier]["productName"] for identifier in ids}
        if not products:
            raise ValueError("Cannot identify iOS application package products")
        return cls(packages, products)

    def dependencies(self, key, platform):
        prefix = key[:key.rfind("/") + 1]
        result = []
        for dependency in self.targets[key]["dependencies"]:
            kind, values = next(iter(dependency.items()))
            conditions = [v for v in values[1:] if isinstance(v, dict) and "platformNames" in v]
            if conditions and ("macos" if platform == "mac" else "ios") not in conditions[0]["platformNames"]:
                continue
            local = prefix + values[0]
            if kind != "product" and local in self.targets:
                result.append(local)
            else:
                result.extend(self.products.get(values[0], []))
        return result

    def closure(self, roots, platform):
        seen, queue = set(), list(roots)
        while queue:
            key = queue.pop()
            if key in seen:
                continue
            if key not in self.targets:
                raise ValueError("Unknown application dependency: " + key)
            seen.add(key)
            queue.extend(self.dependencies(key, platform))
        return seen

    def includes(self, path, platform):
        if path in ("Package.swift", "Package.resolved", "NeoAnkiCore/Package.swift", "NeoAnkiCore/Package.resolved"):
            return True
        if path.startswith(".swiftpm/configuration/"):
            return True
        prefixes = ("Platforms/iOS/", "Platforms/iOSWidget/", "Xcode/NeoAnkiiOS.xcodeproj/") if platform == "ios" else (
            "Packaging/", "Xcode/NeoAnkiMac.xcodeproj/"
        )
        if path.startswith(prefixes):
            return True
        if platform == "mac" and path in (
            "Scripts/install-app.sh", "Scripts/build-release-artifact.sh",
            "Scripts/archive-macos-release.sh", "Scripts/sign-macos-app.py",
        ):
            return True
        return any(path == self.targets[t]["input_path"] or path.startswith(self.targets[t]["input_path"] + "/")
                   for t in self.closures[platform])

    def snapshot(self, files, platform):
        return {p: value for p, value in sorted(files.items()) if self.includes(p, platform)}

    def tests(self, changed_paths, selected):
        changed = {name for name, target in self.targets.items() if any(
            p.startswith(target["input_path"] + "/") for p in changed_paths)}
        result = {}
        for name, target in self.targets.items():
            if target["type"] != "test":
                continue
            if any(changed & self.closure([name], platform) for platform in selected):
                prefix = name[:name.rfind("/") + 1]
                result.setdefault(prefix, []).append(target["name"])
        # Manifest changes can change dependencies without touching a source file.
        if any(p.endswith(("Package.swift", "Package.resolved")) for p in changed_paths):
            for name, target in self.targets.items():
                if target["type"] == "test":
                    result.setdefault(name[:name.rfind("/") + 1], []).append(target["name"])
        return {prefix: sorted(set(names)) for prefix, names in result.items()}


def plan(root, baseline, inputs, files=None):
    files = tree(root) if files is None else files
    snapshots = {p: inputs.snapshot(files, p) for p in ("ios", "mac")}
    changed, reasons = set(), {}
    for channel in CHANNELS:
        platform = "ios" if channel == "ios" else "mac"
        prior = baseline["channels"][channel]
        before = prior.get("inputs")
        if before is None:
            before = inputs.snapshot(tree(root, prior["revision"]), platform)
        paths = sorted(p for p in set(before) | set(snapshots[platform])
                       if before.get(p) != snapshots[platform].get(p))
        if paths:
            changed.add(platform)
            reasons.setdefault(platform, set()).update(paths)
    channels = [c for c in CHANNELS if ("ios" if c == "ios" else "mac") in changed]
    paths = sorted(set().union(*reasons.values())) if reasons else []
    return {"channels": channels, "inputs": snapshots, "changed_paths": paths,
            "tests": inputs.tests(paths, changed), "version": next_version([baseline["version"]])}
