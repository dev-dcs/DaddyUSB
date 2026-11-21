# common.sh - shared helpers for usbmgrd, usbctl and action.sh
# USB Manager (root edition) - @Dev_DcS
#
# Sourced, never run directly. Expects MODDIR to be set by the caller.

MODID=usbmanager_dcs
MODNAME="USB Manager"
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/$MODID

# USBMGR_DATA / USBMGR_SYSFS only exist so I can run this on a desktop
# against a fake /sys. Leave them alone on a phone.
DATA=${USBMGR_DATA:-/data/adb/usbmanager}
SYSFS=${USBMGR_SYSFS:-/sys}
RUN=$DATA/run
CONF=$DATA/settings.conf
DND_LIST=$DATA/dnd.list
LOGF=$DATA/usbmgr.log
PIDF=$RUN/usbmgrd.pid
FIFO=$RUN/wake
SESSION=$RUN/session
SUPPRESS=$RUN/suppress
TRUST_LIST=$DATA/trusted.list
HISTORY=$DATA/history.log
PEERF=$RUN/peer
GUARDF=$RUN/guard
BLOCKF=$RUN/block
IDLEF=$RUN/idle_last
MEMF=$DATA/remembered.list
# seconds per "minute" of idle_minutes. Only the desktop test rig changes it.
IDLE_UNIT=${USBMGR_IDLE_UNIT:-60}
# configfs lives at /config on most phones, some vendors only have the sysfs one
CFGFS_ROOTS=${USBMGR_CONFIGFS:-/config /sys/kernel/config}
CR=$(printf '\r')

export PATH="/system/bin:/system/xbin:/vendor/bin:$PATH"

SDK=$(getprop ro.build.version.sdk 2>/dev/null)
case $SDK in ''|*[!0-9]*) SDK=0 ;; esac

# ---------------------------------------------------------------- logging

log_msg() {
  _lvl=$1; shift
  printf '%s %s %s\n' "$(date '+%m-%d %H:%M:%S')" "$_lvl" "$*" >>"$LOGF" 2>/dev/null
  case $_lvl in E) _p=e ;; W) _p=w ;; *) _p=i ;; esac
  log -p "$_p" -t USBManager "$*" 2>/dev/null
}

log_rotate() {
  [ -f "$LOGF" ] || return 0
  _sz=$(wc -c <"$LOGF" 2>/dev/null)
  [ "${_sz:-0}" -gt 262144 ] && mv -f "$LOGF" "$LOGF.1"
  return 0
}

# seconds since boot, in $NOW. read is a builtin so this never forks
uptime_now() {
  read -r NOW _ </proc/uptime
  NOW=${NOW%%.*}
}

# ---------------------------------------------------------------- settings

# keep = leave the USB functions to Android (cars/docks that switch the phone
# into accessory mode themselves, Android Auto) and only set ADB
is_mode() {
  case $1 in charging | mtp | ptp | rndis | midi | keep) return 0 ;; esac
  return 1
}

is_pkg() {
  case $1 in '' | .* | *[!A-Za-z0-9_.]*) return 1 ;; esac
  return 0
}

# pkg/.Activity or pkg/full.class.Name
is_component() {
  case $1 in '' | *[!A-Za-z0-9_./]* | /* | */) return 1 ;; */*) return 0 ;; esac
  return 1
}

conf_defaults() {
  cfg_enabled=1
  cfg_prompt=1
  cfg_default_mode=charging
  cfg_default_adb=0
  cfg_adb_off_unplug=1
  cfg_defer_locked=1
  cfg_dnd=0
  cfg_dnd_action=charging
  cfg_notify=1
  cfg_ui_host=auto
  cfg_block=0
  cfg_guard=0
  cfg_guard_timeout=60
  cfg_guard_sticky=1
  cfg_guard_cutoff=1
  cfg_guard_warn=1
  cfg_guard_action=reboot
  cfg_idle_reboot=0
  cfg_idle_minutes=1080
  cfg_clean_cache=0
  cfg_remember_hours=12
}

conf_valid() {
  case $1 in
    enabled | prompt | default_adb | adb_off_unplug | defer_locked | dnd | notify | \
      block | guard | guard_sticky | guard_cutoff | guard_warn | idle_reboot | clean_cache)
      [ "$2" = 0 ] || [ "$2" = 1 ] ;;
    default_mode) is_mode "$2" ;;
    dnd_action) [ "$2" = charging ] || [ "$2" = default ] ;;
    ui_host) [ "$2" = auto ] || is_component "$2" ;;
    guard_timeout)
      case $2 in '' | *[!0-9]*) return 1 ;; esac
      [ "$2" -ge 10 ] && [ "$2" -le 600 ] ;;
    guard_action) [ "$2" = reboot ] || [ "$2" = test ] ;;
    idle_minutes)
      case $2 in '' | *[!0-9]*) return 1 ;; esac
      [ "$2" -ge 10 ] && [ "$2" -le 4320 ] ;;
    remember_hours)
      case $2 in '' | *[!0-9]*) return 1 ;; esac
      [ "$2" -le 168 ] ;;
    *) return 1 ;;
  esac
}

conf_assign() {
  case $1 in
    enabled) cfg_enabled=$2 ;;
    prompt) cfg_prompt=$2 ;;
    default_mode) cfg_default_mode=$2 ;;
    default_adb) cfg_default_adb=$2 ;;
    adb_off_unplug) cfg_adb_off_unplug=$2 ;;
    defer_locked) cfg_defer_locked=$2 ;;
    dnd) cfg_dnd=$2 ;;
    dnd_action) cfg_dnd_action=$2 ;;
    notify) cfg_notify=$2 ;;
    ui_host) cfg_ui_host=$2 ;;
    block) cfg_block=$2 ;;
    guard) cfg_guard=$2 ;;
    guard_timeout) cfg_guard_timeout=$2 ;;
    guard_sticky) cfg_guard_sticky=$2 ;;
    guard_cutoff) cfg_guard_cutoff=$2 ;;
    guard_warn) cfg_guard_warn=$2 ;;
    guard_action) cfg_guard_action=$2 ;;
    idle_reboot) cfg_idle_reboot=$2 ;;
    idle_minutes) cfg_idle_minutes=$2 ;;
    clean_cache) cfg_clean_cache=$2 ;;
    remember_hours) cfg_remember_hours=$2 ;;
  esac
}

conf_load() {
  conf_defaults
  [ -r "$CONF" ] || return 0
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    _v=${_v%"$CR"}
    conf_valid "$_k" "$_v" && conf_assign "$_k" "$_v"
  done <"$CONF"
  return 0
}

conf_save() {
  {
    echo "# USB Manager settings. The WebUI writes this file, hand edits are fine too."
    echo "enabled=$cfg_enabled"
    echo "prompt=$cfg_prompt"
    echo "default_mode=$cfg_default_mode"
    echo "default_adb=$cfg_default_adb"
    echo "adb_off_unplug=$cfg_adb_off_unplug"
    echo "defer_locked=$cfg_defer_locked"
    echo "dnd=$cfg_dnd"
    echo "dnd_action=$cfg_dnd_action"
    echo "notify=$cfg_notify"
    echo "ui_host=$cfg_ui_host"
    echo "block=$cfg_block"
    echo "guard=$cfg_guard"
    echo "guard_timeout=$cfg_guard_timeout"
    echo "guard_sticky=$cfg_guard_sticky"
    echo "guard_cutoff=$cfg_guard_cutoff"
    echo "guard_warn=$cfg_guard_warn"
    echo "guard_action=$cfg_guard_action"
    echo "idle_reboot=$cfg_idle_reboot"
    echo "idle_minutes=$cfg_idle_minutes"
    echo "clean_cache=$cfg_clean_cache"
    echo "remember_hours=$cfg_remember_hours"
  } >"$CONF.tmp" && mv -f "$CONF.tmp" "$CONF"
}

# ---------------------------------------------------------------- usb state

# Which file tells us the gadget got enumerated by a host. The controller
# named in sys.usb.controller is the one UsbDeviceManager itself talks to,
# so that wins. android_usb is the old pre-configfs path (and some vendor
# kernels still keep it around). If neither exists we poll dumpsys.
usb_backend_init() {
  USB_STATE_FILE=
  USB_BACKEND=dumpsys
  _udc=$(getprop sys.usb.controller 2>/dev/null)
  if [ -n "$_udc" ] && [ -r "$SYSFS/class/udc/$_udc/state" ]; then
    USB_STATE_FILE=$SYSFS/class/udc/$_udc/state
    USB_BACKEND="udc:$_udc"
    return 0
  fi
  if [ -r "$SYSFS/class/android_usb/android0/state" ]; then
    USB_STATE_FILE=$SYSFS/class/android_usb/android0/state
    USB_BACKEND=android_usb
    return 0
  fi
  for _f in "$SYSFS"/class/udc/*/state; do
    [ -r "$_f" ] || continue
    case $_f in *dummy*) continue ;; esac
    USB_STATE_FILE=$_f
    _udc=${_f%/state}
    USB_BACKEND="udc:${_udc##*/}"
    return 0
  done
  return 0
}

ps_init() {
  PS_ONLINE=
  for _f in "$SYSFS/class/power_supply/usb/online" "$SYSFS/class/power_supply/usb/present"; do
    if [ -r "$_f" ]; then
      PS_ONLINE=$_f
      break
    fi
  done
}

# 0 = a host has enumerated us (that's a computer, not a wall charger)
gadget_up() {
  if [ -n "$USB_STATE_FILE" ]; then
    read -r _gs <"$USB_STATE_FILE" 2>/dev/null || return 1
    case $_gs in configured | suspended | addressed | CONFIGURED | CONNECTED) return 0 ;; esac
    return 1
  fi
  usb_dump || return 1
  [ "$D_CONNECTED" = true ] && [ "$D_HOST" != true ]
}

# 0 = we're the USB host right now (OTG stick, keyboard...). Never prompt then.
host_mode() {
  for _f in "$SYSFS"/class/typec/port[0-9]/data_role "$SYSFS"/class/dual_role_usb/*/data_role; do
    [ -r "$_f" ] || continue
    read -r _r <"$_f" 2>/dev/null
    case $_r in *'[host]'* | host) return 0 ;; esac
  done
  return 1
}

# The gadget drops off the bus every time functions or ADB change, so
# "not enumerated" alone doesn't mean the cable was pulled. Type-C partner
# and the usb power supply stay put through that. Some drivers never fill
# them in though, so a source only counts if it looked attached when the
# session began.
probe_phys() {
  TRUST_TC=0
  TRUST_PS=0
  for _p in "$SYSFS"/class/typec/port*-partner; do
    if [ -e "$_p" ]; then TRUST_TC=1; break; fi
  done
  if [ -n "$PS_ONLINE" ]; then
    read -r _v <"$PS_ONLINE" 2>/dev/null
    [ "$_v" = 1 ] && TRUST_PS=1
  fi
  return 0
}

# 0 attached, 1 gone, 2 no idea
phys_attached() {
  [ "$TRUST_TC" = 1 ] || [ "$TRUST_PS" = 1 ] || return 2
  if [ "$TRUST_PS" = 1 ]; then
    read -r _v <"$PS_ONLINE" 2>/dev/null
    [ "$_v" = 1 ] && return 0
  fi
  if [ "$TRUST_TC" = 1 ]; then
    for _p in "$SYSFS"/class/typec/port*-partner; do
      [ -e "$_p" ] && return 0
    done
  fi
  return 1
}

fn_lower() {
  case $1 in
    MTP) echo mtp ;; PTP) echo ptp ;; RNDIS) echo rndis ;; MIDI) echo midi ;;
    NCM) echo ncm ;; ADB) echo adb ;; ACCESSORY) echo accessory ;;
    AUDIO_SOURCE) echo audio_source ;; UVC) echo uvc ;;
    *) printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' ;;
  esac
}

# Parse the handler block of `dumpsys usb`. Android 10+ prints key=value
# lines, older releases used "mKey: value". Fills D_* vars.
usb_dump() {
  D_CONNECTED=false
  D_CONFIGURED=false
  D_HOST=false
  D_APPLIED=unknown
  D_LOCKED=unknown
  D_FUNCS=
  _dump=$(dumpsys usb 2>/dev/null) || return 1
  [ -n "$_dump" ] || return 1
  _gotc=0
  while IFS= read -r _l; do
    _l=${_l#"${_l%%[! ]*}"}
    case $_l in
      port_manager* | host_manager* | alsa_manager* | "USB Port State"* | "USB Host State"*) break ;;
      current_functions_applied=*) D_APPLIED=${_l#*=} ;;
      current_functions=*)
        _f=$(fn_lower "${_l#*=}")
        [ "$_f" = adb ] || D_FUNCS=${D_FUNCS:+$D_FUNCS,}$_f
        ;;
      mCurrentFunctions:*)
        _old=${_l#*: }
        _old=$(printf '%s' "$_old" | tr ',' ' ')
        for _f in $_old; do
          case $_f in adb | none) ;; *) D_FUNCS=${D_FUNCS:+$D_FUNCS,}$_f ;; esac
        done
        ;;
      screen_locked=*) D_LOCKED=${_l#*=} ;;
      connected=* | mConnected:*)
        if [ "$_gotc" = 0 ]; then
          D_CONNECTED=${_l#*[=:]}
          D_CONNECTED=${D_CONNECTED# }
          _gotc=1
        fi
        ;;
      configured=*) D_CONFIGURED=${_l#*=} ;;
      mConfigured:*) D_CONFIGURED=${_l#*: } ;;
      host_connected=*) D_HOST=${_l#*=} ;;
      mHostConnected:*) D_HOST=${_l#*: } ;;
    esac
  done <<EOF
$_dump
EOF
  return 0
}

adb_get() {
  ADB_NOW=$(settings get global adb_enabled 2>/dev/null)
  case $ADB_NOW in 0 | 1) ;; *) ADB_NOW=0 ;; esac
}

# Secure keyguard up? UsbDeviceManager tracks exactly that (screen_locked),
# which is the cheapest place to ask. Window policy dump is the fallback.
is_locked() {
  usb_dump
  case $D_LOCKED in
    true) return 0 ;;
    false) return 1 ;;
  esac
  _w=$(dumpsys window policy 2>/dev/null)
  case $_w in *mIsShowing=true* | *mShowingLockscreen=true* | *mDreamingLockscreen=true*) return 0 ;; esac
  return 1
}

foreground_pkg() {
  _l=$(dumpsys activity activities 2>/dev/null | grep -m1 -E 'topResumedActivity=|mResumedActivity:|ResumedActivity:')
  [ -n "$_l" ] || _l=$(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus=')
  printf '%s\n' "$_l" | sed -n 's/.*{[^ ]* u[0-9]* \([A-Za-z0-9_.]*\)\/.*/\1/p' | head -n1
}

# ---------------------------------------------------------------- applying

suppress_for() {
  uptime_now
  echo $((NOW + $1)) >"$SUPPRESS"
}

# apply_cfg MODE ADB
# USB functions first, ADB second - same order the framework uses. Never
# put "adb" in the function list, Android 14+ throws on that.
apply_cfg() {
  is_mode "$1" || return 2
  case $2 in 0 | 1) ;; *) return 2 ;; esac
  # both steps re-enumerate the gadget, keep the daemon from reading that as an unplug
  suppress_for 10
  _rc=0
  _fn=$1
  [ "$_fn" = charging ] && _fn=none
  _o=
  if [ "$_fn" = keep ]; then
    : # functions stay whatever Android (or the car) picked
  elif [ "$SDK" -ge 28 ]; then
    _o=$(svc usb setFunctions "$_fn" 2>&1)
  else
    _o=$(svc usb setFunction "$_fn" 2>&1)
  fi
  case $_o in
    *rror* | *xception*)
      log_msg E "svc usb refused $_fn: $(printf '%s' "$_o" | tail -n1)"
      _rc=1
      ;;
  esac
  adb_get
  if [ "$ADB_NOW" != "$2" ]; then
    settings put global adb_enabled "$2" >/dev/null 2>&1 || {
      log_msg E "could not set adb_enabled=$2"
      _rc=1
    }
  fi
  log_msg I "apply mode=$1 adb=$2 rc=$_rc"
  return $_rc
}

# verify_cfg MODE ADB [tries] - waits for the framework to report it back
verify_cfg() {
  _want=$1
  [ "$_want" = charging ] && _want=
  _i=0
  while [ "$_i" -lt "${3:-8}" ]; do
    usb_dump
    adb_get
    [ "$1" = keep ] && _want=$D_FUNCS
    if [ "$D_FUNCS" = "$_want" ] && [ "$ADB_NOW" = "$2" ]; then
      return 0
    fi
    sleep 1
    _i=$((_i + 1))
  done
  return 1
}

# ---------------------------------------------------------------- remembered choices
#
# remembered.list: fp|decision|mode|adb|epoch|label
#   decision = data (mode + adb get repeated) or charge (data cut)
#   epoch    = last time that device was connected (set on connect and on unplug)
# Wall clock on purpose: "12 h since I was last in the car" spans reboots.

# mem_get FP: fills M_DEC M_MODE M_ADB M_TIME M_LABEL, 0 = found and still fresh
mem_get() {
  M_DEC=
  M_MODE=
  M_ADB=
  M_TIME=0
  M_LABEL=
  [ "$cfg_remember_hours" -gt 0 ] 2>/dev/null || return 1
  [ -r "$MEMF" ] || return 1
  while IFS='|' read -r _mf _md _mm _ma _mt _ml; do
    [ "$_mf" = "$1" ] || continue
    case $_mt in '' | *[!0-9]*) return 1 ;; esac
    case $_md in data | charge) ;; *) return 1 ;; esac
    is_mode "$_mm" || return 1
    M_DEC=$_md
    M_MODE=$_mm
    M_ADB=$_ma
    M_TIME=$_mt
    M_LABEL=$_ml
    [ $(($(date +%s) - _mt)) -lt $((cfg_remember_hours * 3600)) ]
    return
  done <"$MEMF"
  return 1
}

# mem_put FP DECISION MODE ADB LABEL - replaces any older line for FP
mem_put() {
  is_fp "$1" || return 1
  _now=$(date +%s)
  _lbl=$(label_clean "$5")
  {
    if [ -r "$MEMF" ]; then
      while IFS= read -r _ml; do
        [ "${_ml%%|*}" = "$1" ] || printf '%s\n' "$_ml"
      done <"$MEMF"
    fi
    echo "$1|$2|$3|$4|$_now|$_lbl"
  } >"$MEMF.tmp" && mv -f "$MEMF.tmp" "$MEMF"
}

# mem_touch FP - "connected just now", keeps the decision as it was
mem_touch() {
  [ -r "$MEMF" ] || return 0
  _now=$(date +%s)
  _hit=0
  while IFS='|' read -r _mf _md _mm _ma _mt _ml; do
    if [ "$_mf" = "$1" ]; then
      echo "$_mf|$_md|$_mm|$_ma|$_now|$_ml"
      _hit=1
    elif [ -n "$_mf" ]; then
      echo "$_mf|$_md|$_mm|$_ma|$_mt|$_ml"
    fi
  done <"$MEMF" >"$MEMF.tmp"
  if [ "$_hit" = 1 ]; then mv -f "$MEMF.tmp" "$MEMF"; else rm -f "$MEMF.tmp"; fi
  return 0
}

mem_forget() {
  [ -r "$MEMF" ] || return 0
  while IFS= read -r _ml; do
    [ "${_ml%%|*}" = "$1" ] || printf '%s\n' "$_ml"
  done <"$MEMF" >"$MEMF.tmp"
  mv -f "$MEMF.tmp" "$MEMF"
}

# the computer/car/dock on the other end right now, from the daemon's peer file
peer_pc() {
  PC_FP=
  PC_LABEL=
  [ -r "$PEERF" ] || return 1
  while IFS='|' read -r _pf _pl _; do
    case $_pf in
      pc:*)
        PC_FP=$_pf
        PC_LABEL=${_pl%, data blocked}
        return 0
        ;;
    esac
  done <"$PEERF"
  return 1
}

# ---------------------------------------------------------------- the UI

# WebUI hosts I know about, best guess first. Whoever owns root goes first
# because its manager is guaranteed to be there.
ui_candidates() {
  [ "$cfg_ui_host" = auto ] || echo "$cfg_ui_host"
  [ -d /data/adb/ap ] && echo me.bmax.apatch/.ui.WebUIActivity
  if [ -d /data/adb/ksu ]; then
    echo me.weishu.kernelsu/.ui.webui.WebUIActivity
    echo com.rifsxd.ksunext/.ui.webui.WebUIActivity
    echo com.sukisu.ultra/.ui.webui.WebUIActivity
  fi
  echo com.dergoogler.mmrl.wx/.ui.webui.activity.NewProcessWebUIActivity
  echo io.github.a13e300.ksuwebui/.WebUIActivity
}

pkg_installed() {
  [ -d "/data/data/$1" ] || [ -d "/data/user/0/$1" ]
}

ui_pick() {
  for _c in $(ui_candidates); do
    pkg_installed "${_c%%/*}" && { echo "$_c"; return 0; }
  done
  return 1
}

# Every host reads the module id from a different place (old KSU/APatch:
# "id" extra, new KSU: ksu://webui?id=, WebUI X: MODULE_ID), so just send
# all of them. We're root, so non-exported activities are fine.
launch_ui() {
  UI_HOST=
  for _c in $(ui_candidates); do
    pkg_installed "${_c%%/*}" || continue
    _out=$(am start -n "$_c" -e id "$MODID" -e name "$MODNAME" -e MODULE_ID "$MODID" \
      -d "ksu://webui?id=$MODID" 2>&1)
    case $_out in
      *Error* | *xception*)
        log_msg W "$_c would not start: $(printf '%s' "$_out" | tail -n1)"
        continue
        ;;
    esac
    UI_HOST=$_c
    echo "$_c" >"$RUN/ui_host"
    return 0
  done
  return 1
}

# Only used when there's no WebUI app at all, once per boot. cmd notification
# has no cancel command, so I keep this to the one message that matters.
notify_nohost() {
  [ "$cfg_notify" = 1 ] || return 0
  [ -f "$RUN/nohost.notified" ] && return 0
  : >"$RUN/nohost.notified"
  _a=off
  [ "$cfg_default_adb" = 1 ] && _a=on
  cmd notification post -S bigtext -t "$MODNAME" usbmgr_nohost \
    "No WebUI app found, so the default ($cfg_default_mode, ADB $_a) was applied. Install KsuWebUIStandalone or WebUI X to get the chooser." \
    >/dev/null 2>&1
  return 0
}

daemon_pid() {
  DPID=
  [ -r "$PIDF" ] || return 1
  read -r DPID <"$PIDF"
  [ -n "$DPID" ] && [ -d "/proc/$DPID" ] && grep -q usbmgrd "/proc/$DPID/cmdline" 2>/dev/null
}

# Requests travel as flag files (reload, prompt, rescan) so they survive a
# daemon that's sleeping instead of reading the FIFO. The FIFO write only
# wakes it up early.
wake_daemon() {
  case $1 in reload | prompt | rescan) : >"$RUN/$1.flag" ;; esac
  [ -p "$FIFO" ] || return 0
  # opening read+write never blocks, even if the daemon is dead
  printf '%s\n' "${1:-wake}" 1<>"$FIFO" 2>/dev/null
  return 0
}

root_impl() {
  if [ -d /data/adb/ap ]; then echo APatch
  elif [ -d /data/adb/ksu ]; then echo KernelSU
  elif [ -d /data/adb/magisk ]; then echo Magisk
  else echo unknown
  fi
}

mod_version() {
  sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1
}

# ---------------------------------------------------------------- blocking

AUTHDEF=$SYSFS/module/usbcore/parameters/authorized_default

# Kernel switches from the usb-hardening patches in dev-dcs/New-GKI-Dev_DcS-Way.
# When the running kernel has them they're the real block: the hub never
# enumerates new devices and the UDC core refuses to pull up, so there's no
# window at all. Everything below them is the fallback for stock kernels.
KSYS=${USBMGR_SYSCTL:-/proc/sys/kernel}
KGATE_HOST=$KSYS/deny_new_usb
KGATE_GADGET=$KSYS/deny_usb_gadget

kgate_init() {
  K_HOST=0
  K_GADGET=0
  [ -w "$KGATE_HOST" ] && K_HOST=1
  [ -w "$KGATE_GADGET" ] && K_GADGET=1
  return 0
}

# kgate_set 1|0. Marker files remember what we flipped, so clearing never
# touches a switch somebody else set.
kgate_set() {
  if [ "$1" = 1 ]; then
    if [ "$K_GADGET" = 1 ] && echo 1 >"$KGATE_GADGET" 2>/dev/null; then
      : >"$RUN/kgadget.set"
    fi
    if [ "$K_HOST" = 1 ] && echo 1 >"$KGATE_HOST" 2>/dev/null; then
      : >"$RUN/khost.set"
    fi
  else
    if [ -f "$RUN/kgadget.set" ]; then
      echo 0 >"$KGATE_GADGET" 2>/dev/null
      rm -f "$RUN/kgadget.set"
    fi
    if [ -f "$RUN/khost.set" ]; then
      echo 0 >"$KGATE_HOST" 2>/dev/null
      rm -f "$RUN/khost.set"
    fi
  fi
  return 0
}

# per tick while blocked: put a switch back if something cleared it.
# Returns 0 when it had to.
kgate_enforce() {
  _kf=1
  if [ -f "$RUN/kgadget.set" ]; then
    read -r _v <"$KGATE_GADGET" 2>/dev/null
    if [ "$_v" != 1 ]; then
      echo 1 >"$KGATE_GADGET" 2>/dev/null
      _kf=0
    fi
  fi
  if [ -f "$RUN/khost.set" ]; then
    read -r _v <"$KGATE_HOST" 2>/dev/null
    if [ "$_v" != 1 ]; then
      echo 1 >"$KGATE_HOST" 2>/dev/null
      _kf=0
    fi
  fi
  return $_kf
}

# "0", "1" or "absent", for status output
kgate_state() {
  if [ -r "$1" ]; then
    read -r _v <"$1"
    echo "${_v:-?}"
  else
    echo absent
  fi
}

# anything in run/ that says a block is still holding (daemon restarted mid-block)
block_leftovers() {
  [ -f "$RUN/kgadget.set" ] || [ -f "$RUN/khost.set" ] || [ -s "$RUN/udc.saved" ] ||
    [ -f "$RUN/authdef.saved" ] || [ -f "$RUN/legacy.cut" ] || [ -s "$RUN/hubs.cut" ] ||
    [ -s "$RUN/devs.cut" ]
}

udc_list() {
  UDC_LIST=
  for _r in $CFGFS_ROOTS; do
    for _u in "$_r"/usb_gadget/*/UDC; do
      [ -f "$_u" ] && UDC_LIST="$UDC_LIST $_u"
    done
  done
}

# Detach every gadget from its controller. The computer then sees nothing,
# not even the locked MTP device Android exposes in "charge only" mode.
# Power still flows. Returns 0 when something actually got cut.
gadget_cut() {
  _cut=1
  for _u in $UDC_LIST; do
    read -r _cur <"$_u" 2>/dev/null
    case $_cur in '' | none) continue ;; esac
    echo "$_u $_cur" >>"$RUN/udc.saved"
    echo none >"$_u" 2>/dev/null && _cut=0
  done
  # pre-configfs kernels
  if [ -z "$UDC_LIST" ]; then
    _e=$SYSFS/class/android_usb/android0/enable
    if [ -w "$_e" ]; then
      read -r _cur <"$_e"
      if [ "$_cur" = 1 ] && echo 0 >"$_e"; then
        : >"$RUN/legacy.cut"
        _cut=0
      fi
    fi
  fi
  return $_cut
}

gadget_restore() {
  if [ -r "$RUN/udc.saved" ]; then
    while read -r _u _name; do
      [ -f "$_u" ] || continue
      read -r _cur <"$_u" 2>/dev/null
      case $_cur in '' | none) echo "$_name" >"$_u" 2>/dev/null ;; esac
    done <"$RUN/udc.saved"
    rm -f "$RUN/udc.saved"
  fi
  if [ -f "$RUN/legacy.cut" ]; then
    echo 1 >"$SYSFS/class/android_usb/android0/enable" 2>/dev/null
    rm -f "$RUN/legacy.cut"
  fi
  return 0
}

# Phone as USB host (OTG). New host controllers read usbcore's
# authorized_default when they get created, which on phones happens at the
# moment the port switches to host. 0 = devices enumerate (so we can still
# log them) but never get a configuration or a driver.
host_param_cut() {
  [ -w "$AUTHDEF" ] || return 0
  read -r _cur <"$AUTHDEF"
  [ -f "$RUN/authdef.saved" ] || echo "$_cur" >"$RUN/authdef.saved"
  [ "$_cur" = 0 ] || echo 0 >"$AUTHDEF"
}

# Per tick while blocked and in host mode: catches controllers that existed
# before we flipped the parameter. Hard-wired ("fixed") devices are left alone.
host_enforce() {
  for _h in "$SYSFS"/bus/usb/devices/usb*; do
    [ -w "$_h/authorized_default" ] || continue
    read -r _a <"$_h/authorized_default"
    if [ "$_a" != 0 ]; then
      echo 0 >"$_h/authorized_default" && echo "$_h" >>"$RUN/hubs.cut"
    fi
  done
  for _d in "$SYSFS"/bus/usb/devices/*; do
    case ${_d##*/} in usb* | *:*) continue ;; esac
    [ -w "$_d/authorized" ] || continue
    _rm=
    [ -r "$_d/removable" ] && read -r _rm <"$_d/removable"
    [ "$_rm" = fixed ] && continue
    read -r _a <"$_d/authorized"
    if [ "$_a" = 1 ]; then
      echo 0 >"$_d/authorized" && echo "$_d" >>"$RUN/devs.cut"
    fi
  done
}

host_restore() {
  if [ -r "$RUN/authdef.saved" ] && [ -w "$AUTHDEF" ]; then
    read -r _v <"$RUN/authdef.saved"
    echo "${_v:--1}" >"$AUTHDEF"
  fi
  rm -f "$RUN/authdef.saved"
  if [ -r "$RUN/hubs.cut" ]; then
    while read -r _h; do
      [ -w "$_h/authorized_default" ] && echo 1 >"$_h/authorized_default"
    done <"$RUN/hubs.cut"
    rm -f "$RUN/hubs.cut"
  fi
  if [ -r "$RUN/devs.cut" ]; then
    while read -r _d; do
      [ -w "$_d/authorized" ] && echo 1 >"$_d/authorized"
    done <"$RUN/devs.cut"
    rm -f "$RUN/devs.cut"
  fi
  return 0
}

# ---------------------------------------------------------------- peers

fp_clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48; }

label_clean() {
  printf '%s' "$1" | tr -d '|"\\\r\n' | tr -s ' ' | cut -c1-64 | sed 's/^ //; s/ $//'
}

is_fp() {
  case $1 in '' | *[!A-Za-z0-9._:=-]*) return 1 ;; esac
  return 0
}

# cheap "did anything change" string for host mode, no forks
host_sig() {
  HSIG=
  for _d in "$SYSFS"/bus/usb/devices/*; do
    case ${_d##*/} in usb* | *:*) continue ;; esac
    [ -e "$_d/idVendor" ] && HSIG="$HSIG ${_d##*/}"
  done
}

# devices plugged into the phone: "fp|label|strength" per line, hubs skipped
host_devices() {
  for _d in "$SYSFS"/bus/usb/devices/*; do
    case ${_d##*/} in usb* | *:*) continue ;; esac
    [ -r "$_d/idVendor" ] || continue
    _cls=
    [ -r "$_d/bDeviceClass" ] && read -r _cls <"$_d/bDeviceClass"
    [ "$_cls" = 09 ] && continue
    read -r _vid <"$_d/idVendor"
    read -r _pid <"$_d/idProduct"
    _ser=
    _man=
    _prod=
    [ -r "$_d/serial" ] && read -r _ser <"$_d/serial"
    [ -r "$_d/manufacturer" ] && read -r _man <"$_d/manufacturer"
    [ -r "$_d/product" ] && read -r _prod <"$_d/product"
    _lbl=$(label_clean "$_man $_prod")
    [ -n "$_lbl" ] || _lbl="USB device"
    if [ -n "$_ser" ]; then
      echo "usb:$_vid:$_pid:$(fp_clean "$_ser")|$_lbl ($_vid:$_pid)|unique"
    else
      echo "usb:$_vid:$_pid|$_lbl ($_vid:$_pid)|model"
    fi
  done
}

# What a computer looks like from the phone's side. Without help from the
# host there's no serial to read, so unless the port speaks USB PD and
# reports an identity, this only describes the *kind* of port. The UI says so.
pc_fingerprint() {
  _pd=no
  _id=
  _op=unknown
  _spd=unknown
  _typ=unknown
  for _p in "$SYSFS"/class/typec/port*-partner; do
    [ -d "$_p" ] || continue
    [ -r "$_p/supports_usb_power_delivery" ] && read -r _pd <"$_p/supports_usb_power_delivery"
    if [ -r "$_p/identity/id_header" ] && [ -r "$_p/identity/product" ]; then
      read -r _h <"$_p/identity/id_header"
      read -r _pp <"$_p/identity/product"
      case $_h$_pp in
        0x*0x*)
          _v=$((_h & 0xffff))
          _pr=$(((_pp >> 16) & 0xffff))
          [ "$_v" != 0 ] && _id=$(printf '%04x:%04x' "$_v" "$_pr")
          ;;
      esac
    fi
    break
  done
  for _f in "$SYSFS"/class/typec/port[0-9]/power_operation_mode; do
    [ -r "$_f" ] && read -r _op <"$_f"
    break
  done
  if [ -n "$USB_STATE_FILE" ] && [ -r "${USB_STATE_FILE%/state}/current_speed" ]; then
    read -r _spd <"${USB_STATE_FILE%/state}/current_speed"
  fi
  if [ -r "$SYSFS/class/power_supply/usb/usb_type" ]; then
    read -r _t <"$SYSFS/class/power_supply/usb/usb_type"
    case $_t in
      *'['*']'*)
        _t=${_t#*\[}
        _typ=${_t%%\]*}
        ;;
      *) _typ=$_t ;;
    esac
  elif [ -r "$SYSFS/class/power_supply/usb/real_type" ]; then
    read -r _typ <"$SYSFS/class/power_supply/usb/real_type"
  fi
  if [ -n "$_id" ]; then
    echo "pc:pd:$_id|USB host or dock (PD $_id)|model"
    return 0
  fi
  _op=$(fp_clean "$_op")
  _spd=$(fp_clean "$_spd")
  _typ=$(fp_clean "$_typ")
  echo "pc:op=$_op:spd=$_spd:t=$_typ:pd=$(fp_clean "$_pd")|USB host ($_spd, $_typ)|generic"
}

# anything attached right now, even with data blocked? (no trust tricks here)
phys_now() {
  for _p in "$SYSFS"/class/typec/port*-partner; do
    [ -e "$_p" ] && return 0
  done
  if [ -n "$PS_ONLINE" ]; then
    read -r _v <"$PS_ONLINE" 2>/dev/null
    [ "$_v" = 1 ] && return 0
  fi
  return 1
}

# With data blocked nothing enumerates, so the only hint that a computer
# (and not a charger) is on the other end is BC1.2 detection: SDP/CDP are
# data ports. Type-C/PD chargers and laptops look alike, those aren't logged.
looks_like_data_host() {
  [ -r "$SYSFS/class/power_supply/usb/usb_type" ] || return 1
  read -r _t <"$SYSFS/class/power_supply/usb/usb_type"
  case $_t in *'[SDP]'* | *'[CDP]'*) return 0 ;; esac
  return 1
}

is_trusted() {
  [ -r "$TRUST_LIST" ] || return 1
  while IFS='|' read -r _tfp _; do
    [ "$_tfp" = "$1" ] && return 0
  done <"$TRUST_LIST"
  return 1
}

# history line: id|epoch|kind|fp|label|strength|trusted|result
history_add() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$@" >>"$HISTORY"
  _n=$(wc -l <"$HISTORY" 2>/dev/null)
  if [ "${_n:-0}" -gt 400 ]; then
    tail -n 300 "$HISTORY" >"$HISTORY.tmp" && mv -f "$HISTORY.tmp" "$HISTORY"
  fi
  return 0
}

# history_set ATTACH RESULT - closes the still-open lines of one attach
history_set() {
  [ -f "$HISTORY" ] || return 0
  sed -i -e "s/^\($1\.[0-9]*|.*\)|active\$/\1|$2/" \
    -e "s/^\($1\.[0-9]*|.*\)|armed\$/\1|$2/" "$HISTORY"
}

# ---------------------------------------------------------------- guard bits

# false before the first unlock after boot (BFU): user data is still
# encrypted then, so restarting would buy nothing and could loop
ce_unlocked() {
  [ "$(getprop sys.user.0.ce_available 2>/dev/null)" = true ] && return 0
  am get-started-user-state 0 2>/dev/null | grep -q RUNNING_UNLOCKED
}

buzz() {
  cmd vibrator_manager synced -f oneshot "$1" >/dev/null 2>&1 ||
    cmd vibrator vibrate -f "$1" usbguard >/dev/null 2>&1
  return 0
}

notify_post() {
  cmd notification post -S bigtext -t "$2" "$1" "$3" >/dev/null 2>&1
  return 0
}

# cmd notification can't cancel, but it can snooze. Ten years is close enough.
notify_hide() {
  _key=$(cmd notification list 2>/dev/null | grep -m1 "|$1|")
  [ -n "$_key" ] && cmd notification snooze --for 315360000000 "$_key" >/dev/null 2>&1
  return 0
}

# Leftovers in run/ from the previous boot describe kernel state that's gone
# now. Called first thing by post-fs-data, service.sh and the daemon.
run_fresh() {
  mkdir -p "$RUN"
  read -r _bid </proc/sys/kernel/random/boot_id 2>/dev/null
  _old=
  [ -r "$RUN/boot_id" ] && read -r _old <"$RUN/boot_id"
  [ "$_bid" = "$_old" ] && return 0
  rm -f "$RUN/udc.saved" "$RUN/authdef.saved" "$RUN/hubs.cut" "$RUN/devs.cut" "$RUN/legacy.cut" \
    "$RUN/kgadget.set" "$RUN/khost.set" "$BLOCKF" "$GUARDF" "$PEERF" "$IDLEF"
  echo "$_bid" >"$RUN/boot_id"
}

wakelock() {
  echo usbguard >"$SYSFS/power/wake_$1" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- auto restart

# Panel backlight > 0 = screen (or AOD) is on, the only time someone can
# unlock. No backlight node at all = can't tell, caller assumes on.
screen_on() {
  _any=0
  for _b in "$SYSFS"/class/backlight/*/brightness "$SYSFS"/class/leds/lcd-backlight/brightness; do
    [ -r "$_b" ] || continue
    _any=1
    read -r _v <"$_b" 2>/dev/null
    [ "${_v:-0}" != 0 ] && return 0
  done
  [ "$_any" = 0 ]
}

# ringing or off-hook on any SIM
in_call() {
  dumpsys telephony.registry 2>/dev/null | grep -q 'mCallState=[12]'
}

# Android's own cache trimmer: asks for far more free space than exists, so
# it clears every app's cache dirs. Never longer than $1 seconds, the restart
# matters more than the cleanup.
clean_caches() {
  log_msg I "clearing app caches before restart"
  if timeout "$1" pm trim-caches 9999G >/dev/null 2>&1; then
    log_msg I "app caches cleared"
  else
    log_msg W "cache cleanup didn't finish within ${1}s (or failed), restarting anyway"
  fi
  return 0
}

# init's reboot path (sync, unmount), not busybox's. Normally never returns.
do_reboot() {
  sync
  if [ -x /system/bin/reboot ]; then
    /system/bin/reboot
  else
    setprop sys.powerctl reboot
  fi
  sleep 10
  # still here? ask the framework instead
  log_msg E "reboot did not happen, trying svc power reboot"
  svc power reboot >/dev/null 2>&1
}
