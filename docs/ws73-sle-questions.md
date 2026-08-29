# WS73 SLE (NearLink) host stack questions for the SLE repo owner

Target board: Hi3798MV310 STB, Debian 11 **glibc armhf** (32-bit, hard-float),
kernel 4.4.35_hi3798mv310. WS73 USB dongle (ffff:3733). BLE already works
(hci0 UP, scan OK). SLE is the next target.

## What we already know (SDK 1.10.110)

- `sle_soc.ko` loads on 4.4 and creates `/dev/hwsle` (verified 8/28).
- `application/lib/rv1126/libsle_host.a` is ARM **hard-float VFP** — ABI matches
  our `arm-histbv320-linux` toolchain.
- `bin/stm32mp157/sle/sparklinkd` is 32-bit ARM but **uClibc**
  (`NEEDED: libc.so.0, ld-uClibc.so.1`) — incompatible with our glibc rootfs.
- `sample/sle/sle_uuid/` contains server source we can rebuild.
- A separate `sle_chba.ko` ships under `bin/3518_usb/sle/`.

## Questions (priority order)

1. **sparklinkd for glibc armhf**: do you have (or can you build) a
   `sparklinkd`/`sparklinkctrl` linked against **glibc** (or fully static,
   musl/static-uClibc) for 32-bit ARM hard-float? If source of the SLE host
   daemon can be released, we can build it ourselves against
   `lib/rv1126/libsle_host.a`.

2. **Correct lib variant for our target**: is `lib/rv1126/libsle_host.a`
   (ARM hard-float) the right host library for a 32-bit armhf glibc target?
   If not, which `application/lib/<board>/` variant matches armhf, and which
   prebuilt `sparklinkd` pairs with it?

3. **sle_soc.ko <-> userland interface**: what is the userland/kernel contract
   for `/dev/hwsle`? Which ioctls does sparklinkd issue, is there a doc header
   (we see `include/bsle/` in the SDK), and is sparklinkd the only supported
   daemon? Do we need `sle_chba.ko` too (what does CHBA add, and does it
   change the load order: `plat -> ble -> sle -> chba -> wifi`?)?

4. **SLE bring-up sequence**: after `insmod sle_soc.ko`, what is the minimal
   sequence to (a) set SLE address, (b) start SLE advertising, (c) scan for
   and connect another WS73/HHD SLE device? Any vendor/HCI prerequisites on
   the plat side (e.g. `H2D_MSG_SLE_OPEN` flow we see in plat_pm_wlan.c)?

5. **Three-mode coexistence**: are there known constraints running
   BLE + SLE + WiFi concurrently on one WS73 USB dongle? `bt_coex_mode=1`
   is set in our ini — is that correct for USB dongle operation, or does USB
   need a different coex config?

6. **SLE security/pairing**: for a simple point-to-point link between two
   devices (SSAP server/client sample), is default no-auth connect sufficient,
   or must host configure pairing keys? Any sample showing
   `sle_uuid_server` + `sle_uuid_client` interop on two dongles?

7. **Known 4.4 issues**: are there known kernel-4.4-specific bugs in
   sle_soc.ko / sle host driver (memory, workqueue, timer) we should patch
   proactively? (We hit several in ble_soc on 4.4 and fixed them; happy to
   contribute the patches back.)

## Environment for repro

- Board SSH: 10.42.0.81:6440 (key available), modules at /opt/ws73/
- BLE verified: hci0 UP RUNNING, bluetoothctl scan finds real devices
- sle_soc.ko on board is built 8/28 (pre-CONFIG fix); will rebuild with
  NF_CONNTRACK/BRIDGE/NET_SCHED-enabled kernel headers (sk_buff +12B fix)
  before SLE testing.
