#!/bin/bash
#
# Docker containers reach the host resolver on the bridge address 172.17.0.1.
# The firewall may allow that only from Docker bridge interfaces. A rule keyed
# only by a source range also matches ordinary LAN addresses, and under the
# kernel's weak host model a neighbor can send those packets at 172.17.0.1 via
# the laptop's Wi-Fi address. Limiting the source range is not enough: loose
# reverse-path filtering still accepts a LAN packet whose source looks like a
# container.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

engine="$ROOT/test/shell.d/fixtures/docker-dns-firewall-engine.js"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

stub_dir="$test_dir/bin"
state="$test_dir/ufw-state.json"
mkdir -p "$stub_dir"
printf '%s\n' '{"rules":[]}' >"$state"

cat >"$stub_dir/ufw" <<EOF
#!/bin/bash
exec node "$engine" "$state" "\$@"
EOF

cat >"$stub_dir/ufw-docker" <<'STUB'
#!/bin/bash
set -euo pipefail
PATH="/bin:/usr/bin:/sbin:/usr/sbin:/snap/bin/"
if ! ufw status 2>/dev/null | grep -Fq 'Status: active'; then
  echo 'inactive' >&2
  exit 1
fi
STUB

cat >"$stub_dir/sed" <<'STUB'
#!/bin/bash
if [[ ${1:-} == 0,/^PATH=* ]]; then
  exec /usr/bin/sed "$@"
fi
exit 0
STUB

cat >"$stub_dir/systemctl" <<'STUB'
#!/bin/bash
exit 0
STUB

chmod +x "$stub_dir"/*

PATH="$stub_dir:$PATH" bash -eE -c 'source "$1"' bash "$ROOT/install/config/firewall.sh"

if grep -F 'from 192.168.0.0/16 to 172.17.0.1 port 53' "$ROOT/bin/omarchy-upgrade-to-quattro" >/dev/null; then
  fail "Omarchy 4 upgrade does not allow LAN clients to query the Docker DNS address"
fi
if grep -F 'from 172.16.0.0/12 to 172.17.0.1 port 53' "$ROOT/bin/omarchy-upgrade-to-quattro" >/dev/null; then
  fail "Omarchy 4 upgrade does not allow 172.16.0.0/12 clients to query the Docker DNS address"
fi
grep -F '/usr/share/omarchy/install/config/firewall.sh' "$ROOT/bin/omarchy-upgrade-to-quattro" >/dev/null ||
  fail "Omarchy 4 upgrade applies the packaged firewall script"

if ! node "$engine" --check "$state" "fresh install"; then
  fail "fresh install firewall rules keep Docker DNS on Docker bridges"
fi

pass "fresh install firewall rules keep Docker DNS on Docker bridges"
