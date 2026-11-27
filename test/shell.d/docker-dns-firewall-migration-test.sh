#!/bin/bash
#
# ufw allow appends. Machines that already ran the unrestricted Docker DNS
# rules keep them after install/config/firewall.sh is corrected, and the
# quattro upgrade command does not run again on those machines. A migration
# has to delete those rules and leave DNS reachable from Docker bridges only.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

engine="$ROOT/test/shell.d/fixtures/docker-dns-firewall-engine.js"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

shopt -s nullglob
candidates=()
for migration in "$ROOT"/migrations/*.sh; do
  if grep -qE 'allow-docker-dns|172\.17\.0\.1|install/config/firewall\.sh' "$migration"; then
    candidates+=("$migration")
  fi
done
shopt -u nullglob

if (( ${#candidates[@]} == 0 )); then
  fail "a migration removes unrestricted Docker DNS allows from installed machines"
fi

stub_dir="$test_dir/bin"
state="$test_dir/ufw-state.json"
mkdir -p "$stub_dir" "$test_dir/home"
node "$engine" --seed-installed "$state"

cat >"$stub_dir/ufw" <<EOF
#!/bin/bash
exec node "$engine" "$state" "\$@"
EOF

cat >"$stub_dir/sudo" <<'STUB'
#!/bin/bash
while [[ $# -gt 0 && $1 == -* ]]; do
  if [[ $1 == -- ]]; then
    shift
    break
  fi
  if [[ $1 == -u ]]; then
    shift 2
    continue
  fi
  shift
done
exec "$@"
STUB

cat >"$stub_dir/pkexec" <<'STUB'
#!/bin/bash
exec "$@"
STUB

chmod +x "$stub_dir"/*

for migration in "${candidates[@]}"; do
  HOME="$test_dir/home" OMARCHY_PATH="$ROOT" PATH="$stub_dir:$PATH" \
    bash -euo pipefail "$migration"
done

if ! node "$engine" --check "$state" "installed machine"; then
  fail "a migration removes unrestricted Docker DNS allows from installed machines"
fi

pass "a migration removes unrestricted Docker DNS allows from installed machines"
