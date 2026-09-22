#!/usr/bin/env bash
# star_fetch-installer.sh — single-file installer for star_fetch on Fedora / KDE Plasma.
#
# star_fetch is a borderless, always-below Konsole widget that shows live
# RAM, CPU, battery, OS and uptime stats next to a small ascii scene.
#
# This one file carries everything the widget needs and sets all of it up:
#   ~/.local/share/star_fetch/star_fetch.sh        stats script
#   ~/.local/share/star_fetch/star_fetch.template  ascii layout
#   ~/.local/bin/star_fetch                        start/stop command
#   ~/.local/share/konsole/star_fetch.profile      Konsole profile
#   ~/.local/share/konsole/Blonde.colorscheme      Konsole color scheme (default)
#   ~/.local/share/konsole/StarFetchBlue.colorscheme  blue color scheme
#   ~/.config/kwinrulesrc                          KWin window rule
#
# Usage:
#   bash star_fetch-installer.sh [options]       install (or update in place)
#   bash star_fetch-installer.sh --uninstall     remove everything above
#
# Options:
#   --position X,Y   top-left corner of the widget in pixels   (default 1424,130)
#   --size W,H       widget size in pixels                     (default 310,180)
#   --autostart      also start the widget when you log in
#   --no-start       don't start the widget after installing
#   -h, --help       show this help
#
# After installing:
#   star_fetch          start the widget
#   star_fetch end      stop it
#   star_fetch blue     switch to the blue colors
#   star_fetch blonde   switch back to the blonde colors (default)

set -euo pipefail

DATA_DIR="$HOME/.local/share/star_fetch"
BIN_DIR="$HOME/.local/bin"
KONSOLE_DIR="$HOME/.local/share/konsole"
AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/star_fetch.desktop"
# Fixed id so re-running the installer updates the same KWin rule
# instead of adding a duplicate.
RULE_ID="4bf35db9-0ac7-4637-afb4-dfd61ca2972a"

POSITION="1424,130"
SIZE="310,180"
AUTOSTART=0
START=1
ACTION=install

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --position) POSITION="${2:?--position needs X,Y}"; shift 2 ;;
        --size)     SIZE="${2:?--size needs W,H}"; shift 2 ;;
        --autostart) AUTOSTART=1; shift ;;
        --no-start) START=0; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for pair in "$POSITION" "$SIZE"; do
    if ! [[ "$pair" =~ ^[0-9]+,[0-9]+$ ]]; then
        echo "Expected two numbers like 1424,130 — got '$pair'" >&2
        exit 1
    fi
done

reconfigure_kwin() {
    dbus-send --session --dest=org.kde.KWin --type=method_call \
        /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
}

# kwriteconfig6 can't delete a whole group, so drop the rule's section by hand.
delete_rule_group() {
    local rc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrulesrc"
    [ -f "$rc" ] || return 0
    awk -v g="[$RULE_ID]" '
        /^\[/ { skip = ($0 == g) }
        !skip
    ' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
}

# Matches the widget loop, and the watch-based widget from older installs.
WIDGET_PATTERN='star_fetch\.sh --loop$|^watch -ctn 30 .*star_fetch\.sh$|^/usr/bin/watch -ctn 30 .*star_fetch\.sh$'

stop_running_widget() {
    pkill -f "$WIDGET_PATTERN" 2>/dev/null || return 0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$WIDGET_PATTERN" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
}

# ---------------------------------------------------------------- uninstall
if [ "$ACTION" = uninstall ]; then
    echo "Uninstalling star_fetch..."
    stop_running_widget
    rm -rf "$DATA_DIR"
    rm -f "$BIN_DIR/star_fetch" "$KONSOLE_DIR/star_fetch.profile" "$AUTOSTART_FILE" \
        "$KONSOLE_DIR/StarFetchBlue.colorscheme"
    # Blonde.colorscheme is left in place: other Konsole profiles may use it.

    if command -v kwriteconfig6 >/dev/null 2>&1; then
        rules=$(kreadconfig6 --file kwinrulesrc --group General --key rules)
        rules=$(echo "$rules" | tr ',' '\n' | { grep -vx "$RULE_ID" || true; } | paste -sd, -)
        kwriteconfig6 --file kwinrulesrc --group General --key rules "$rules"
        kwriteconfig6 --file kwinrulesrc --group General --key count \
            "$(echo "$rules" | tr ',' '\n' | grep -c . || true)"
        delete_rule_group
        reconfigure_kwin
    fi
    echo "Done. star_fetch removed."
    exit 0
fi

# ---------------------------------------------------------------- dependencies
missing=()
need() { command -v "$1" >/dev/null 2>&1 || missing+=("$2"); }
need konsole       konsole
need free          procps-ng
need pgrep         procps-ng
need kwriteconfig6 kf6-kconfig
need kreadconfig6  kf6-kconfig
need dbus-send     dbus-tools
if [ ${#missing[@]} -gt 0 ]; then
    echo "star_fetch needs a few packages that aren't installed:" >&2
    echo "  sudo dnf install $(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')" >&2
    exit 1
fi
if ! fc-list 2>/dev/null | grep -q 'Hack-Regular'; then
    echo "Note: the Hack font isn't installed, so the widget's text won't fit its box exactly."
    echo "      (sudo dnf install source-foundry-hack-fonts)"
fi
if ! command -v upower >/dev/null 2>&1; then
    echo "Note: upower isn't installed, so battery fields will show N/A."
    echo "      (sudo dnf install upower)"
fi

echo "Installing star_fetch..."
mkdir -p "$DATA_DIR" "$BIN_DIR" "$KONSOLE_DIR"

# ---------------------------------------------------------------- data files
cat > "$DATA_DIR/star_fetch.sh" <<'STAR_FETCH_EOF'
#!/usr/bin/env bash
# star_fetch.sh — prints star_fetch.template with live system stats
# inserted one space after each ':' field.
# Keep this script next to star_fetch.template (same directory).
#
#   star_fetch.sh          print the stats once
#   star_fetch.sh --loop   widget mode: draw centered in the terminal,
#                          refresh every 30s and redraw at once on resize

set -u
# Fixed locale so `free`, upower and awk output parse the same everywhere,
# and so ${#line} counts characters, not bytes.
export LC_ALL=C.UTF-8
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/star_fetch.template"

# --- RAM usage: percent + used GB only (no total/ratio) ---
ram_pct() {
    free -b | awk '/^Mem:/ {
        printf "%.0f%% (%.1fGB)", ($3/$2)*100, $3/1073741824
    }'
}

# --- CPU usage: percent only ---
cpu_pct() {
    read -r _ u1 n1 s1 i1 w1 x1 y1 z1 _rest1 < /proc/stat
    sleep 0.3
    read -r _ u2 n2 s2 i2 w2 x2 y2 z2 _rest2 < /proc/stat
    local prev_idle=$((i1 + w1))
    local idle=$((i2 + w2))
    local prev_total=$((u1 + n1 + s1 + i1 + w1 + x1 + y1 + z1))
    local total=$((u2 + n2 + s2 + i2 + w2 + x2 + y2 + z2))
    local diff_total=$((total - prev_total))
    local diff_idle=$((idle - prev_idle))
    local pct=0
    if [ "$diff_total" -gt 0 ]; then
        pct=$(( (100 * (diff_total - diff_idle)) / diff_total ))
    fi
    echo "${pct}%"
}

# --- Shorten upower's spelled-out time units ---
shorten_units() {
    sed -e 's/\bhours\b/hrs/' -e 's/\bhour\b/hr/' -e 's/\bminutes\b/mins/' -e 's/\bminute\b/min/' \
        -e 's/\bseconds\b/secs/' -e 's/\bsecond\b/sec/'
}

# --- Battery: percentage, line label, and time (single upower query) ---
# Plugged in: "full charge in:" + time until 100% (0 secs once full).
# On battery: "uptime left:" + time until empty.
battery_info() {
    local label="full charge in:"
    if ! command -v upower >/dev/null 2>&1; then
        echo "N/A|$label|N/A"
        return
    fi
    local batt
    batt=$(upower -e 2>/dev/null | grep -m1 'battery_BAT\|BAT')
    if [ -z "$batt" ]; then
        echo "N/A|$label|N/A"
        return
    fi
    local info state pct left
    info=$(upower -i "$batt" 2>/dev/null)
    pct=$(echo "$info" | awk -F: '/percentage/ { gsub(/^[ \t]+/,"",$2); print $2 }')
    state=$(echo "$info" | awk '/state:/ {print $2}')
    case "$state" in
        discharging)
            label="uptime left:"
            left=$(echo "$info" | awk -F: '/time to empty/ { gsub(/^[ \t]+/,"",$2); print $2 }' | shorten_units)
            ;;
        charging|pending-charge|fully-charged)
            # upower keeps reporting a few seconds "to full" at 100%.
            if [ "$state" = fully-charged ] || [ "${pct%%%*}" = 100 ]; then
                left="0 secs"
            else
                left=$(echo "$info" | awk -F: '/time to full/ { gsub(/^[ \t]+/,"",$2); print $2 }' | shorten_units)
            fi
            [ "$state" = charging ] && pct="${pct} (⚡)"
            ;;
        *)
            left="N/A"
            ;;
    esac
    [ -z "$pct" ] && pct="N/A"
    [ -z "$left" ] && left="N/A"
    echo "${pct}|${label}|${left}"
}

# --- OS name: just distro + version, no edition suffix ---
os_name() {
    local name ver
    name=$(awk -F= '/^NAME=/ { gsub(/"/,"",$2); print $2 }' /etc/os-release)
    ver=$(awk -F= '/^VERSION_ID=/ { gsub(/"/,"",$2); print $2 }' /etc/os-release)
    echo "$name $ver"
}

# --- System uptime, decimal hours (matches the battery field's style) ---
uptime_str() {
    awk '{ printf "%.1f hrs", $1/3600 }' /proc/uptime
}

render() {
    local RAM CPU BATT_PCT BATT_LABEL BATT_LEFT OS UP
    RAM=$(ram_pct)
    CPU=$(cpu_pct)
    IFS='|' read -r BATT_PCT BATT_LABEL BATT_LEFT <<< "$(battery_info)"
    OS=$(os_name)
    UP=$(uptime_str)

    awk -v ram="$RAM" -v cpu="$CPU" -v battpct="$BATT_PCT" -v battlabel="$BATT_LABEL" -v battleft="$BATT_LEFT" -v os="$OS" -v up="$UP" '
        /ram% :/       { $0 = $0 " " ram }
        /cpu% :/       { $0 = $0 " " cpu }
        /battery:/     { $0 = $0 " " battpct }
        /full charge in:/ { sub(/full charge in:/, battlabel); $0 = $0 " " battleft }
        /os:/          { $0 = $0 " " os }
        /uptime:/      { $0 = $0 " " up }
        { print }
    ' "$TEMPLATE"
}

# --- Widget mode: center the block in the terminal ---
# The block is centered on a fixed width (widest template line + room for
# its value) so the text doesn't shift sideways as the numbers change.
VALUE_ROOM=8

draw() {
    local rows cols lines line width=0 top left i out
    read -r rows cols < <(stty size 2>/dev/null) || true
    rows=${rows:-12} cols=${cols:-38}

    while IFS= read -r line; do
        [ ${#line} -gt "$width" ] && width=${#line}
    done < "$TEMPLATE"
    width=$((width + VALUE_ROOM))

    mapfile -t lines < <(render)
    top=$(( (rows - ${#lines[@]}) / 2 )); [ "$top" -lt 0 ] && top=0
    left=$(( (cols - width) / 2 ));       [ "$left" -lt 0 ] && left=0

    # Home the cursor and overwrite in place (no full clear, so no flicker);
    # \e[K clears the rest of each row, \e[J everything below the block.
    out=$'\e[H'
    for ((i = 0; i < top; i++)); do out+=$'\e[K\n'; done
    for i in "${!lines[@]}"; do
        [ "$i" -gt 0 ] && out+=$'\n'
        out+="$(printf '%*s' "$left" '')${lines[$i]}"$'\e[K'
    done
    out+=$'\e[J'
    printf '%s' "$out"
}

if [ "${1:-}" = --loop ]; then
    # Hide the cursor and turn off line wrapping: a line too long for the
    # window gets clipped instead of pushing the rest of the text down.
    printf '\e[?25l\e[?7l\e[2J'
    nap=""
    trap 'resized=1; [ -n "$nap" ] && kill "$nap" 2>/dev/null' WINCH
    trap '[ -n "$nap" ] && kill "$nap" 2>/dev/null' EXIT
    while :; do
        resized=0
        draw
        [ "$resized" = 1 ] && continue
        #change the line below to increase or decrease the refresh time
        sleep 30 & nap=$!
        wait "$nap"
        nap=""
    done
else
    render
fi
STAR_FETCH_EOF
chmod +x "$DATA_DIR/star_fetch.sh"

cat > "$DATA_DIR/star_fetch.template" <<'STAR_FETCH_EOF'
      star_fetch ☆
⠀⠀⢰⡀⠀⠀⠀
⠀ ⣸⣿⣤⠖⠀    ram% :
⠉⠉⢹⣿⠿⠦⡀    cpu% :
⠀⠀⢸⣿⠀⠀⠀
⠀⠀ ⣿⠀⠀⠀    battery:
⠀⠀ ⡇⠀⠀⠀    full charge in:
⠀⠀⠀⡇⠀⠀⠀
⠀⠀⠀⠃⠀⠀     os:
⠀⠀⠀⠀⠀⠀     uptime:
STAR_FETCH_EOF

# ---------------------------------------------------------------- command
cat > "$BIN_DIR/star_fetch" <<'STAR_FETCH_EOF'
#!/usr/bin/env bash
# star_fetch — start/stop the star_fetch Konsole desktop widget
#
#   star_fetch          start the widget (no-op if already running)
#   star_fetch end      stop the widget
#   star_fetch blue     switch to the blue colors
#   star_fetch blonde   switch back to the blonde colors (default)

# Anchored so it only matches the widget itself, not some other command line
# that happens to mention star_fetch.sh.
PATTERN='star_fetch\.sh --loop$'
PROFILE="$HOME/.local/share/konsole/star_fetch.profile"

is_running() {
    pgrep -f "$PATTERN" >/dev/null 2>&1
}

start_widget() {
    if is_running; then
        echo "star_fetch is already running."
        return
    fi

    setsid konsole --profile star_fetch --hide-menubar --hide-tabbar \
        < /dev/null > /dev/null 2>&1 &
    disown

    # Konsole sets the window's real title a moment after it's first
    # mapped, which is often too late for KWin's window rule to catch
    # on that very first placement. Nudging KWin to re-check its rules
    # a second later re-applies the Force'd position/behavior once the
    # title has caught up.
    sleep 1
    dbus-send --session --dest=org.kde.KWin --type=method_call \
        /KWin org.kde.KWin.reconfigure 2>/dev/null

    echo "star_fetch started."
}

stop_widget() {
    if pkill -f "$PATTERN" 2>/dev/null; then
        # Wait for it to exit so a restart doesn't see it as still running.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            is_running || break
            sleep 0.2
        done
        echo "star_fetch stopped."
    else
        echo "star_fetch was not running."
    fi
}

# Konsole only reads a profile's colors when a window opens, so switching
# rewrites the profile and restarts the widget if it's up.
set_colors() {
    local name=$1 scheme=$2
    if [ ! -f "$PROFILE" ]; then
        echo "star_fetch isn't installed (no $PROFILE)." >&2
        exit 1
    fi
    kwriteconfig6 --file "$PROFILE" --group Appearance --key ColorScheme "$scheme"
    echo "star_fetch colors: $name"
    if is_running; then
        stop_widget >/dev/null
        start_widget
    fi
}

case "${1:-}" in
    ""|start)
        start_widget
        ;;
    end|stop)
        stop_widget
        ;;
    blue)
        set_colors blue StarFetchBlue
        ;;
    blonde)
        set_colors blonde Blonde
        ;;
    *)
        echo "Usage: star_fetch [end | blue | blonde]"
        exit 1
        ;;
esac
STAR_FETCH_EOF
chmod +x "$BIN_DIR/star_fetch"

# ---------------------------------------------------------------- Konsole
# Keep blue if it was picked with `star_fetch blue`; blonde otherwise.
SCHEME=Blonde
if grep -qx 'ColorScheme=StarFetchBlue' "$KONSOLE_DIR/star_fetch.profile" 2>/dev/null; then
    SCHEME=StarFetchBlue
fi

# Hack 10 is pinned because the default size (310x180) is measured for it:
# exactly 38x12 character cells, one blank row above and below the text.
cat > "$KONSOLE_DIR/star_fetch.profile" <<STAR_FETCH_EOF
[Appearance]
ColorScheme=$SCHEME
Font=Hack,10,-1,5,50,0,0,0,0,0

[General]
Command=$DATA_DIR/star_fetch.sh --loop
LocalTabTitleFormat=star_fetch
Name=star_fetch
Parent=FALLBACK/
TerminalCenter=true
TerminalColumns=38
TerminalMargin=0
TerminalRows=12

[Scrolling]
HistoryMode=0
ScrollBarPosition=2
STAR_FETCH_EOF

cat > "$KONSOLE_DIR/Blonde.colorscheme" <<'STAR_FETCH_EOF'
[Background]
Color=245,239,229

[BackgroundIntense]
Color=255,250,242

[BackgroundFaint]
Color=236,229,217

[Color0]
Color=61,47,32

[Color0Intense]
Color=119,119,119

[Color0Faint]
Color=48,39,27

[Color1]
Color=122,58,48

[Color1Intense]
Color=160,74,60

[Color1Faint]
Color=96,46,38

[Color2]
Color=58,94,60

[Color2Intense]
Color=77,122,80

[Color2Faint]
Color=46,74,47

[Color3]
Color=166,136,102

[Color3Intense]
Color=194,160,121

[Color3Faint]
Color=135,110,82

[Color4]
Color=48,74,84

[Color4Intense]
Color=65,102,116

[Color4Faint]
Color=38,58,66

[Color5]
Color=162,77,74

[Color5Intense]
Color=192,99,96

[Color5Faint]
Color=128,61,58

[Color6]
Color=106,122,137

[Color6Intense]
Color=138,154,169

[Color6Faint]
Color=84,97,109

[Color7]
Color=245,239,229

[Color7Intense]
Color=255,250,242

[Color7Faint]
Color=216,208,195

[Foreground]
Color=61,47,32

[ForegroundIntense]
Bold=true
Color=61,47,32

[ForegroundFaint]
Color=119,119,119

[General]
Anchor=0.5,0.5
Blur=false
ColorRandomization=false
Description=Blonde
FillStyle=Tile
Opacity=1
Wallpaper=
STAR_FETCH_EOF

cat > "$KONSOLE_DIR/StarFetchBlue.colorscheme" <<'STAR_FETCH_EOF'
[Background]
Color=9,9,27

[BackgroundFaint]
Color=10,11,31

[BackgroundIntense]
Color=10,11,31

[Color0]
Color=3,5,10

[Color0Faint]
Color=3,5,10

[Color0Intense]
Color=49,51,85

[Color1]
Color=198,90,110

[Color1Faint]
Color=140,70,84

[Color1Intense]
Color=212,131,146

[Color2]
Color=127,169,124

[Color2Faint]
Color=94,124,92

[Color2Intense]
Color=159,190,157

[Color3]
Color=216,177,108

[Color3Faint]
Color=158,131,86

[Color3Intense]
Color=226,196,145

[Color4]
Color=80,81,118

[Color4Faint]
Color=60,61,90

[Color4Intense]
Color=132,133,159

[Color5]
Color=154,111,174

[Color5Faint]
Color=112,84,124

[Color5Intense]
Color=179,147,194

[Color6]
Color=111,166,176

[Color6Faint]
Color=82,122,130

[Color6Intense]
Color=147,188,196

[Color7]
Color=196,198,230

[Color7Faint]
Color=140,142,164

[Color7Intense]
Color=205,207,234

[Foreground]
Color=196,198,230

[ForegroundFaint]
Color=140,142,164

[ForegroundIntense]
Color=205,207,234

[General]
Anchor=0.5,0.5
Blur=true
ColorRandomization=false
Description=star_fetch blue
FillStyle=Tile
Opacity=1
Wallpaper=
WallpaperFlipType=NoFlip
WallpaperOpacity=1
STAR_FETCH_EOF

# ---------------------------------------------------------------- KWin rule
# The profile titles the widget "star_fetch — Konsole"; the rule matches that
# substring and forces: no border, keep below, all desktops, skip taskbar and
# pager, no focus, and a fixed position and size.
kw() { kwriteconfig6 --file kwinrulesrc --group "$RULE_ID" "$@"; }
delete_rule_group
kw --key Description   "star_fetch"
kw --key title         "star_fetch — Konsole"
kw --key titlematch    2
kw --key acceptfocusrule 2
kw --key below         true
kw --key belowrule     2
kw --key desktops      '\0'
kw --key desktopsrule  2
kw --key noborder      true
kw --key noborderrule  2
kw --key position      "$POSITION"
kw --key positionrule  2
kw --key size          "$SIZE"
kw --key sizerule      2
kw --key skippager     true
kw --key skippagerrule 2
kw --key skipswitcherrule 2
kw --key skiptaskbar   true
kw --key skiptaskbarrule 2

rules=$(kreadconfig6 --file kwinrulesrc --group General --key rules)
if ! echo "$rules" | tr ',' '\n' | grep -qx "$RULE_ID"; then
    rules="${rules:+$rules,}$RULE_ID"
    kwriteconfig6 --file kwinrulesrc --group General --key rules "$rules"
fi
kwriteconfig6 --file kwinrulesrc --group General --key count \
    "$(echo "$rules" | tr ',' '\n' | grep -c . || true)"
reconfigure_kwin

# ---------------------------------------------------------------- autostart
if [ "$AUTOSTART" = 1 ]; then
    mkdir -p "$(dirname "$AUTOSTART_FILE")"
    cat > "$AUTOSTART_FILE" <<STAR_FETCH_EOF
[Desktop Entry]
Type=Application
Name=star_fetch
Comment=Konsole desktop stats widget
Exec=$BIN_DIR/star_fetch
X-KDE-autostart-phase=2
NoDisplay=true
STAR_FETCH_EOF
    echo "Autostart enabled: $AUTOSTART_FILE"
fi

# ---------------------------------------------------------------- finish
echo ""
echo "Done. star_fetch is installed."
echo "  data:     $DATA_DIR"
echo "  command:  $BIN_DIR/star_fetch"
echo "  position: $POSITION   size: $SIZE"
echo ""
echo "Start the widget:  star_fetch"
echo "Stop the widget:   star_fetch end"
echo "Colors:            star_fetch blue / star_fetch blonde"

if [ "$START" = 1 ] && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
    # Restart so a running widget picks up the new files.
    stop_running_widget
    "$BIN_DIR/star_fetch" >/dev/null && echo "" && echo "star_fetch started."
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo ""
        echo "Note: $BIN_DIR isn't on PATH in this shell yet."
        echo "Open a new terminal before running 'star_fetch'."
        ;;
esac
