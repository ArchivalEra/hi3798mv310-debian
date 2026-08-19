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
