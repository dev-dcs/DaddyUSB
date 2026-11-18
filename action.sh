#!/system/bin/sh
# Action button: reopens the chooser if a computer is waiting on an answer,
# otherwise opens the settings panel. Prints the current state either way.
MODDIR=${0%/*}
# shellcheck source=common.sh
. "$MODDIR/common.sh"

conf_load
usb_dump
adb_get

echo "USB Manager $(mod_version)"
if daemon_pid; then
  echo "- daemon running (pid $DPID)"
else
  echo "- daemon NOT running, starting it"
  setsid sh "$MODDIR/bin/usbmgrd" </dev/null >/dev/null 2>&1 &
fi
echo "- connected to a computer: $D_CONNECTED"
echo "- USB mode: ${D_FUNCS:-charging}"
_a=off
[ "$ADB_NOW" = 1 ] && _a=on
echo "- ADB: $_a"
_b=off
_h=
[ -r "$BLOCKF" ] && read -r _b _h <"$BLOCKF"
echo "- USB data block: ${_b:-off}${_h:+ ($_h)}"
echo "- kernel switches: deny_usb_gadget=$(kgate_state "$KGATE_GADGET") deny_new_usb=$(kgate_state "$KGATE_HOST")"
if [ -r "$GUARDF" ]; then
  echo "- USB guard: ARMED"
elif [ "$cfg_guard" = 1 ]; then
  echo "- USB guard: on (${cfg_guard_timeout}s, $cfg_guard_action)"
else
  echo "- USB guard: off"
fi
if [ "$cfg_idle_reboot" = 1 ]; then
  echo "- auto restart: after $cfg_idle_minutes min without unlock (clean cache: $cfg_clean_cache)"
else
  echo "- auto restart: off"
fi
echo " "

if [ -r "$SESSION" ]; then
  wake_daemon prompt
  echo "- Reopening the chooser..."
  exit 0
fi

if launch_ui; then
  echo "- Opened in ${UI_HOST%%/*}"
else
  echo "! No WebUI app found."
  echo "! Install WebUI X Portable or KsuWebUIStandalone,"
  echo "! or edit $CONF by hand."
fi
