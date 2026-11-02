#!/system/bin/sh
# ui.sh - calibration helper: look at the current screen and click through an app via ADB.
# Every command prints the visible elements afterwards:  text|content-desc|class|ch=checked|cl=clickable|[x1,y1][x2,y2]
#
#   adb shell sh /data/local/tmp/ui.sh show                 what is on screen right now
#   adb shell sh /data/local/tmp/ui.sh tap "Laden starten"  tap the first element whose text/description matches (regex)
#   adb shell sh /data/local/tmp/ui.sh xy 540 942           tap a coordinate
#   adb shell sh /data/local/tmp/ui.sh swipe 540 1800 540 700
#   adb shell sh /data/local/tmp/ui.sh key KEYCODE_BACK
#   adb shell sh /data/local/tmp/ui.sh text "hello"         type text into the focused field
#
# Note: `uiautomator dump` sets accessibility_enabled to 0, which disables accessibility services;
# this script switches it back on after every dump.

WORKDIR=/data/local/tmp
F=$WORKDIR/ui.xml; N=$WORKDIR/ui_nodes.txt
dump() { rm -f "$F"; uiautomator dump "$F" >/dev/null 2>&1; settings put secure accessibility_enabled 1; grep -o '<node [^>]*>' "$F" > "$N"; }
show() { sed -n 's/.*text="\([^"]*\)".*class="\([^"]*\)".*content-desc="\([^"]*\)".*checked="\([^"]*\)".*clickable="\([^"]*\)".*bounds="\([^"]*\)".*/\1|\3|\2|ch=\4|cl=\5|\6/p' "$N" | grep -v -E '^\|\|' | sed 's/android.widget.//; s/android.view.//' | head -c 5000; }
case "$1" in
  tap) w=${3:-2}; dump; b=$(grep -i -E "(text|content-desc)=\"[^\"]*($2)[^\"]*\"" "$N" | head -1 | grep -o 'bounds="[^"]*"' | sed 's/[^0-9]/ /g')
       [ -z "$b" ] && { echo "NOT FOUND: $2"; show; exit 0; }
       set -- $b; input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 )); sleep $w; dump; show ;;
  xy) input tap $2 $3; sleep 2; dump; show ;;
  text) input text "$2"; sleep 1; dump; show ;;
  key) input keyevent $2; sleep 2; dump; show ;;
  swipe) input swipe $2 $3 $4 $5 400; sleep 2; dump; show ;;
  show) dump; show ;;
  *) echo "usage: ui.sh show | tap <regex> [wait] | xy X Y | swipe X1 Y1 X2 Y2 | key KEYCODE | text <text>" ;;
esac
