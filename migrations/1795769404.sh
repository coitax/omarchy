echo "Stop foot from answering OSC 52 clipboard reads"

# foot defaults security.osc52 to enabled, which replies to an OSC 52 query with
# the local clipboard, so any remote host or container shell could read it. Only
# configs that never chose a mode are changed; an explicit osc52 line is kept.

foot_config="$HOME/.config/foot/foot.ini"

[[ -f $foot_config ]] || exit 0

if awk '
  /^[[:space:]]*\[/ { section = $0; gsub(/[[:space:]]/, "", section) }
  section == "[security]" && /^[[:space:]]*osc52[[:space:]]*=/ { found = 1 }
  END { exit found ? 0 : 1 }
' "$foot_config"; then
  exit 0
fi

comment="# Let remote programs copy to the clipboard over OSC 52, but never read it back."

if grep -Eq '^[[:space:]]*\[security\][[:space:]]*$' "$foot_config"; then
  tmp=$(mktemp)
  COMMENT="$comment" awk '
    { print }
    !inserted && /^[[:space:]]*\[security\][[:space:]]*$/ {
      print ENVIRON["COMMENT"]
      print "osc52=copy-enabled"
      inserted = 1
    }
  ' "$foot_config" >"$tmp"
  cat "$tmp" >"$foot_config"
  rm -f "$tmp"
else
  printf '\n[security]\n%s\nosc52=copy-enabled\n' "$comment" >>"$foot_config"
fi
