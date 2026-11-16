# USB Manager (root edition) installer - @Dev_DcS
# sourced by Magisk / KernelSU / APatch, MODPATH and friends come from them

DATA=/data/adb/usbmanager

ui_print " "
ui_print "  USB Manager - no LSPosed needed"
ui_print "  by @Dev_DcS"
ui_print " "

if [ "$API" -lt 26 ]; then
  abort "! Needs Android 8.0 or newer (you're on API $API)"
fi
[ "$API" -lt 28 ] && ui_print "! Android 8.x: only the old svc usb setFunction path works, expect rough edges"

mkdir -p "$DATA/run"
if [ -f "$DATA/settings.conf" ]; then
  ui_print "- Keeping your existing settings"
else
  cp -f "$MODPATH/defaults.conf" "$DATA/settings.conf"
  ui_print "- Default settings written to $DATA"
fi
touch "$DATA/dnd.list"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$DATA" 0 0 0700 0600

# having both versions active means two prompts per plug-in
if pm path com.tiger.usbmanager >/dev/null 2>&1; then
  ui_print " "
  ui_print "! The LSPosed USBManager app is installed."
  ui_print "! Disable it in LSPosed (or uninstall it), otherwise"
  ui_print "! you'll get two choosers every time."
fi

ui_print " "
if [ "$KSU" = true ] || [ "$APATCH" = true ]; then
  ui_print "- Your root manager has WebUI built in, the chooser opens there"
else
  _found=
  for _p in com.dergoogler.mmrl.wx io.github.a13e300.ksuwebui; do
    [ -d "/data/data/$_p" ] && _found=$_p
  done
  if [ -n "$_found" ]; then
    ui_print "- WebUI host found: $_found"
  else
    ui_print "! Magisk has no WebUI of its own. Install WebUI X Portable"
    ui_print "! or KsuWebUIStandalone to get the chooser. Without one the"
    ui_print "! default config gets applied quietly on every plug-in."
  fi
fi
if [ -e /proc/sys/kernel/deny_usb_gadget ] && [ -e /proc/sys/kernel/deny_new_usb ]; then
  ui_print "- Kernel USB switches found: USB block and guard cut-off run in the kernel"
else
  ui_print "- No kernel USB switches, the block uses the userspace fallback"
fi
ui_print "- Reboot, then plug into a computer"
ui_print " "
