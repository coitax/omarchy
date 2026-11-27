echo "Stop Alacritty from answering OSC 52 clipboard reads"

# Earlier configs set terminal.osc52 to CopyPaste, which makes Alacritty reply to
# an OSC 52 query with the local clipboard, so any remote host or container shell
# could read it. Alacritty lowercases the value before matching, so every case
# and quoting variant enables the reply. OnlyCopy keeps remote copy working.

alacritty_config="$HOME/.config/alacritty/alacritty.toml"

[[ -f $alacritty_config ]] || exit 0

tmp=$(mktemp)
awk '
  {
    line = $0
    out = ""
    while (match(tolower(line), /osc52["'\'']?[[:space:]]*=[[:space:]]*["'\'']+copypaste["'\'']/)) {
      segment = substr(line, RSTART, RLENGTH)
      value = index(tolower(segment), "copypaste")
      out = out substr(line, 1, RSTART - 1) substr(segment, 1, value - 1) "OnlyCopy" substr(segment, value + 9)
      line = substr(line, RSTART + RLENGTH)
      changed = 1
    }
    print out line
  }
  END { exit changed ? 0 : 1 }
' "$alacritty_config" >"$tmp" && cat "$tmp" >"$alacritty_config"
rm -f "$tmp"
