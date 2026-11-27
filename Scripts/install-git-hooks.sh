#!/usr/bin/env bash
set -euo pipefail

hook_dir=$(git rev-parse --git-path hooks)
mkdir -p "$hook_dir"
hook="$hook_dir/pre-push"
launcher=$(cat <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
hook="$root/Scripts/githooks/pre-push"
if [[ ! -x "$hook" ]]; then
  printf 'Pre-push: this branch is missing the validation hook. Integrate current main before pushing.\n' >&2
  exit 1
fi
exec "$hook" "$@"
SCRIPT
)
if [[ -e "$hook" || -L "$hook" ]]; then
  if [[ -L "$hook" || "$(cat "$hook")" != "$launcher" ]]; then
    printf 'The existing pre-push hook at %s needs to be preserved.\n' "$hook" >&2
    exit 1
  fi
else
  (set -o noclobber; printf '%s\n' "$launcher" > "$hook")
fi
chmod u+x "$hook"
printf 'Installed the NeoAnki2 pre-push hook at %s.\n' "$hook"
