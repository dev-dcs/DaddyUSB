#!/system/bin/sh
# Early part of the USB block. With the dev-dcs kernel this flips the kernel
# switches before init ever binds the gadget, so a computer never sees the
# phone during boot. On stock kernels it at least sets usbcore's
# authorized_default before host controllers come up; service.sh does the rest.
MODDIR=${0%/*}
# shellcheck source=common.sh
. "$MODDIR/common.sh"

run_fresh
conf_load
if [ "$cfg_block" = 1 ]; then
  kgate_init
  kgate_set 1
  host_param_cut
fi
exit 0
