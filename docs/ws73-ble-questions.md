# WS73 BLE hci0 issue -- questions for the WS73 provider

Target: Hi3798MV310 (armhf 4.4.35), for cross-build on mv310 toolchain.

## Environment

- Board: Hi3798MV310 STB, kernel `4.4.35_hi3798mv310` (armv7l), SDK toolchain `arm-histbv320-linux`
- WS73 USB dongle: `ffff:0x3733`, 5 EP (second-stage enumeration OK)
- Load order: `plat_soc.ko` (firmware_download_etc::succ) -> `ble_soc.ko` (bt_register_hci_dev OK, hci0 appears)
- Firmware: `/etc/ws73/ws73.bin`(143956B) + `btc_cali.bin` + `wifi_cali.bin` + `ws73_cfg.ini`

## Symptom (hci0 up always reproduces)

```
[HCC] ble btc open finish
[HCC] ble open time:16
[HCC] hci_bt_setup
[HCC] send tx data failed        <- hci_bt_send_frame -> ble_hci_send_frame -> hcc_bt_tx_data fails
Bluetooth: hci0 sending frame failed (-1)
[HCC] hci_bt_close
```

- `BLE Mac Addr` sometimes reads `1c:4e:a2:aa:**:**` (success), sometimes `00:00:00:00:**:**` (fail)
- `hcc_adapt_bsle_msg_rx_proc` receives `type:2, device_msg:1` (BSLE_MSG_HCC_TYPE_DEVICE_STATUS + BSLE_STATUS_BOOT_FINISH)
- But `hbsle_hcc_customize_get_device_status(BSLE_STATUS_BOOT_FINISH)` times out -> `device boot not finish` -> `[HCC][ERROR]off` -> all TX fails

## Questions (priority order)

1. **device boot state**: when should `bsle_device_msg[device_msg]=true` in
   `hcc_adapt_bsle_msg_rx_proc` fire? After `type:2/device_msg:1` is received,
   why does `get_device_status(1)` still time out? Is the host driver's
   `device_msg` field offset wrong, or does the device firmware not send the
   correct BOOT_FINISH?
2. **hci_bt_setup empty implementation**: SDK `ble_host_hcc.c` has
   `hci_bt_setup` returning `EXT_ERR_SUCCESS` directly; bluez then sends
   `HCI_OP_READ_LOCAL_VERSION` -> TX fails. Correct fix: wait for device boot
   in setup, or return an error so bluez retries?
3. **root cause of hcc_state=OFF**: who sets `hcc_state` to `HCC_OFF`?
   When does `hcc_switch_status(HCC_BUS_FORBID)` in `plat_main.c`/`plat_pm.c`
   trigger?
4. **USB state `WORK --> OFF`**: after `hci0 up` the USB drops from WORK to
   OFF (`usb_set_bus_state`). Is it `pm_ble_disable` or an exception path?
   What is the correct sequence?
5. **mv310 target build**: if there is a WS73 BLE success case on
   Hi3798MV310 or similar armhf 4.4, please provide:
   - correct `ble_soc.ko` build flags (Kconfig/config)
   - any 4.4 adaptation patches for `hci_bt_setup` or `hcc`
   - whether `ws73_cfg.ini` needs specific config (e.g. `[HOST_WIFI_NORMAL]`)

## Repro (on-site)

- SSH: 10.42.0.81:6440 (box2_key)
- dufs: http://10.42.0.1:9099/ws73/ (plat_soc.ko / ble_soc.ko / firmware)
- Repro: `insmod plat_soc.ko; insmod ble_soc.ko; hciconfig hci0 up`
