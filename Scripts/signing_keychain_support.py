"""Certificate discovery for short-lived signing contexts; never changes trust."""
from pathlib import Path
import re


def search_list(run):
    return re.findall(r'"([^"]+)"', run(["security", "list-keychains", "-d", "user"]).decode())


def register(run, keychain):
    """--keychain selects private keys; chain building also needs this list."""
    keychain = Path(keychain).resolve()
    current = search_list(run)
    if not any(Path(path).resolve() == keychain for path in current):
        run(["security", "list-keychains", "-d", "user", "-s", *current, str(keychain)])


def unregister(run, keychain):
    """Remove only our entry, including /var versus /private/var aliases."""
    keychain = Path(keychain).resolve()
    current = search_list(run)
    remaining = [path for path in current if Path(path).resolve() != keychain]
    if remaining != current:
        run(["security", "list-keychains", "-d", "user", "-s", *remaining])


def verify_chain(run, certificate, policy="codeSign"):
    # Do not supply the intermediate explicitly or fetch it from the network:
    # verify discovery through the same search list codesign will actually use.
    run(["security", "verify-cert", "-c", str(certificate), "-p", policy, "-L"])
