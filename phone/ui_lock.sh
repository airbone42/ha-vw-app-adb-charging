#!/system/bin/sh
# ui_lock.sh - shared lock for everything that drives an app on this phone through its UI via ADB
# (uiautomator dump, input tap/text/swipe, bringing an app to the front). Without it, two scripts that run at
# the same time (e.g. vw.sh and a second automation on the same wall phone) tap into each other's app.
# Rule: whoever drives the UI takes this lock first. A plain `am force-stop` of a background app does not need it.
#
# Install:   adb push ui_lock.sh /data/local/tmp/ui_lock.sh
#
# Inside scripts on the phone (source it):
#   . /data/local/tmp/ui_lock.sh
#   ui_cleanup() { ...; }            # optional, runs on exit before the release (also on error/signal)
#   ui_lock <name> [wait_s=120] [max_s=180] || { echo "busy: $UL_WHO"; exit 0; }
#   ... ui_waiting && { echo "someone is waiting, giving up"; exit 0; }   # optional, for low-priority jobs
#   (the release happens on exit via trap EXIT/HUP/INT/TERM; if the caller sets its own trap afterwards,
#    it has to call ui_unlock in it)
# From outside (adb shell from a PC/server, Home Assistant via androidtv.adb_command):
#   sh ui_lock.sh take <name> [wait_s=120] [max_s=180]  -> exit 0 and "UI_LOCK=<name> ..." or exit 1 and "UI_LOCK_BUSY=..."
#   sh ui_lock.sh release <name>                       -> releases only a lock with that name
#   sh ui_lock.sh who                                  -> "UI_LOCK=free" or "UI_LOCK=<name> since N s (pid P, max M s)"
#   sh ui_lock.sh bg <name> <wait_s> '<commands>'      -> detached: take the lock, run the commands, release
#                                                         (for HA, androidtv.adb_command only waits ~10 s);
#                                                         output in $UL_D/ui_lock_<name>.out
# A lock is stale when the process holding it has exited, or when it is older than its max_s (default 180 s).
# Locks taken from outside have no process on the phone and only expire through max_s.
# Content of $UL/who: "<name> <epoch> <pid|-> <max_s>". Waiters write "<name> <epoch>" to $UL_W, so that
# low-priority jobs can check ui_waiting and step aside.
UL_D=${UL_D:-/data/local/tmp}
UL=$UL_D/ui.lock
UL_W=$UL_D/ui.lock.waiting
UL_WHO=''
UL_MINE=''

_ul_now() { date +%s; }
# sets UL_WHO (readable) and returns 0 if the lock is validly held
_ul_valid() {
  _ul_c=$(cat $UL/who 2>/dev/null)
  [ -d $UL ] || { UL_WHO=''; return 1; }
  set -- $_ul_c
  _ul_n=${1:-?}; _ul_t=${2:-0}; _ul_p=${3:--}; _ul_m=${4:-180}
  case "$_ul_t" in ''|*[!0-9]*) _ul_t=0 ;; esac
  case "$_ul_m" in ''|*[!0-9]*) _ul_m=180 ;; esac
  _ul_age=$(( $(_ul_now) - _ul_t ))
  UL_WHO="$_ul_n since $_ul_age s (pid $_ul_p, max $_ul_m s)"
  # just created, owner not written yet: valid
  [ -z "$_ul_c" ] && { _ul_age=$(( $(_ul_now) - $(stat -c %Y $UL 2>/dev/null || echo 0) )); [ $_ul_age -lt 5 ] && return 0; }
  [ $_ul_age -gt $_ul_m ] && return 1
  case "$_ul_p" in -|'') return 0 ;; esac
  kill -0 "$_ul_p" 2>/dev/null
}
# remove a stale lock, but only if it has not changed since it was checked
_ul_break() {
  [ "$(cat $UL/who 2>/dev/null)" = "$_ul_c" ] || return 0
  echo "UI_LOCK stale, removed: $UL_WHO" >&2
  rm -rf $UL
}
ui_lock() {
  _ul_name=${1:?name}; _ul_wait=${2:-120}; _ul_max=${3:-180}; _ul_pid=${UL_PID:-$$}
  _ul_start=$(_ul_now)
  # already ours (nested, e.g. a job holds it and calls vw.sh with UI_LOCK_TOKEN=<content of who>): nothing to do
  if [ -n "$UI_LOCK_TOKEN" ] && [ "$(cat $UL/who 2>/dev/null)" = "$UI_LOCK_TOKEN" ]; then UL_WHO="$UI_LOCK_TOKEN"; return 0; fi
  _ul_told=''
  while :; do
    if mkdir $UL 2>/dev/null; then
      UL_MINE="$_ul_name $(_ul_now) $_ul_pid $_ul_max"
      echo "$UL_MINE" > $UL/who
      [ "$(cut -d' ' -f1 $UL_W 2>/dev/null)" = "$_ul_name" ] && rm -f $UL_W
      [ "$_ul_pid" = - ] || trap '_ul_exit' EXIT
      [ "$_ul_pid" = - ] || trap '_ul_exit; exit 1' HUP INT TERM
      return 0
    fi
    _ul_valid || { _ul_break; continue; }
    [ $(( $(_ul_now) - _ul_start )) -ge $_ul_wait ] && return 1
    [ -z "$_ul_told" ] && { echo "WAITING for ui.lock: $UL_WHO"; _ul_told=1; }
    echo "$_ul_name $(_ul_now)" > $UL_W
    sleep 2
  done
}
ui_unlock() {
  [ -n "$UL_MINE" ] || return 0
  [ "$(cat $UL/who 2>/dev/null)" = "$UL_MINE" ] && rm -rf $UL
  UL_MINE=''
}
_ul_exit() {
  trap - EXIT HUP INT TERM
  type ui_cleanup >/dev/null 2>&1 && ui_cleanup
  ui_unlock
}
# 0 if someone else has waited for the lock within the last 10 s
ui_waiting() {
  set -- $(cat $UL_W 2>/dev/null)
  [ -n "$1" ] && [ "$1" != "$_ul_name" ] || return 1
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(_ul_now) - $2 )) -le 10 ]
}

# called as a program (not when sourced with ".")
case "$0" in
  *ui_lock.sh)
    case "$1" in
      take)
        UL_PID=-; ui_lock "${2:?name}" "${3:-120}" "${4:-180}" && { echo "UI_LOCK=$UL_MINE"; exit 0; }
        echo "UI_LOCK_BUSY=$UL_WHO"; exit 1 ;;
      release)
        own=$(cut -d' ' -f1 $UL/who 2>/dev/null)
        if [ -n "$2" ] && [ "$own" = "$2" ]; then rm -rf $UL; echo "UI_LOCK=free"; else echo "UI_LOCK not ours (${own:-none})"; fi
        exit 0 ;;
      who)
        if [ -d $UL ] && _ul_valid; then echo "UI_LOCK=$UL_WHO"; elif [ -d $UL ]; then echo "UI_LOCK=stale ($UL_WHO)"; else echo "UI_LOCK=free"; fi
        exit 0 ;;
      bg)
        n=${2:?name}; w=${3:-120}; shift 3
        o=$UL_D/ui_lock_$n.out
        ( trap '' HUP; nohup setsid sh -c ". $UL_D/ui_lock.sh; ui_lock '$n' '$w' || { echo \"UI_LOCK_BUSY=\$UL_WHO\"; exit 1; }; $*; echo UI_LOCK_DONE" > $o 2>&1 < /dev/null & )
        echo "STARTED $n"; exit 0 ;;
      *) echo "usage: ui_lock.sh take|release|who|bg ..."; exit 2 ;;
    esac ;;
esac
