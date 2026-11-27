echo "Stop Sunshine Admin from disabling certificate checks in the everyday browser"

# The Sunshine installer used to write this exact Exec line. Leave any entry the
# user has rewritten alone; omarchy-launch-webapp drops the switch either way.
desktop="$HOME/.local/share/applications/Sunshine Admin.desktop"
legacy_exec="Exec=omarchy-launch-webapp https://localhost:47990 --ignore-certificate-errors"

[[ -f $desktop ]] || exit 0
grep -Fxq "$legacy_exec" "$desktop" || exit 0

sed -i "s|^$legacy_exec\$|Exec=omarchy-launch-webapp https://localhost:47990|" "$desktop"
