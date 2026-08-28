# WS73 NearLink - 4.4 armhf cross-build plan (frozen)

> Goal: bring up the WS73 NearLink 4-module set on target
> `4.4.35_hi3798mv310` (`_hi3798mv310`).
> Basis: handoff `handoff-nearlink-armhf44.md` + `SDK-INTEL.md` +
> `06/10/SHIFU-BUILD-LIST.md`, fully verified.

Original Chinese manuscript: `/tmp/plan-ws73-armhf44.md`.

## Modules (order matters, first one does firmware download)

1. `driver/platform/` -> `plat_soc.ko` (HCC/USB + firmware download + PM)
2. `driver/bsle/ble_driver/linux/` -> `ble_soc.ko` (BlueZ hci0)
3. `driver/bsle/sle_driver/` -> `sle_soc.ko` (`/dev/hwsle` + SLE)
4. `driver/wifi/` -> `wifi_soc.ko` (cfg80211)

Load order: `plat -> ble -> sle -> wifi`.

## Cross-build config (4.4 armhf, overriding ws73_usb_light.config defaults)

```ini
WSCFG_USING_GCC=y
WSCFG_CROSS_COMPILE="arm-linux-gnueabihf-"                         # /usr/bin/arm-linux-gnueabihf-gcc 16.1.0 (verified)
WSCFG_KERNEL_DIR="/opt/reasonix-cradle/builds-boy/histb-mv300-src/source/kernel/linux-4.4.y"  # contains .config + Module.symvers + arch/arm/include
WSCFG_ARCH_NAME="arm"
WSCFG_BUS_USB=y
```

Reference: `nearlink/sdk/ws73_sdk_linux_WS73_1.10.110/build/config/ws73_usb_light.config`
defaults are `arm-himix100-linux-` + `Hi3518 4.9.y`; only override the 4 lines above.

## Build flow

```bash
cd nearlink/sdk/ws73_sdk_linux_WS73_1.10.110

# 0) Kernel side: ensure 060 mv310 .config + Module.symvers exist
#    (CONFIG_XFS_FS=m / CONFIG_USB_STORAGE=y / CONFIG_TUN=n)
grep CONFIG_LOCALVERSION /opt/reasonix-cradle/builds-boy/histb-mv300-src/source/kernel/linux-4.4.y/.config
ls /opt/reasonix-cradle/builds-boy/histb-mv300-src/source/kernel/linux-4.4.y/Module.symvers

# 1) Generate Kconfig header (falls back to ws73_default.config if .config missing)
make prepare          # -> output/bin/autoconfig.h  + output/bin/ws73_cfg.ini

# 2) Full build -j1 (mandatory!)
bash /home/archivalera/plum/zcode-projects/nearlink/scripts/wait-for-idle.sh 1.0  # ~10% of 8 cores, 30s timeout fallback
make -j1              # top-level make -j$(nproc) pulls wifi 253 files + 3 drivers in parallel -> OOM black screen (seen twice)

# Single-module (more stable, optional)
cd driver/platform && make -j1 WSCFG_KCONFIG_CONFIG=<sdk>/.config \
  DIR_MAP_CONFIG_FILE=release.mk WSCFG_AUTOCONFIG_H=<sdk>/output/bin/autoconfig.h modules
```

## 7.x -> 4.4 adaptation (conclusion: zero changes needed)

| File | What 7.x changed | Needed on 4.4? |
|---|---|---|
| driver/platform/Makefile | EXTRA_CFLAGS->ccflags-y / clang -mcmodel | No (gcc armhf) |
| osal_fileops.c / oal_kernel_file.h | set_fs no-op | No (set_fs still exists on 4.4) |
| osal_timer.c | del_timer->timer_delete | Reverse: still del_timer on 4.4 |
| cfg/ini.h | i_ctime->i_ctime_sec | No |

Approach: `git diff` only the generic fixes unrelated to armhf; revert the pure 7.x compat layer.

## Firmware (copy to target /etc/ws73/)

```
firmware/us/ws73.bin          # 143,956 B
firmware/us/wifi_cali.bin
firmware/us/btc_cali.bin
firmware/us/wow.bin
build/config/ws73_cfg_default.ini -> /etc/ws73_cfg.ini
```

## On-target verification

```bash
# ccache 10G + compression already configured
ccache -s

# Copy modules
cp plat_soc.ko ble_soc.ko sle_soc.ko wifi_soc.ko /lib/modules/$(uname -r)/
depmod -a

# Load in order
insmod plat_soc.ko && dmesg | grep wireless_usb   # expect: registered new interface driver wireless_usb
insmod ble_soc.ko  # -> hci0
insmod sle_soc.ko  # -> /dev/hwsle
insmod wifi_soc.ko # -> wlan0

# HHD-01 status (WS63, same family)
# /dev/ttyUSB0 CH340 115200 AT->OK, SDK 1.10.102, violin 11:22:33:44:55:66
```

## 060 SDK notes (verified together)

* `hi3798mv310_defconfig` vs `hi3798mv300_defconfig` differ only in
  `ARCH_HI3798MV310`/`ARCH_HI3798MV2X` + `LOCALVERSION`.
* `XFS/USB-storage`: `CONFIG_XFS_FS=m` builds `xfs.ko 1.2M` via `M=fs/xfs modules`;
  `CONFIG_USB_STORAGE=y` (built-in, no ko needed).
* `CONFIG_TUN=n`: intentionally off in both defconfigs; needs out-of-tree `drivers/net/tun.ko`.
* `BBR3/FQ`: no BBR on 4.4, `CONFIG_NET_SCHED=n`, not modular; `higmac TSO/GRO` already present.

## Build discipline

* Run `wait-for-idle.sh 1.0` before every build, proceed only when load <= 1.0.
* Mandatory `-j1`; top-level `CPU_NUM=$(nproc)` parallel will explode.
* ccache auto `cc` prefix, current hit rate 14.39%.

---

*Plan frozen 2026-08-28. Next: wire up the USB dongle on both host and box.*
