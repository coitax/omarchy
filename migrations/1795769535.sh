echo "Stop tmux from answering OSC 52 clipboard queries"

# With set-clipboard on, tmux answers a pane's OSC 52 query with its newest paste
# buffer, so any remote host or container shell in a pane could read what was
# copied. A get-clipboard line the user already wrote is kept.

tmux_config="$HOME/.config/tmux/tmux.conf"

[[ -f $tmux_config ]] || exit 0
grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*get-clipboard[[:space:]]' "$tmux_config" && exit 0

comment="# Accept OSC 52 copies from panes, but never answer their clipboard queries."

if grep -qxF 'set -g set-clipboard on' "$tmux_config"; then
  tmp=$(mktemp)
  COMMENT="$comment" awk '
    { print }
    !inserted && $0 == "set -g set-clipboard on" {
      print ENVIRON["COMMENT"]
      print "set -g get-clipboard off"
      inserted = 1
    }
  ' "$tmux_config" >"$tmp"
  cat "$tmp" >"$tmux_config"
  rm -f "$tmp"
else
  printf '\n%s\nset -g get-clipboard off\n' "$comment" >>"$tmux_config"
fi

omarchy-restart-tmux
