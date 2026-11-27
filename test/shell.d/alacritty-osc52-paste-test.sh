#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

# Alacritty 0.17.0 lowercases terminal.osc52 (StringVisitor) and then matches
# disabled / onlycopy / onlypaste / copypaste. onlypaste and copypaste both
# answer an OSC 52 query by writing the clipboard back to the PTY. Any other
# string is rejected and the field stays at the default, onlycopy.

# Exit 0 when the config answers clipboard reads, 1 when it does not, and 2
# when the file cannot be parsed. A parse error fails the test so a broken
# file cannot pass as a fix.
paste_enabled() {
  local file="$1"

  python3 - "$file" <<'PY'
import sys
import tomllib

try:
    with open(sys.argv[1], "rb") as handle:
        data = tomllib.load(handle)
except (OSError, tomllib.TOMLDecodeError) as err:
    print(err, file=sys.stderr)
    sys.exit(2)

terminal = data.get("terminal") or {}
raw = terminal.get("osc52")
if isinstance(raw, str) and raw.lower() in ("copypaste", "onlypaste"):
    sys.exit(0)

sys.exit(1)
PY
}

assert_paste_disabled() {
  local file="$1"
  local description="$2"
  local status=0

  [[ -f $file ]] || fail "$description" "missing $file"
  paste_enabled "$file" || status=$?
  if (( status == 0 )); then
    fail "$description" "OSC 52 paste is enabled in $file"
  elif (( status != 1 )); then
    fail "$description" "could not parse $file"
  fi
  pass "$description"
}

# Existing installs keep a full Alacritty config. Rewrite only the mode so
# keybinding migrations still see the file they expect, and so a case variant
# Alacritty's visitor accepts is what the migration has to repair.
write_osc52_mode() {
  local source="$1"
  local dest="$2"
  local literal="$3"

  python3 - "$source" "$dest" "$literal" <<'PY'
import pathlib
import re
import sys

source, dest, literal = sys.argv[1:]
text = pathlib.Path(source).read_text()
replacement = "osc52 = " + literal
updated, count = re.subn(r"(?m)^osc52\s*=\s*.*$", replacement, text, count=1)
if count == 0:
    updated, count = re.subn(r"(?m)^\[terminal\]\s*$", "[terminal]\n" + replacement, text, count=1)
if count != 1:
    sys.exit("could not set osc52 in " + source)
pathlib.Path(dest).write_text(updated)
PY
}

apply_alacritty_migrations() {
  local home="$1"
  local migration

  for migration in "$ROOT"/migrations/*.sh; do
    [[ -f $migration ]] || continue
    if grep -Eq 'alacritty|osc52' "$migration"; then
      HOME="$home" OMARCHY_PATH="$ROOT" bash -euo pipefail "$migration" >/dev/null
    fi
  done
}

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

stub_bin="$test_root/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-pkg-add" <<'STUB'
#!/bin/bash
exit 0
STUB

cat >"$stub_bin/omarchy-notification-send" <<'STUB'
#!/bin/bash
exit 0
STUB

cat >"$stub_bin/omarchy-launch-floating-terminal-with-presentation" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >"$LAUNCH_LOG"
exit 0
STUB

chmod +x "$stub_bin"/*

export LAUNCH_LOG="$test_root/launch.log"
export PATH="$stub_bin:$ROOT/bin:$PATH"
export OMARCHY_PATH="$ROOT"

shipped="$ROOT/config/alacritty/alacritty.toml"
assert_paste_disabled "$shipped" "shipped Alacritty config does not answer OSC 52 clipboard reads"

install_home="$test_root/install-home"
mkdir -p "$install_home/.config"
HOME="$install_home" omarchy-install-terminal alacritty >/dev/null
assert_paste_disabled \
  "$install_home/.config/alacritty/alacritty.toml" \
  "omarchy-install-terminal copies an Alacritty config that does not answer OSC 52 clipboard reads"

default_home="$test_root/default-home"
mkdir -p "$default_home/.config"
HOME="$default_home" omarchy-default-terminal --install alacritty >/dev/null
assert_paste_disabled \
  "$default_home/.config/alacritty/alacritty.toml" \
  "omarchy-default-terminal --install copies an Alacritty config that does not answer OSC 52 clipboard reads"
grep -qx 'Alacritty.desktop' "$default_home/.config/xdg-terminals.list" \
  || fail "default terminal install records Alacritty as the xdg terminal"
pass "default terminal install records Alacritty as the xdg terminal"

: >"$LAUNCH_LOG"
delegate_home="$test_root/delegate-home"
mkdir -p "$delegate_home"
HOME="$delegate_home" omarchy-default-terminal alacritty >/dev/null
grep -F 'omarchy-default-terminal --install alacritty' "$LAUNCH_LOG" >/dev/null \
  || fail "menu default-terminal action installs Alacritty when the command is missing" "$(cat "$LAUNCH_LOG")"
pass "menu default-terminal action installs Alacritty when the command is missing"

menu="$ROOT/default/omarchy/omarchy-menu.jsonc"
grep -F '"setup.default.terminal.alacritty"' "$menu" >/dev/null \
  && grep -F '"action":"omarchy-default-terminal alacritty"' "$menu" >/dev/null \
  || fail "setup menu selects Alacritty through omarchy-default-terminal"
grep -F '"install.terminal.alacritty"' "$menu" >/dev/null \
  && grep -F 'omarchy-install-terminal alacritty' "$menu" >/dev/null \
  || fail "install menu installs Alacritty through omarchy-install-terminal"
pass "terminal menu entries install and select Alacritty"

declare -A paste_modes=(
  [shipped]='"CopyPaste"'
  [lower]='"copypaste"'
  [upper]="'COPYPASTE'"
)

for label in shipped lower upper; do
  case_home="$test_root/migrated-$label"
  mkdir -p "$case_home/.config/alacritty"
  write_osc52_mode "$shipped" "$case_home/.config/alacritty/alacritty.toml" "${paste_modes[$label]}"
  apply_alacritty_migrations "$case_home"
  assert_paste_disabled \
    "$case_home/.config/alacritty/alacritty.toml" \
    "migrations disable OSC 52 paste in an existing Alacritty config ($label)"
done

safe_home="$test_root/already-safe"
mkdir -p "$safe_home/.config/alacritty"
write_osc52_mode "$shipped" "$safe_home/.config/alacritty/alacritty.toml" '"OnlyCopy"'
apply_alacritty_migrations "$safe_home"
assert_paste_disabled \
  "$safe_home/.config/alacritty/alacritty.toml" \
  "migrations leave an Alacritty config that already refuses OSC 52 paste"
