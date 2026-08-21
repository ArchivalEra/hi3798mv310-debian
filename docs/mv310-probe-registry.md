# MV310 probe registry and maintenance rules

> Authoritative inventory of every `MV310-*` probe in the kernel and ATF
> trees, plus the lifecycle rules that keep the probe zoo manageable.
> This investigation has burned real time on probe proliferation
> (`MV310-HP` once spammed a boot log with dozens of lines, `MV310-IRQ`
> was renamed to `MV310-IRQ-IAR`, `GICMAP` went through three formats) —
> these rules are the remedy.  Audit both trees before every rebuild;
> every probe must have a registry row.

---

## 1. Probe lifecycle (birth → retirement)

- **Birth**: add a registry row first (§2), get a unique ID, then write code.
- **Live**: semantics are frozen for the lifetime of the ID.  Changing the
  output format or the meaning is a NEW probe: give it a new ID, retire the
  old one (with a one-line changelog entry pointing at the new ID).
- **Retirement**: the moment the probe's "retire when" condition is met, it
  is deleted from source, one line goes in the changelog, and the registry
  row is marked `RETIRED`.  Only `SENTINEL` probes stay for the whole
  investigation.
- **Forbidden**: renaming in place (rename = new ID), probes without a
  registry row, two probes for the same semantic question, silent format
  changes.

## 2. The registry

Fields: `ID | location | fires | reading (what it proves) | status | retire when`.

### Kernel side (EL1) — `drivers/irqchip/irq-gic.c`

| ID | Location | Fires | Reading | Status | Retire when |
|---|---|---|---|---|---|
| `MV310-IRQ-ENTER` | gic_handle_irq, true first stmt, **before** IAR read | every IRQ | printed = interrupt reached the handler alive; 0 hits = never pended, or intercepted earlier than the handler | ACTIVE | SMP brings up, or H-VEC adjudicated |
| `MV310-IRQ-IAR` | gic_handle_irq, after IAR read | every IRQ | ENTER printed, IAR not = dies in the IAR read | ACTIVE | same as above |
| `MV310-GICMAP-EARLY` | gic_cpu_init entry | once per CPU | `cpu=N` = that CPU entered gic_cpu_init; per-CPU banked gicc_ctlr/pmr snapshot | ACTIVE | merged into GICMAP, or CPU1 death adjudicated |
| `MV310-GICMAP` | gic_cpu_init tail | once per CPU | isenabler0 read from EL1 (the ONLY sanctioned read of 0xF1001100); cpu_map sanity | ACTIVE | SMP brings up |
| `MV310-SYSREG` | gic_cpu_init tail | once per CPU | VBAR_EL1 / DAIF / CurrentEL / SCTLR_EL1 / MPIDR snapshot | ACTIVE (one-shot, cheap) | vector routing adjudicated |
| `MV310-EL1-ENTER` | `arch/arm64/kernel/entry-common.c:el1_interrupt` entry, `noinstr` | every EL1 IRQ/FIQ (raw UART 'E') | printed = interrupt reached EL1 vector alive; HB alive but no E => vector never entered; E printed + no IRQ-ENTER => wedge between vector and gic_handle_irq | ACTIVE | H-VEC adjudicated |

### ATF side (EL3)

| ID | Location | Fires | Reading | Status | Retire when |
|---|---|---|---|---|---|
| `MV310-BL31-GICD` | gicv2_distif_init tail | once per cold boot | S-view GICD_CTLR (`ctlr=0x3` = G0\|G1 open). Sentinel for the S-view state | SENTINEL | end of investigation |
| `MV310-CPUON-entry` / `MV310-CPUON-unlocked` | lib/psci/psci_on.c | once per CPU_ON | entry + unlocked only (trimmed 6->2 in v6c) | ACTIVE | CPU_ON path adjudicated |
| `MV310-GIC-on_finish` / `-on_finish-after` | plat/hisilicon/hi3798mv2x/plat_pm.c | once per secondary power-up | `after` printed = TF-A's banked writes on the secondary completed ⇒ wedge is in the kernel sequence; absent ⇒ wedge inside TF-A's gicv2_pcpu_distif_init | ACTIVE (this is the §8.4 E1.4 discriminator) | CPU1 death adjudicated |

### Retired

| ID | Why it existed | Retire note |
|---|---|---|
| `MV310-MAIN` / `MV310-HP` | hotplug-thread state on CPU0 (031546 era) | conclusion reached; removed from source; lives only in old logs |
| `MV310-IRQ` (old name) | after-IAR hit counter | renamed to `MV310-IRQ-IAR` (the old name would collide with the pre-IAR probe) |

### EL0-forbidden MMIO (never in an init script / devmem)

**Rule (v6c, 2026-08-20): ALL EL0 GIC MMIO is forbidden — reads and
writes, GICD and GICC alike. No offset is certified safe.**

The offset-specific model is falsified by the v6 series: on one kernel
lineage, five consecutive boots each died at the SECOND EL0 GIC read of
the boot, across five different registers — 0x1C00 (v5b), 0x1080 (v6),
0x1104 (v6b), 0x2000 (v6c ×2) — and in every case the read's VALUE
printed and the next script line never did (the read transaction itself
always completes; something dies at the following output). 0x1080,
0x1104 and 0x2000 had all previously SURVIVED EL0 reads in v3/v4/031546
scripts, so whether an access kills depends on script position/timing,
not the offset. Best-fit model so far: the first EL0 GIC access arms an
async poison that kills the CPU or the console ~15-30 ms later (v3 died
29 ms after its first access, v4 at 28 ms, v5b/v6/v6b/v6c at 16-17 ms);
only a heartbeat can adjudicate CPU-dead vs console-dead.

Historical per-offset death sites (log archaeology only; the offset is
NOT the cause):

| Offset | Register | Fatal in | Survived EL0 reads in |
|---|---|---|---|
| `0xF1001100` | ISENABLER0 | v3, v4 | — (EL1: every boot, GICMAP) |
| `0xF1001080` | IGROUPR0 | v6 | v3, v4, 031546 (EL1: every boot, GICMAP) |
| `0xF1001104` | ISENABLER1 | v6b | 031546 |
| `0xF1001C00` | ICFGR0 | v5b | — |
| `0xF1002000` | GICC_CTLR | v6c ×2 — CONFIRMED (serial-v6c-1445.log last boot AND serial-v6c-1457.log last boot; the earlier "needs second run" was satisfied by re-reading the cumulative capture) | v3, 031546 |
| `0xF1001300` | ISACTIVER0 | v3 (retracted reading, still off-limits) | — |

0xF1001000 as the boot's FIRST EL0 GIC read has survived in every run
so far — that is position luck, not safety. EL0 and EL1 access to the
SAME offset are NOT equivalent — never cross-apply a safety conclusion.

Log-file note: serial-v6-1417 / v6b-1430 / v6c-1445 / v6c-1457 are
cumulative snapshots of one capture (1417 ⊂ 1430 ⊂ 1445 ⊂ 1457; each
later file contains all earlier boots plus one new boot). Cite the boot
index within the file, not just the filename. Script banners lagged the
script version (v6b/v6c still print "V6 START") — identify by the L1
header comment, and bump the banner string in v7.

---


### Retired in v9 (2026-08-21 probe cleanup)

| ID | Retire note |
|---|---|
| `MV310-HB` / raw-UART heartbeat | mission complete: proved CPU-alive vs console-dead (v7.2); msleep/timer dependency found; removed from irq-gic.c |
| `MV310-SGIR` (/proc/mv310_sgir) | adjudicated H-GATE-SGI: spend=0 reproduced with full config; removed |
| `MV310-PEND` SPI pend probe | decisive: hppir=0x3ff with all knobs correct -> hardware forward path dead; removed |
| `MV310-CONSOLE-PROBE` | printk healthy in FIFO context -> flush starvation confirmed; removed |
| `/proc/mv310_timer_ctrl` debug proc | bench-only; removed from timer driver |
| `MV310-CPUON-*`, `MV310-GIC-on_finish*`, `MV310-BL31-HCR` | CPU_ON path and EL2 routing no longer suspects; removed from ATF |
| initramfs ladder scripts (M1-M50, Z-DONE, C-challenge) | replaced by clean boot script with sleep canary |

Kept: `MV310-TIMER` registration print (driver one-shot), `MV310-BL31-GICD`
SENTINEL. Kernel irq-gic.c now carries ZERO probes - only the two mv310
fixes (GICC EnableGrp1 + IGROUPR SPI banks).

---

## 3. Maintenance rules (the 15 laws)

Naming and identity
1. Prefix everything `MV310-`; one semantic per ID; the message must contain
   the register offset(s) in the text so a log cannot be misread.
2. Renaming = new probe (retire the old ID, changelog line, new row).
3. No code without a registry row.  The registry is the review checklist.

Rate and shape
4. High-frequency probes (per-IRQ, per-CPU_ON) MUST be rate-limited or
   counter-based.  Bare per-event prints are forbidden (lesson: MV310-HP).
5. One line per semantic question — pack several fields into one printk
   (see GICMAP), never one field per printk.
6. Put the expected value in the message ("expect 0x3: G0|G1") so the log
   is self-interpreting without a memory aid.

Safety
7. The EL0-forbidden list above is absolute for initramfs/devmem scripts.
8. Never add extra IAR/register reads inside gic_handle_irq (breaks ACK);
   probes there read only parameters already in hand.
9. A probe must not change the measured behavior: no locks, no sleep, no
   added MMIO beyond the read it reports.

Lifecycle
10. Every probe has a "retire when"; when it fires, delete the probe.
11. Retirement = source deletion + changelog line + registry `RETIRED`.
12. Before deploying a three-piece set: grep-count probes per tree and
    compare against the registry — no orphans, no unregistered probes.

Docs and traceability
13. Changing a format = new version suffix (`MV310-X-V2`); old logs must
    stay readable against old names.
14. Every bench log lands in `notes/logs/` named with the probe-set
    identifier (e.g. `serial-v5-icfgr0-123155.log`).
15. Each registry row records WHERE the output is expected in the boot
    (which phase, which CPU) — when the line is missing you know whether the
    probe never ran or the system never got there.

---

## 4. Open actions (before the next build) — done in v7

1. **DONE — Trim `MV310-CPUON-*` 6→2** (keep `entry` + `unlocked` only; v6b/c build).
2. **DONE — Register the new E1 probes**: `HB`, `MV310-SGIR`, `GICCPU-STEP [CI-1..CI-7]` (see New in v7 above).
3. **Freeze the GICMAP format**: it is the EL1-sanctioned ISENABLER0 reader
   and the §6 checklist reference; no more format drift.

### New in v7

| ID | Location | Fires | Reading | Status | Retire when |
|---|---|---|---|---|---|
| `MV310-HB` (HB) | raw UART kthread, `drivers/irqchip/irq-gic.c` kthread | every ~50 ms from late_initcall until driver unbind | `HB n=N` line = CPU alive and UART path alive. HB keeps printing but printk stalls => T2 console-dead. HB stops => CPU-dead / wedged. Not a printk, so it covers the case where printk/console itself is the victim (law 12). | ACTIVE | H-VEC vs T2 adjudicated, then down-rate or remove |
| `MV310-SGIR` | `/proc/mv310_sgir` write handler, `drivers/irqchip/irq-gic.c` | on demand (one `echo 8 > /proc/mv310_sgir` per boot) | header `S-view GICD_CTLR snapshot` before the write; `BEFORE`/`AFTER` SPENDSGIR0 + HPPIR + `MV310-IRQ-ENTER/-IAR` line counts after. BEFORE/AFTER spend bit8=1 + hppir=0x3FF + 0 ENTER => H-GATE (SGI) confirmed; ENTER+IAR printed => delivery + vector + ACK all OK (then H-SRC). | ACTIVE | H-GATE-SGI adjudicated |
| `GICCPU-STEP [CI-1..CI-7]` | `gic_cpu_init()` step markers, `drivers/irqchip/irq-gic.c` | once per CPU (boot CPU + each secondary entering gic_cpu_init) | `CI-N` printed = code reached that group boundary. Last CI seen names the wedge window (e.g. CI-5 printed but CI-6 missing => wedge between CI-5 and CI-6). Carried into the v7 build so the next maxcpus=4 boot costs zero extra. | ACTIVE | CPU1 death window adjudicated |

## 5. Relationship to the three-piece deployment

Each deployment = Image / l-loader / dtb md5s + a probe-set version
(string, e.g. `probes-v6-e1`), bound in the changelog.  Log filenames carry
the probe-set tag; the registry is the single source of truth for what any
log's `MV310-*` lines mean.
