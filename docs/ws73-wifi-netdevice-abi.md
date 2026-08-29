# WS73 WiFi (wifi_soc.ko) on mv310 4.4 — build OK, runtime blocked by net_device ABI

Status 2026-08-29: **build fixed, runtime deferred**. Onboard RTL8822BS already
provides WiFi, so WS73 WiFi is not on the critical path.

## What works

- `wifi_soc.ko` builds clean on 4.4 after:
  - `_PRE_WLAN_FEATURE_WPA3` off (4.4 lacks SAE/OWE cfg80211 API)
  - `cfg80211_ch_switch_notify` 2-arg prototype below 4.5 (oal_cfg80211.c)
  - `wdev->preset_chandef` direct member below 4.7 (wal_linux_cfg80211.c)
- Load chain boots: `mv310-pad.ko -> cfg80211.ko -> wifi_soc.ko`
  (cfg80211 rebuilt from kernel tree net/wireless with the corrected config).
- Init trigger is sysfs: `echo init > /sys/kernel/wifi` (module init only
  registers the node; real init = mpxx_host_main_init).

## The wall

`echo init > /sys/kernel/wifi` oopses in `hmac_vap_creat_netdev_etc+0xc4`
(memcpy to `net_device->dev_addr`). Root cause is the same class as the
sk_buff fix (CONFIG_NF_CONNTRACK/BRIDGE/NET_SCHED), but `struct net_device`
is far more CONFIG-sensitive (RPS/XPS, WEXT, qdisc, ndisc, sysfs...). The
module's compiled-in offsets do not match the running kernel's layout, so a
6-byte write at the module's `dev_addr` offset lands past the kernel's
allocation.

## Paths forward (if WS73 WiFi is ever needed)

1. Recover/derive the running kernel's exact .config (board has no
   /proc/config.gz; kernel built 2025-11-09 on `root@debian` from
   HiSTBLinuxV100R005C00SPC060). Reproduce byte-exact net_device layout,
   rebuild wifi_soc. Verify with an offsetof-probe module like the sk_buff
   offko trick before loading.
2. Or ship a rebuilt kernel (we control boot chain via fastboot) so module
   and kernel configs match by construction.
3. Or ask the WS73 vendor for a 4.4-mv310-targeted wifi_soc binary.

Module probe evidence: offko printed skb offsets matching the running kernel
only after enabling NF_CONNTRACK + BRIDGE(_NETFILTER) + NET_SCHED in the SDK
kernel header config.
