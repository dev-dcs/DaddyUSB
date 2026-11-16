#!/system/bin/sh
# start usbmgrd once Android is fully up
MODDIR=${0%/*}
# shellcheck source=common.sh
. "$MODDIR/common.sh"

run_fresh
conf_load

if [ "$cfg_block" = 1 ]; then
  # USB block survives reboots: keep the phone off the bus during boot,
  # the daemon takes over once it's running
  kgate_init
  kgate_set 1
  udc_list
  host_param_cut
  if [ -f "$RUN/kgadget.set" ]; then
    # kernel holds the pullup down, nothing to babysit
    until [ "$(getprop sys.boot_completed)" = 1 ]; do
      sleep 2
    done
  else
    until [ "$(getprop sys.boot_completed)" = 1 ]; do
      # init creates the gadget somewhere during boot, look again until it's there
      [ -n "$UDC_LIST" ] || udc_list
      gadget_cut
      sleep 1
    done
    gadget_cut
  fi
else
  until [ "$(getprop sys.boot_completed)" = 1 ]; do
    sleep 2
  done
  # give UsbDeviceManager a moment to settle its first config
  sleep 5
fi

if command -v setsid >/dev/null 2>&1; then
  setsid sh "$MODDIR/bin/usbmgrd" </dev/null >/dev/null 2>&1 &
else
  nohup sh "$MODDIR/bin/usbmgrd" </dev/null >/dev/null 2>&1 &
fi
