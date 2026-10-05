#!/usr/bin/env bash
set -euo pipefail

# Decode credentials only on the ephemeral runner; no persistent Keychain or
# Apple ID password is needed. The signer owns its disposable Keychain.
python3 - <<'PYTHON'
import base64
import json
import os
from pathlib import Path
import subprocess

os.umask(0o077)
folder = Path(os.environ["RUNNER_TEMP"]) / "neoanki-signing-material"
folder.mkdir(mode=0o700, exist_ok=True)
inputs = {
    "APPLE_DEVELOPER_ID_P12_BASE64": "identity.p12",
    "APPLE_DEVELOPER_ID_PROFILE_BASE64": "Mac-DeveloperID.provisionprofile",
    "APPLE_DEVELOPER_ID_CHAIN_BASE64": "DeveloperIDG2CA.cer",
    "APPLE_NOTARY_KEY_BASE64": "notary-key.p8",
}
for variable, filename in inputs.items():
    if not os.environ.get(variable):
        raise SystemExit("Missing signing secret: " + variable)
    (folder / filename).write_bytes(base64.b64decode(os.environ[variable], validate=True))
for variable in ("APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_ISSUER_ID", "APPLE_DEVELOPMENT_TEAM"):
    if not os.environ.get(variable):
        raise SystemExit("Missing signing secret: " + variable)
for flags, filename in ((["-nocerts", "-nodes"], "Developer-ID-Application.key.pem"),
                        (["-clcerts", "-nokeys"], "Developer-ID-Application.cert.pem")):
    result = subprocess.run(["openssl", "pkcs12", "-in", str(folder / "identity.p12"),
                             "-passin", "env:APPLE_DEVELOPER_ID_P12_PASSWORD", *flags],
                            capture_output=True, stdin=subprocess.DEVNULL)
    if result.returncode:
        raise SystemExit("Cannot decode Developer ID identity")
    (folder / filename).write_bytes(result.stdout)
(folder / "identity.p12").unlink()
(folder / "app-store-connect.json").write_text(json.dumps({
    "key_id": os.environ["APPLE_NOTARY_KEY_ID"],
    "issuer_id": os.environ["APPLE_NOTARY_ISSUER_ID"],
    "private_key_path": str(folder / "notary-key.p8"),
    "team_id": os.environ["APPLE_DEVELOPMENT_TEAM"],
}))
with Path(os.environ["GITHUB_ENV"]).open("a") as stream:
    stream.write("NEOANKI_SIGNING_DIR=" + str(folder) + "\n")
PYTHON
