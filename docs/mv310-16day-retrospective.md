# Hi3798MV310 aarch64 bring-up -- 16-day retrospective (why we stopped)

> From `smp: Bringing up secondary CPUs` going silent, to the `H` heartbeat
> revealing the truth, to `xfs.ko` mounting read-only on armhf -- the full arc
> from mainline aarch64 to practical armhf.

Audience: the next person to pick up this board. Also a note to ourselves --
the ones who stared at `0xF1001100` for a week.

The original Chinese manuscript is at `/tmp/blog-mv310-16days.md` (130 lines,
not committed due to the repo's no-CJK policy). This is the English archival
version.

---

## TL;DR

* **16 days**: 7 days of mainline 7.1.8 SMP deadlock triage, 5 days of GIC
  non-delivery root-cause, 4 days of armhf 4.4.35 practical bring-up
  (XFS / USB storage / WiFi).
* **Stuck on**: zero GIC interrupts under mainline (`/proc/interrupts` all
  zero, zero `MV310-IRQ` hits), with console starved by the missing tick
  so the board looks "completely dead".
* **Why stuck**: `GICD_CTLR bit1 write hangs` + non-standard
  `IGROUPR/ISENABLER` semantics on mv310 + `arch_timer PPI30` never fires
  -- three walls at once.
* **How we proved liveness**: HB raw-UART heartbeat + MMIO timer driver
  (SPIs 58/91/59/92) showed CPU/bus/UART are alive; on armhf we fell back
  to the vendor 4.4 chain where XFS/USB just work.
* **Verdict**: **stop chasing aarch64 mainline, close on armhf 4.4.**
  mv300 boots mainline fine with the same TF-A, mv310 does not -- the
  difference is almost certainly a security/firmware gate, not a kernel bug.
  Further return on investment is negative.

---

## 1. Timeline

| Phase | Dates | What happened | Artifact |
|---|---|---|---|
| Day 0 | 08-16 | Secondary bring-up baseline | `STATUS.md` |
| Day 1-2 | 08-17/18 | RAM boot chain + console fixes + VA39 + manual CPU_ON | `deploy/images/MANIFEST.txt` |
| Day 3 | 08-19 | SGI verdict + `GICD_CTLR bit1` hang + v2 revert to initramfs | `docs/mv310-board-handoff.md` Addendum 1-4 |
| Day 4 | 08-20 | HB heartbeat, dual-fault model | `notes/experiment-report/day4.md` |
| Day 5-6 | 08-21/22 | `timer-mv310.c` + `poll clockevent` triple starvation + CNTPCT discriminator | `day5.md` / `day6-7.md` |
| Finale | 08-25/28 | Vendor 4.4.35 practical: XFS/USB, `CONFIG_TUN=n` clarified, BBR/FQ assessed | this doc |

---

## 2. Day 1-2 -- getting the board to boot (and three traps)

**Day 1**: froze the zero-write RAM boot chain
`fastboot -> l-loader -> TF-A BL31 -> U-Boot -> booti`. Permanent archival
by `name-md5`. Also introduced the **silent kconfig pollution** -- non-interactive
`kconfig` prompt failures silently cleared `CONFIG_SERIAL_AMBA_PL011` and
`CONFIG_CMDLINE` after 16:43, half a day lost to "probe pollution".

**Day 2**: VA39 image invalidated by the pollution above; manual
`mw 0xf8a22048/50` proved **RVBAR/CPU reset hardware is healthy**;
`maxcpus=1` proved single-core reaches `init`; both hotplug and SMP reach
`cpu_online=1` yet stall after `wait_for_ap_thread` -- **stall converges on
interrupt/scheduling path**.

**Vendor control** was the turning point: the same board booting the eMMC
32-bit `4.4.35_hi3798mv310` brings up all four cores with `hisp804`
clockevents 0-3 ticking, proving **GIC hardware is 100% healthy**.

Traps: earlycon-only console (Day 1), `CONFIG_CMDLINE_FORCE=y` making
`setenv bootargs` a no-op (Day 2), `olddefconfig </dev/null + grep` becomes
mandatory.

## 3. Day 3 -- zero delivery and two retracted root causes

Core verdict: **`MV310-IRQ` probes: zero hits on any CPU, all boot**.

Two retracted root causes the same day:

1. **ISENABLER0 misread**: `0xF1001104` (ISENABLER1) read as `0x1100`, fake
   "SGI not enabled".
2. **GICC/HPPIR semantics misread**: `GICC_BPR` read as `HPPIR`, fake
   "interrupt reached CPU interface".

The real killer was **`GICD_CTLR bit1 write hangs`** -- `v1 Image 9673d8f5`
writing `0x3` made the boot die in `time_init`; revert to `0x1`
(`v2 e35b730b`) was the first build that reached `Run /init`. Both retractions
rewrote the problem from "misconfigured" to **"not delivered"**.

## 4. Day 4 -- the instrument wakes up: the CPU is alive

**Minimal isolation** (`R-BEFORE/AFTER` brackets) pinned death to a single
instruction: `devmem 0xF1001100` returns `0x4A00FFFF`, the next `echo AFTER`
never prints. But this is **console death**, not CPU death.

**HB raw-UART heartbeat** was the hardest instrument of the whole
investigation:

* `v7.2` (busy-wait heartbeat) streams `H` for 20k+ beats with zero `M`
  markers -- **CPU/bus/UART alive, printk->console path dead**.
* `v7.3` `CONSOLE-PROBE` triple markers (`B + pr_info + D`) all land --
  `printk` lock not dead, **user kmsg flush starved by the scheduler**.
* Chain: flush needs scheduler -> scheduler needs tick -> tick needs
  PPI30 -> **PPI30 never fires**. Dual faults collapse to one root cause.

## 5. Day 5-6 -- MMIO timer ready, blocked by the same wall

`drivers/clocksource/timer-mv310.c` registers four per-CPU clockevents
(SPIs 58/91/59/92) with `request_irq` succeeding, yet counts stay zero;
even `S-view GICC_CTLR 0x1e9 -> 0x1eb` leaves `hppir=0x3ff` -- **nine
reachable knobs all green, forwarding still dead**.

`poll clockevent` triple starvation is a textbook case: serial init
starves itself without a tick; `v10.3` retry machinery runs a full 5 s
window with `jiffies` frozen; `v10.4` discriminator: **`CNTPCT advances
while jiffies frozen -- counter alive, only the IRQ never comes`**.

BBR3/FQ was assessed in parallel: no `tcp_bbr.c` on 4.4.35 and
`CONFIG_NET_SCHED=n`, `higmac` only has `TSO/GRO/LRO` -- congestion
control is not a board-side fix.

## 6. Day 7-16 -- falling back to armhf 4.4 and making the box useful

Back on the vendor chain, the goal shifts from "fix the tick" to
"make this box useful":

* **060 SDK check**: `hi3798mv310_defconfig` vs `hi3798mv300_defconfig`
  differ only in `ARCH`/`LOCALVERSION`; `CONFIG_XFS_FS=m` /
  `CONFIG_USB_STORAGE=y` (built-in) / `CONFIG_TUN=n` (intentionally off)
  match the running kernel; `UTS_RELEASE 4.4.35_hi3798mv310` aligns with
  `arm-histbv320-linux`, `xfs.ko 1.2M` builds cleanly on the host.
* **XFS USB live test**: `fs/xfs/xfs.ko` built on the host, shipped via
  `dufs`, validated on the board (mount path in progress); BBR3/FQ
  confirmed not modular on 4.4, kernel rebuild not worth it.
* **WS73 NearLink 4.4 armhf** ready per handoff: 4-module order
  `plat->ble->sle->wifi`, `WSCFG_BUS_USB=y` + `arm-linux-gnueabihf-` +
  kernel dir pointing at the 060 build, `wait-for-idle 1.0` + `make -j1` +
  `ccache 10G` discipline aligned.

---

## 7. Why we stopped -- five hard reasons

> Not "out of ideas", but "another week won't open this door".

1. **Three independent paths fail the same way**: arch_timer PPI30 never
   fires, MMIO timer SPI 58 count never increments, soft-pended `HPPIR/RPR`
   stays dead -- three paths point at a **firmware/hardware gate on
   Group1 forwarding**, not a single bug.
2. **Nine knobs all green, still dead**: NS/S `GICD_CTLR`, `IGROUPR` all
   banks, `ISENABLER/ISPENDR`, `GICC_CTLR/PMR/RPR` all verified -- **reachable
   software configuration space is exhausted**.
3. **Reference board counter-proof** is strongest:
   `hataketsu/hi3798mv300-mainline` boots 7.2-rc5 on sibling MV300 with the
   **same TF-A** (GIC+PPI30 alive) -- not an upstream bug, almost certainly
   a **per-SoC factory security strapping** difference.
4. **Deliverables done**: `timer-mv310.c`, HB heartbeat, `probe-registry`
   retirement discipline, `cbuild` scripts, 8 experiment reports + 10
   falsified + 12 confirmed hypotheses -- all reusable assets.
5. **ROI inflection**: next steps are `fuse dump / EL3 private register
   archaeology / Group0 FIQ handler` -- a week for one errata line, while
   armhf 4.4 already meets the real "useful box" need.

---

## 8. Checklist for the next person

| Want to | Read | One-liner |
|---|---|---|
| Reproduce non-delivery | `docs/mv310-board-handoff.md` section 6 + Addendum 7-14 | Run v4 `R-BEFORE/AFTER`, then HB heartbeat; do not trust `sleep` |
| Read registers | `docs/mv310-gic-errata.md` / `mv310-probe-registry.md` | `0x1100` is ISENABLER0, `0x2018` is HPPIR, `GICC` at `0x2000` bank |
| Boot the board | `scripts/fb-run.py` + `serial-proxy.py` | Zero-write eMMC, `go 0x0203F000 -> booti`, archive by `name-md5` |
| Build XFS/USB | `notes/experiment-report/day6-7.md` Record 4 | `arm-histbv320-linux` + `UTS_RELEASE 4.4.35_hi3798mv310` |
| Build WS73 NearLink | `/tmp/plan-ws73-armhf44.md` (this session; copy to `docs/` if kept) | `plat->ble->sle->wifi`, `WSCFG_BUS_USB=y`, `-j1` + `wait-for-idle` |
| Keep digging aarch64 | `notes/experiment-report/hypothesis-matrix.md` U1-U4 | Remaining ports: `CNTHCTL.PL1PCEN` / `interrupt_props` / `fuse` |

> Rule: **prove the CPU is alive before talking about interrupts.** Without
> the `H` heartbeat, every "hang" may just be console starvation.

---

## 9. Acknowledgements and archive

* The serial line does not lie: after the `H` heartbeat, every "hang" got a
  second opinion.
* The probe does not lie: the moment `MV310-IRQ` stayed at zero, the
  investigation truly began.
* The archive does not lie: every Image has an `md5`, every claim has a
  `serial-*.log` -- the next person can re-judge.

Archive:

* This blog (English archival): `docs/mv310-16day-retrospective.md` (this file)
* Original Chinese manuscript: `/tmp/blog-mv310-16days.md` (130 lines, kept out of git)
* Experiment reports: `notes/experiment-report/day{1-2,3,4,5,6-7}.md` + `hypothesis-matrix.md` + `code-audit.md` (under `/mnt/hdd/hi3798mv310-stuff/`, not in this repo)
* Board handoff: `docs/mv310-board-handoff.md` (Addendum 1-17)
* Probe discipline: `docs/mv310-probe-registry.md` (v9 retired)

---

*16 days, 8 Image rounds, 25,613 `H`s, one `CNTPCT ADVANCED`. The board did
not become what we wanted, but we finally saw what it really is. -- 2026-08-28*
