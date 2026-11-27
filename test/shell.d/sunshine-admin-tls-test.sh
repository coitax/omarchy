#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Sunshine Admin must not start the everyday browser with certificate
# validation disabled. Chromium applies --ignore-certificate-errors to every
# request in that process, and a later launch of the same binary with the same
# user-data directory joins the running process instead of starting a clean one.
# --profile-directory selects a profile inside that directory, so it does not
# count as isolation. An empty user-data directory (and CHROME_USER_DATA_DIR)
# means the browser's default directory.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

home="$test_tmp/home"
mock_bin="$test_tmp/bin"
launch_log="$test_tmp/launch-log"
mkdir -p "$mock_bin" \
  "$home/.local/share/applications" \
  "$home/.config/hypr"

cat >"$mock_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$mock_bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$mock_bin/systemctl" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$mock_bin/xdg-settings" <<'SH'
#!/bin/bash
if [[ ${1:-} == "get" && ${2:-} == "default-web-browser" ]]; then
  printf '%s\n' "${OMARCHY_TEST_DEFAULT_BROWSER:-chromium.desktop}"
fi
exit 0
SH

cat >"$mock_bin/xdg-mime" <<'SH'
#!/bin/bash
if [[ $* == "query default x-scheme-handler/https" ]]; then
  printf '%s\n' "${OMARCHY_TEST_DEFAULT_BROWSER:-chromium.desktop}"
fi
exit 0
SH

cat >"$mock_bin/setsid" <<'SH'
#!/bin/bash
{
  printf 'CHROME_USER_DATA_DIR=%s\0' "${CHROME_USER_DATA_DIR-}"
  printf 'CHROME_CONFIG_HOME=%s\0' "${CHROME_CONFIG_HOME-}"
  printf 'XDG_CONFIG_HOME=%s\0' "${XDG_CONFIG_HOME-}"
  printf 'HOME=%s\0' "${HOME-}"
  printf '%s\0' "$@"
  printf '\036'
} >>"$OMARCHY_TEST_LAUNCH_LOG"
exit 0
SH

cat >"$mock_bin/systemd-run" <<'SH'
#!/bin/bash
{
  printf 'CHROME_USER_DATA_DIR=%s\0' "${CHROME_USER_DATA_DIR-}"
  printf 'CHROME_CONFIG_HOME=%s\0' "${CHROME_CONFIG_HOME-}"
  printf 'XDG_CONFIG_HOME=%s\0' "${XDG_CONFIG_HOME-}"
  printf 'HOME=%s\0' "${HOME-}"
  printf '%s\0' "$@"
  printf '\036'
} >>"$OMARCHY_TEST_BROWSER_LOG"
exit 0
SH

cat >"$mock_bin/uwsm-app" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_UWSM_LOG"
exit 0
SH

# launch-browser probes the binary with --help before starting it.
for browser_bin in chromium google-chrome-stable brave microsoft-edge-stable opera vivaldi helium; do
  cat >"$mock_bin/$browser_bin" <<'SH'
#!/bin/bash
exit 0
SH
done
chmod +x "$mock_bin"/*

write_browser_desktop() {
  local desktop_id=$1
  local exec_bin=$2
  cat >"$home/.local/share/applications/$desktop_id" <<EOF
[Desktop Entry]
Exec=$exec_bin %U
EOF
}

write_browser_desktop chromium.desktop chromium
write_browser_desktop google-chrome.desktop google-chrome-stable
write_browser_desktop brave-browser.desktop brave
write_browser_desktop microsoft-edge.desktop microsoft-edge-stable
write_browser_desktop opera.desktop opera
write_browser_desktop vivaldi.desktop vivaldi
write_browser_desktop helium.desktop helium
write_browser_desktop firefox.desktop firefox

reset_log() {
  : >"$launch_log"
}

# Print one launch record per line: data_dir<TAB>binary<TAB>args...
# data_dir is empty when the launch leaves the browser on its default directory.
extract_browser_launches() {
  local log=$1
  python3 - "$log" <<'PY'
import os
import sys

log_path = sys.argv[1]
data = open(log_path, "rb").read() if os.path.exists(log_path) else b""
for record in data.split(b"\036"):
    if not record:
        continue
    fields = record.split(b"\0")
    env = {}
    argv = []
    for field in fields:
        if not field:
            continue
        text = field.decode()
        if text.startswith("CHROME_USER_DATA_DIR=") and "CHROME_USER_DATA_DIR" not in env:
            env["CHROME_USER_DATA_DIR"] = text.split("=", 1)[1]
            continue
        if text.startswith("CHROME_CONFIG_HOME=") and "CHROME_CONFIG_HOME" not in env:
            env["CHROME_CONFIG_HOME"] = text.split("=", 1)[1]
            continue
        if text.startswith("XDG_CONFIG_HOME=") and "XDG_CONFIG_HOME" not in env:
            env["XDG_CONFIG_HOME"] = text.split("=", 1)[1]
            continue
        if text.startswith("HOME=") and "HOME" not in env:
            env["HOME"] = text.split("=", 1)[1]
            continue
        argv.append(text)
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]
    if not argv:
        continue
    binary = os.path.basename(argv[0])
    data_dir = env.get("CHROME_USER_DATA_DIR", "")
    previous = ""
    for arg in argv[1:]:
        if previous == "--user-data-dir":
            data_dir = arg
            break
        if arg.startswith("--user-data-dir="):
            data_dir = arg.split("=", 1)[1]
            break
        previous = arg
    if data_dir == "":
        data_dir = "-"
    config_home = env.get("CHROME_CONFIG_HOME") or env.get("XDG_CONFIG_HOME") or "-"
    sys.stdout.write(
        data_dir + "\t" + binary + "\t" + config_home + "\t" + "\t".join(argv[1:]) + "\n"
    )
PY
}

default_data_dir_for() {
  local binary=$1
  local home_dir=$2
  local config_home=$3
  local base=${config_home:-$home_dir/.config}
  case $binary in
  chromium) printf '%s' "$base/chromium" ;;
  google-chrome-stable | google-chrome) printf '%s' "$base/google-chrome" ;;
  brave | brave-browser) printf '%s' "$base/BraveSoftware/Brave-Browser" ;;
  microsoft-edge-stable | microsoft-edge) printf '%s' "$base/microsoft-edge" ;;
  opera) printf '%s' "$base/opera" ;;
  vivaldi) printf '%s' "$base/vivaldi" ;;
  helium) printf '%s' "$base/helium" ;;
  *) printf '%s' "$base/chromium" ;;
  esac
}

normalize_dir() {
  local dir=$1
  [[ -n $dir ]] || return 0
  if [[ $dir != /* ]]; then
    dir="$PWD/$dir"
  fi
  realpath -m "$dir"
}

# Directory the recorded launch will use. An explicit --user-data-dir or
# CHROME_USER_DATA_DIR wins. Otherwise Chromium derives the default from
# CHROME_CONFIG_HOME, then XDG_CONFIG_HOME, then ~/.config.
launch_profile_dir() {
  local data_dir=$1
  local binary=$2
  local config_home=$3
  local base=""

  if [[ $data_dir != "-" ]]; then
    normalize_dir "$data_dir"
    return
  fi
  if [[ $config_home != "-" ]]; then
    base=$config_home
  fi
  normalize_dir "$(default_data_dir_for "$binary" "$home" "$base")"
}

everyday_profile_dir() {
  local binary=$1
  normalize_dir "$(default_data_dir_for "$binary" "$home" "${XDG_CONFIG_HOME:-}")"
}

# A launch disables validation on the everyday profile when the ignore flag is
# present and the resolved user-data directory is the one later browsing uses.
# Pointing --user-data-dir at that same directory is still the everyday profile.
# --profile-directory is a folder inside it, so it does not count as isolation.
launch_disables_shared_profile() {
  local line=$1
  local data_dir binary config_home args arg
  local launch_dir everyday_dir flag=false

  IFS=$'\t' read -r data_dir binary config_home args <<<"$line"
  launch_dir=$(launch_profile_dir "$data_dir" "$binary" "$config_home")
  everyday_dir=$(everyday_profile_dir "$binary")
  if [[ $launch_dir != "$everyday_dir" ]]; then
    return 1
  fi

  IFS=$'\t' read -r -a argv <<<"$args"
  for arg in "${argv[@]:-}"; do
    [[ -n $arg ]] || continue
    if [[ $arg == "--ignore-certificate-errors" || $arg == --ignore-certificate-errors=* ]]; then
      flag=true
    fi
  done
  [[ $flag == "true" ]]
}

assert_launches_keep_shared_profile() {
  local description=$1
  local log=$2
  local line

  if [[ ! -s $log ]]; then
    fail "$description" "no browser launch was recorded"
  fi

  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if launch_disables_shared_profile "$line"; then
      fail "$description" "$line"
    fi
  done < <(extract_browser_launches "$log")
}

# Desktop Entry field unescape, then Exec tokenization, then run that command.
launch_desktop_exec() {
  local desktop=$1
  local exec_value
  exec_value=$(python3 - "$desktop" <<'PY'
import shlex
import sys

def unescape(value):
    out = []
    i = 0
    while i < len(value):
        if value[i] == "\\" and i + 1 < len(value):
            code = value[i + 1]
            mapping = {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}
            out.append(mapping.get(code, code))
            i += 2
            continue
        out.append(value[i])
        i += 1
    return "".join(out)

def split_exec(value):
    args = []
    current = []
    quoted = False
    escape = False
    i = 0
    while i < len(value):
        char = value[i]
        if escape:
            current.append(char)
            escape = False
        elif char == "\\":
            escape = True
        elif char == '"':
            quoted = not quoted
        elif char == " " and not quoted:
            if current:
                args.append("".join(current))
                current = []
        else:
            current.append(char)
        i += 1
    if current:
        args.append("".join(current))
    return args

text = open(sys.argv[1], encoding="utf-8").read().splitlines()
exec_line = next(line[5:] for line in text if line.startswith("Exec="))
sys.stdout.write(" ".join(shlex.quote(arg) for arg in split_exec(unescape(exec_line))))
PY
)

  reset_log
  local argv=()
  eval "argv=($exec_value)"

  HOME="$home" PATH="$mock_bin:$ROOT/bin:$PATH" \
    OMARCHY_TEST_LAUNCH_LOG="$launch_log" \
    OMARCHY_TEST_DEFAULT_BROWSER="${OMARCHY_TEST_DEFAULT_BROWSER:-chromium.desktop}" \
    "${argv[@]}"
}

installer_env() {
  HOME="$home" PATH="$mock_bin:$ROOT/bin:$PATH" \
    OMARCHY_TEST_LAUNCH_LOG="$launch_log" \
    OMARCHY_TEST_DEFAULT_BROWSER="${OMARCHY_TEST_DEFAULT_BROWSER:-chromium.desktop}" \
    "$@"
}

wait_for_launch_record() {
  local description=$1
  local attempt

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -s $launch_log ]] && grep -aq $'\036' "$launch_log"; then
      return 0
    fi
    sleep 0.05
  done
  fail "$description" "timed out waiting for the browser launch"
}

reset_log
installer_env bash "$ROOT/bin/omarchy-install-service-sunshine" >/dev/null
wait_for_launch_record "sunshine install launches the admin page without disabling TLS on the shared browser profile"

assert_launches_keep_shared_profile \
  "sunshine install launches the admin page without disabling TLS on the shared browser profile" \
  "$launch_log"
pass "sunshine install launches the admin page without disabling TLS on the shared browser profile"

desktop="$home/.local/share/applications/Sunshine Admin.desktop"
[[ -f $desktop ]] || fail "sunshine install writes the admin desktop entry"

launch_desktop_exec "$desktop"
assert_launches_keep_shared_profile \
  "sunshine admin desktop entry keeps TLS validation on the shared browser profile" \
  "$launch_log"
pass "sunshine admin desktop entry keeps TLS validation on the shared browser profile"

browser_log="$test_tmp/browser-log"
: >"$browser_log"
HOME="$home" PATH="$mock_bin:$ROOT/bin:$PATH" \
  OMARCHY_TEST_BROWSER_LOG="$browser_log" \
  OMARCHY_TEST_DEFAULT_BROWSER=chromium.desktop \
  bash "$ROOT/bin/omarchy-launch-browser" "https://example.test/after-sunshine"

sunshine_line=$(extract_browser_launches "$launch_log" | head -n 1)
browser_line=$(extract_browser_launches "$browser_log" | head -n 1)
[[ -n $sunshine_line && -n $browser_line ]] ||
  fail "sunshine admin and the browser launcher both record a command" "$sunshine_line // $browser_line"

IFS=$'\t' read -r sunshine_dir sunshine_bin sunshine_config _ <<<"$sunshine_line"
IFS=$'\t' read -r browser_dir browser_bin browser_config _ <<<"$browser_line"
[[ $sunshine_bin == "$browser_bin" ]] ||
  fail "sunshine admin and later browsing launch the same browser binary" \
    "admin=$sunshine_line browser=$browser_line"

sunshine_norm=$(launch_profile_dir "$sunshine_dir" "$sunshine_bin" "$sunshine_config")
browser_norm=$(launch_profile_dir "$browser_dir" "$browser_bin" "$browser_config")
if [[ $sunshine_norm == "$browser_norm" ]] && launch_disables_shared_profile "$sunshine_line"; then
  fail "later browser launches join a process whose certificate checks were disabled" \
    "admin=$sunshine_line browser=$browser_line"
fi
pass "later browser launches do not join a process with certificate checks disabled"

# The installer takes the default browser from xdg and the launcher has two
# branches: a Chromium-family desktop id is used as-is, and anything else is
# rewritten to chromium.desktop. Re-run the real installer on each id.
for desktop_id in \
  chromium.desktop \
  google-chrome.desktop \
  brave-browser.desktop \
  microsoft-edge.desktop \
  opera.desktop \
  vivaldi.desktop \
  helium.desktop \
  firefox.desktop; do
  rm -f "$home/.local/share/applications/Sunshine Admin.desktop"
  reset_log
  OMARCHY_TEST_DEFAULT_BROWSER=$desktop_id \
    installer_env bash "$ROOT/bin/omarchy-install-service-sunshine" >/dev/null
  wait_for_launch_record "sunshine install keeps TLS validation for default browser $desktop_id"
  assert_launches_keep_shared_profile \
    "sunshine install keeps TLS validation for default browser $desktop_id" \
    "$launch_log"

  OMARCHY_TEST_DEFAULT_BROWSER=$desktop_id \
    launch_desktop_exec "$home/.local/share/applications/Sunshine Admin.desktop"
  assert_launches_keep_shared_profile \
    "sunshine admin desktop entry keeps TLS validation for default browser $desktop_id" \
    "$launch_log"
done
pass "sunshine admin keeps TLS validation for every browser the launcher can start"
