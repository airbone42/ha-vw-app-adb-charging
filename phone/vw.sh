#!/system/bin/sh
# vw.sh - remote-control the Volkswagen app on an Android phone via ADB (start/stop charging, read state,
# set charge target and AC current). Meant to be called from Home Assistant through the
# "Android Debug Bridge" integration (androidtv.adb_command), but works from any `adb shell`.
#
# Install:   adb push vw.sh /data/local/tmp/vw.sh
# Call:      adb shell sh /data/local/tmp/vw.sh <command>
#
# Commands:
#   status                     open the app, read the charging view, report state
#   start | stop               press "start charging" / "stop charging" and verify the result
#   current_max                switch "reduced AC charging current" off (and save)
#   current_reduced            switch "reduced AC charging current" on (and save)
#   target <50..100>           move the charge target slider to <n> % (and save)
#   target_trip                target $TRIP_TARGET (default 100)
#   target_normal              target 80
#   texts [bytes]              dump all texts on screen with their bounds (for calibration)
#   home                       bring the Home Assistant app back to the front
#   bg <command> [args]        run <command> detached, write the output to $WORKDIR/vw.out
#                              (androidtv.adb_command only waits ~10 s for an answer)
#
# Shared UI lock: if $WORKDIR/ui_lock.sh exists, every command that drives the app (status, start, stop,
# current_*, target*) first takes the lock "vw-<command>" and waits up to 120 s for it, so that other scripts
# driving the same phone do not tap into the VW app (and vice versa). If the phone stays busy, the result is
# STATUS=error MESSAGE=phone busy (<who>). texts and home do not take it.
#
# Output: the LAST line is always
#   STATUS=<charging|plugged|unplugged|unknown|error> MESSAGE=<text>[ soc NN][ power N.N][ lock locked|unlocked|unknown][ sync MIN]
#   lock/sync come from the header of the start page ("Fahrzeug ist verriegelt. Synchronisiert vor 7 Minuten",
#   sync = age of the car's data in minutes) and are only present if the start page was seen during the run.
#   charging   the app shows the "stop charging" button
#   plugged    cable connected, not charging ("start charging" button visible)
#   unplugged  no cable
#   unknown    app open, but no known state recognised (logged out? app updated?)
#   error      a step failed, MESSAGE says which
#
# How it works: wake the screen, force-stop the Home Assistant app (its picture-in-picture window
# swallows taps), launch the VW app, read the view with `uiautomator dump`, find buttons by their
# text / content-desc and tap the centre of their bounds with `input tap`, then relaunch the HA app.
#
# Everything app-specific (package names, screen texts, coordinates) is in the CONFIG block below.
# Values in $WORKDIR/vw.conf (plain `NAME='value'` lines) override it, so you can recalibrate after an
# app update without replacing this script. Use `vw.sh texts` and ui.sh to find the texts.
#
# The defaults were calibrated on a German-language UI (VW app "Volkswagen", com.volkswagen.weconnect,
# ID-family car, phone with a 1080 px wide screen). Other languages, app versions and screen sizes need
# their own values.

# ============================== CONFIG ==============================
WORKDIR=/data/local/tmp

# Apps
PKG=com.volkswagen.weconnect                 # VW app
HA_PKG=io.homeassistant.companion.android    # app to return to afterwards (empty = none)

# Screen texts (extended regular expressions, matched case-insensitively against text and content-desc)
M_START='Laden starten'                      # button "start charging" (visible = plugged, not charging)
M_STOP='Laden stoppen'                       # button "stop charging"  (visible = charging)
M_CHARGING='Lädt gerade|Prozent\. Aktiviert' # tile text while charging (fallback if no button is found)
M_UNPLUGGED='nicht angeschlossen|nicht eingesteckt|nicht verbunden|Ladekabel einstecken|Stecker'
M_NO_CABLE='Ladekabel verbinden'             # charging view without cable (start button may still be visible!)
M_CHARGE_TILE='Übersicht Reichweite'         # tile on the start page that opens the charging view
M_DISMISS='Alles klar'                       # "OK" of info dialogs (e.g. after stop, after raising the target)

# Values read from the charging view (the number is taken from the first match)
RE_SOC='Batterieladung: [0-9]{1,3} Prozent'                 # battery level in %
RE_POWER='Ladeleistung: [0-9]+([,.][0-9]+)? Kilowatt'       # charging power in kW

# Header of the start page (content-desc), e.g. "Ihr Fahrzeug: ID.4 Pro Performance. Fahrzeug ist verriegelt.
# Synchronisiert vor 7 Minuten". Gives lock state and age of the data, e.g. to read more often while driving.
RE_HEADER='content-desc="Ihr Fahrzeug:[^"]*"'
M_UNLOCKED='nicht verriegelt|entriegelt'     # checked first
M_LOCKED='verriegelt'
RE_SYNC='Synchroni[^."]*'                    # "Synchronisiert vor 7 Minuten" (parsed in read_header)

# Settings page (charge target slider, reduced AC current switch, save)
SWIPE_TO_SETTINGS='540 1800 540 700'         # swipe up on the start page until the settings entry is visible
M_SETTINGS='Einstellungen\. Details'         # entry that opens the charging settings
M_TARGET_ROW='Laden bis'                     # row "charge until (50-100 %)"
M_REDUCED='Reduzierter AC-Ladestrom'         # row "reduced AC charging current"
M_SAVE='Speichern'                           # "save" (top right)
RE_TARGET_VALUE='text="[0-9]{2,3}%"'         # the slider itself is not in the dump, only its value "NN%"

# Slider geometry in screen pixels (the slider is invisible to uiautomator, so we swipe blind)
SL_Y=942          # y of the slider track
SL_X0=106         # x of 50 %
SL_X100=830       # x of 100 %
SL_GRAB_X=300     # x where the swipe starts (anywhere on the track)
SW_MIN_X=800      # the reduced-current switch is the checkable element right of this x in its row
SW_TAP_X=970      # x to tap the switch

# Charge target used by "target_trip"
TRIP_TARGET=100
# ============================ END CONFIG ============================

[ -f "$WORKDIR/vw.conf" ] && . "$WORKDIR/vw.conf"
F=$WORKDIR/vw_ui.xml
N=$WORKDIR/vw_nodes.txt
SOC=''
POWER=''
LOCK=''
SYNC=''

# `uiautomator dump` sets accessibility_enabled to 0, which silently disables every accessibility service
# (e.g. an automation app that confirms the "allow wireless debugging" popup after a reboot).
# Switch it back on if any service is configured.
a11y() { [ -n "$(settings get secure enabled_accessibility_services 2>/dev/null | grep -v null)" ] && settings put secure accessibility_enabled 1; }

# Read the current view into $N, one <node ...> per line.
dump() {
  rm -f "$F"
  uiautomator dump "$F" >/dev/null 2>&1
  a11y
  [ -s "$F" ] || return 1
  grep -o '<node [^>]*>' "$F" > "$N"
  read_header
}
# Lock state and data age from the start page header, if it is on screen (sets LOCK, SYNC in minutes).
# Uses its own variable names: dump is called inside loops that use k, s, b.
read_header() {
  _hd=$(grep -o -E "$RE_HEADER" "$N" | head -1)
  [ -z "$_hd" ] && return 0
  if echo "$_hd" | grep -q -E "$M_UNLOCKED"; then LOCK=unlocked
  elif echo "$_hd" | grep -q -E "$M_LOCKED"; then LOCK=locked
  else LOCK=unknown; fi
  # "vor 7 Minuten", "vor 1 Minute", "vor 2 Stunden", "vor 16 h", "vor weniger als einer Minute", "gerade eben"
  _hs=$(echo "$_hd" | grep -o -E "$RE_SYNC" | head -1)
  [ -z "$_hs" ] && return 0
  _hn=$(echo "$_hs" | grep -o -E '[0-9]+' | head -1)
  [ -z "$_hn" ] && echo "$_hs" | grep -q -E ' (einer|einem|eine) ' && _hn=1
  case "$_hs" in
    *weniger*|*gerade*|*jetzt*|*Sekunde*) SYNC=0 ;;
    *Min*|*' min') [ -n "$_hn" ] && SYNC=$_hn ;;
    *Stund*|*Std*|*' h') [ -n "$_hn" ] && SYNC=$(( _hn * 60 )) ;;
    *Tag*|*' d') [ -n "$_hn" ] && SYNC=$(( _hn * 1440 )) ;;
  esac
  return 0
}
nodes() { grep -i -E "(text|content-desc)=\"[^\"]*($1)[^\"]*\"" "$N"; }
has() { [ -n "$1" ] && nodes "$1" | grep -q .; }
# Tap the centre of the first node matching $1.
tap() {
  b=$(nodes "$1" | head -1 | grep -o 'bounds="[^"]*"' | sed 's/[^0-9]/ /g')
  [ -z "$b" ] && return 1
  set -- $b
  input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}
read_values() {
  a=$(grep -o -E "$RE_SOC" "$N" | head -1 | grep -o -E '[0-9]+' | head -1)
  [ -n "$a" ] && SOC=$a
  l=$(grep -o -E "$RE_POWER" "$N" | head -1 | grep -o -E '[0-9]+([,.][0-9]+)?' | head -1 | tr ',' '.')
  [ -n "$l" ] && POWER=$l
}
open_app() {
  input keyevent KEYCODE_WAKEUP
  # The VW app ignores touches while the HA app's picture-in-picture window is on top.
  [ -n "$HA_PKG" ] && am force-stop "$HA_PKG"
  am force-stop "$PKG"
  monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
}
go_home() { [ -n "$HA_PKG" ] && monkey -p "$HA_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; }

# Wait for a known state (up to $1 rounds of 2 s). Sets Z, returns 1 if nothing was recognised.
read_state() {
  Z=unknown
  i=0
  while [ $i -lt ${1:-15} ]; do
    i=$((i + 1))
    echo "wait $i"
    sleep 2
    dump || continue
    read_values
    if [ -n "$M_DISMISS" ] && has "$M_DISMISS"; then tap "$M_DISMISS"; continue; fi
    if has "$M_STOP"; then Z=charging; return 0; fi
    if [ -n "$M_NO_CABLE" ] && has "$M_NO_CABLE"; then Z=unplugged; return 0; fi
    if has "$M_START"; then Z=plugged; return 0; fi
    if has "$M_UNPLUGGED"; then Z=unplugged; return 0; fi
    # Start page: open the charging view (the buttons only exist there)
    if [ -n "$M_CHARGE_TILE" ] && has "$M_CHARGE_TILE"; then tap "$M_CHARGE_TILE"; sleep 2; continue; fi
  done
  # No button found: fall back to the tile text
  has "$M_CHARGING" && { Z=charging; return 0; }
  return 1
}

# Generic step sequence for your own additions (not used by the built-in commands):
# steps separated by ";". A step is a text pattern (wait for it, then tap it), "?pattern" (tap if present)
# or "!shell command" (e.g. "!input swipe 100 900 900 900 400").
steps() {
  [ -z "$1" ] && return 2
  echo "$1" | tr ';' '\n' | while read -r s; do
    [ -z "$s" ] && continue
    case "$s" in
      !*) sh -c "${s#!}"; sleep 2 ;;
      \?*) dump && tap "${s#\?}"; sleep 2 ;;
      *) k=0; ok=1
         while [ $k -lt 8 ]; do k=$((k + 1)); sleep 2; dump || continue
           if tap "$s"; then ok=0; break; fi
         done
         [ $ok -eq 0 ] || { echo "STEP_MISSING $s"; exit 1; } ;;
    esac
  done
}

wait_for() {  # $1 pattern, $2 rounds of 2 s
  k=0
  while [ $k -lt ${2:-8} ]; do k=$((k + 1)); sleep 2; dump || continue
    [ -n "$M_DISMISS" ] && has "$M_DISMISS" && { tap "$M_DISMISS"; continue; }
    has "$1" && return 0
  done
  return 1
}
open_settings() {
  open_app
  wait_for "$M_CHARGE_TILE" 10 || finish error "start page of the app not recognised"
  input swipe $SWIPE_TO_SETTINGS 500
  wait_for "$M_SETTINGS" 5 || finish error "settings entry not found"
  tap "$M_SETTINGS"
  wait_for "$M_TARGET_ROW" 8 || finish error "settings did not open"
}
target_value() { grep -o -E "$RE_TARGET_VALUE" "$N" | head -1 | grep -o -E '[0-9]+'; }
save() {
  dump; has "$M_SAVE" || return 1
  tap "$M_SAVE"; sleep 3
  wait_for "$M_TARGET_ROW|$M_CHARGE_TILE" 5
  return 0
}

# Charge target. With "battery care" enabled the app applies a target above 80 % only to the next
# charging session and resets it to 80 % after every stop, so set it again before every start.
set_target() {  # $1 percent (50..100)
  p=$1
  case "$p" in ''|*[!0-9]*) finish error "target needs a number" ;; esac
  [ "$p" -lt 50 ] || [ "$p" -gt 100 ] && finish error "target must be 50..100"
  open_settings
  old=$(target_value)
  [ "$old" = "$p" ] && { SOC=''; go_home; echo "STATUS=unknown MESSAGE=target $p was already set"; exit 0; }
  x=$(( SL_X0 + (p - 50) * (SL_X100 - SL_X0) / 50 ))
  [ $x -gt $SL_X100 ] && x=$SL_X100
  input swipe $SL_GRAB_X $SL_Y $x $SL_Y 700
  sleep 2; dump; has "$M_DISMISS" && { tap "$M_DISMISS"; sleep 2; dump; }
  new=$(target_value)
  [ "$new" = "$p" ] || finish error "slider is at ${new:-?} instead of $p (check SL_* in the config)"
  save || finish error "save button not found"
  go_home; echo "STATUS=unknown MESSAGE=target $p saved (was $old)"; exit 0
}

set_current() {  # $1 on = reduced, off = maximum
  mode=$1
  open_settings
  # The switch is the checkable element on the right in the row of $M_REDUCED
  b=$(nodes "$M_REDUCED" | head -1 | grep -o 'bounds="[^"]*"' | sed 's/[^0-9]/ /g')
  [ -z "$b" ] && finish error "row '$M_REDUCED' not found"
  set -- $b; y=$(( ($2 + $4) / 2 ))
  st=$(grep 'checkable="true"' "$N" | while read -r l; do
         b=$(echo "$l" | grep -o 'bounds="[^"]*"' | sed 's/[^0-9]/ /g'); set -- $b
         [ $1 -ge $SW_MIN_X ] && [ $2 -le $y ] && [ $4 -ge $y ] && { echo "$l" | grep -o 'checked="[a-z]*"' | cut -d'"' -f2; break; }
       done)
  [ -z "$st" ] && finish error "cannot read the state of the switch"
  want=false; [ "$mode" = on ] && want=true
  if [ "$st" = "$want" ]; then go_home; echo "STATUS=unknown MESSAGE=reduced current $mode was already set"; exit 0; fi
  input tap $SW_TAP_X $y
  sleep 2; dump; has "$M_DISMISS" && tap "$M_DISMISS"
  save
  go_home; echo "STATUS=unknown MESSAGE=reduced current $mode saved"; exit 0
}

finish() { go_home; echo "STATUS=$1 MESSAGE=${2:-ok}${SOC:+ soc $SOC}${POWER:+ power $POWER}${LOCK:+ lock $LOCK}${SYNC:+ sync $SYNC}"; exit 0; }

case "$1" in
  status|start|stop|current_max|current_reduced|target|target_trip|target_normal)
    if [ -f "$WORKDIR/ui_lock.sh" ]; then
      . "$WORKDIR/ui_lock.sh"
      ui_lock "vw-$1" 120 300 || { echo "STATUS=error MESSAGE=phone busy ($UL_WHO)"; exit 0; }
    fi ;;
esac

case "$1" in
  bg)
    # Detach so that Home Assistant can close the ADB connection. A plain `setsid ... &` was killed
    # when HA closed the connection; subshell + nohup + setsid + ignored signals survives.
    shift
    rm -f "$WORKDIR/vw.out"
    ( trap '' HUP TERM INT; nohup setsid sh -c "trap '' HUP TERM INT; exec sh $WORKDIR/vw.sh $*" > "$WORKDIR/vw.out" 2>&1 < /dev/null & )
    sleep 1
    echo "STARTED $*"
    exit 0 ;;
  status)
    open_app; read_state 15 || finish unknown "no known state in the app"
    finish $Z ;;
  start)
    open_app; read_state 15 || finish unknown "no known state in the app"
    case $Z in
      charging) finish charging "was already charging" ;;
      unplugged) finish unplugged ;;
    esac
    tap "$M_START" || finish error "start button not found"
    # After "start" the app shows an intermediate state (~30 s) before "charging"
    sleep 5
    j=0
    while [ $j -lt 6 ]; do
      j=$((j + 1)); read_state 3; [ "$Z" = charging ] && finish charging "started"; sleep 3
    done
    finish error "no charging visible after the tap ($Z)" ;;
  stop)
    open_app; read_state 15 || finish unknown "no known state in the app"
    [ "$Z" = charging ] || finish $Z "was not charging"
    tap "$M_STOP" || finish error "stop button not found"
    sleep 4
    dump && has "$M_DISMISS" && tap "$M_DISMISS"
    sleep 3
    j=0
    while [ $j -lt 6 ]; do
      j=$((j + 1)); read_state 3; [ "$Z" != charging ] && [ "$Z" != unknown ] && finish $Z "stopped"; sleep 5
    done
    finish error "still charging after the tap" ;;
  current_max) set_current off ;;
  current_reduced) set_current on ;;
  target) set_target "$2" ;;
  target_trip) set_target "${TRIP_TARGET:-100}" ;;
  target_normal) set_target 80 ;;
  texts)
    dump || { echo "STATUS=error MESSAGE=uiautomator dump failed"; exit 0; }
    sed -n 's/.*text="\([^"]*\)".*content-desc="\([^"]*\)".*bounds="\([^"]*\)".*/\1|\2|\3/p' "$N" | grep -v '^||' | head -c ${2:-3500}
    echo; echo "STATUS=unknown MESSAGE=texts" ;;
  home) go_home; echo "STATUS=unknown MESSAGE=home" ;;
  *) echo "STATUS=error MESSAGE=unknown command $1" ;;
esac
