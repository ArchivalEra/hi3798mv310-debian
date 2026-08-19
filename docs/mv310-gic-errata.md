# Errata: two retracted GIC findings (read this before the notebook)

Date: 2026-08-19. Source: independent audit of
`/mnt/hdd/hi3798mv310-stuff/notes/mv310-smp-root-cause-report.md` and
`mv310-expert-handoff.md` against the code and the devmem log
`notes/logs/serial-devmem-031546.log`.

Two runtime GIC readings that drove the recent fix attempts were taken
from the wrong register offsets.  Both are banked-view / offset
misreads, not hardware anomalies.

## 1. "ISENABLER0 == 0x0 -> SGIs never enabled" (retracted)

The reading was taken at `0xf1001104`:

```
GICD_ISENABLER0 (0xF1001104) = 0x00000000
```

`0xf1001104` is **GICD_ISENABLER1** (SPI 32-63).  Mainline
`gic_dist_config()` disables every SPI before enabling them by request,
so this register reads 0 during early boot.  That is normal.

The real **GICD_ISENABLER0 is at dist + 0x100 = `0xf1001100`**, and
mainline `gic_cpu_config()` writes it with `GICD_INT_EN_SET_SGI`
(0xffff) on every CPU at `gic_cpu_init()` time (see
`drivers/irqchip/irq-gic.c`).  SGIs are enabled.  The "SGI never
enabled -> IPI never pends" theory is void; the GICD_SPENDSGIR/CPENDSGIR
test in the bisect script (Step 1 of the runbook) measures the real
thing directly.

## 2. "GICD_CTLR == 0x1 -> kernel cleared EnableGrp1" (retracted)

```
GICD_CTLR (0xF1001000) = 0x00000001
```

In the **non-secure** banking of GICD_CTLR, bit 0 is the alias of
EnableGrp1(NS) and bit 1 (the EnableGrp1 field of the secure view)
reads as 0.  So `0x1` is the *good* state: the distributor is
forwarding Group 1.  The kernel's `writel(GICD_DISABLE)` /
`writel(GICD_ENABLE)` sequence in `gic_dist_init()` did not clear
anything that matters.

## What is still true

- The symptom: no GIC interrupt ever reaches any CPU's handler (the
  devmem boot logs zero `MV310-IRQ` lines, even for CPU0, and a self
  SGI is not handled).
- IGROUPR0 NS view = `0xfe00ffff`: SGIs 0-7 and PPIs 16-31 in Group 1,
  timer PPIs 26/27/29/30 included.  Group assignment is correct.
- The reference board (hi3798mv300) runs four cores, arch-timer PPIs
  and SGIs with the same TF-A platform and an unmodified mainline
  kernel.  The GIC configuration theory cannot explain the failure by
  itself.

So the remaining fault is in interrupt *delivery* between the
distributor and the exception vector: GICD_CTLR banking/forwarding,
the secure-bank state on top of the NS view, SCR_EL3 IRQ/FIQ/EA
trapping, DAIF/VBAR.  The bisect scripts in `scripts/` and the
runbook in `docs/` close these one by one, starting with a software
pending SGI read back through GICC_HPPIR.

---

## UPDATE 2026-08-19 (board bisect): GICD_CTLR bit 1 is a hang trigger

Fresh data from the bench, after deploying patch 0001 (kernel) +
0002 (ATF) v1 and bisecting with the old sgigrp1 l-loader:

- New Image (patch 0001 v1, kernel writes GICD_CTLR = 0x3):
  `MV310-GIC[0]` dump shows **GICD_CTLR = 0x00000003**, then the boot
  hangs in time_init() right after the sched_clock line (t=0.000001),
  no further serial output.
- Same new Image + old sgigrp1 l-loader (BL31 without the
  gicv2_main EnableGrp1 write): **same 0x3, same hang**.  The only
  runtime difference vs the booting devmem baseline (GICD_CTLR=0x1) is
  that bit.
- The devmem baseline (GICD_CTLR=0x1) boots all the way into the
  initramfs.  Note: the devmem image itself already carried the
  GICC_CTLR.EnableGrp1 write (GICC_CTLR=0x3e3) - so GICC bit 1 is
  validated as harmless, GICD bit 1 is validated as fatal.

Conclusion: **mv310's non-secure view of GICD_CTLR accepts bit 1
(non-standard for GIC-400 NS banking, where bit 0 is the EnableGrp1NS
alias) and enabling it wedges the boot.**  This is a hardware
difference of this SoC (or of this GIC-400 integration), not a Linux
bug.

Actions taken (patch v2):
- kernel `gic_dist_init()`: GICD_CTLR write stays the known-good
  `GICD_ENABLE` (0x1); the bit 1 write is removed.  GICC_CTLR bit 1
  and the IGROUPR0 write are kept.
- ATF `gicv2_distif_init()`: EnableGrp1 write removed; only the
  SCR_EL3 print remains in the patch.

Implication for the SMP deadlock: the deadlock is NOT a Group 1
forwarding problem (the GIC was forwarding Group 1 all along at
GICD_CTLR=0x1 in the NS view).  The bisect step that actually matters
next is the SGI-pend / HPPIR test from the initramfs
(`scripts/mv310-gic-bisect.sh`) and the SCR_EL3 read, both on a boot
that reaches the initramfs again.
