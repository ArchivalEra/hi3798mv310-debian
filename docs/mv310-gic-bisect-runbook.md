# hi3798mv310 GIC interrupt bisect runbook

> State: 2026-08-19. Working tree: `/mnt/hdd/hi3798mv310-stuff/`.
> Read this before touching the box. Patches live in `../patches/`.

## TL;DR

Everything in the GIC configuration that was ever called "wrong" turns
out to be correct.  The failure is in interrupt *delivery*: no GIC
interrupt ever reaches any CPU's exception handler (not even a self
SGI), while the same SoC family (mv300) delivers SGIs, arch-timer PPIs
and IPIs with an unmodified mainline kernel and the same TF-A platform.

So stop changing the GIC configuration.  Keep the two EnableGrp1 /
IGROUPR belt-and-braces writes (harmless, already validated), then
bisect the delivery path.  The scripts below do exactly that from the
initramfs with devmem, no kernel rebuilds.

## Why the previous two "root causes" are retracted

Two runtime readings drove all the recent fix attempts.  Both were
read from the wrong place.

1.  `ISENABLER0 == 0x0` -> "SGIs are never enabled".

    The reading was taken at `0xf1001104`, which is GICD_ISENABLER1
    (SPI 32-63).  `gic_dist_config()` disables every SPI before
    enabling them by request, so reading 0x0 there is expected and
    irrelevant.

    The real GICD_ISENABLER0 is at dist + 0x100 = `0xf1001100`, and
    mainline `gic_cpu_config()` writes it with `GICD_INT_EN_SET_SGI`
    (0xffff) on every CPU at `gic_cpu_init()` time.  SGIs are enabled.
    Never read 0xf1001104 again while debugging this.

2.  `GICD_CTLR == 0x1` -> "the kernel cleared EnableGrp1".

    In the non-secure banking of GICD_CTLR, bit 0 is the alias of
    EnableGrp1(NS) and bit 1 reads as 0.  So `0x1` is the *good* state;
    the distributor is forwarding Group 1.  The kernel did not clear
    anything.

There is also an unexploited data point already in the logs: the
devmem initramfs boot prints `MV310-GICMAP` (from `gic_cpu_init()`) but
zero `MV310-IRQ` lines, even though the interrupt path is fully
initialized.  That alone proves the failure sits between "GIC signals
the CPU" and "the exception vector runs".

## The remaining suspects (in bisect order)

1.  GICD_ISENABLER0 is actually 0 -> SGIs/PPIs disabled at the
    distributor.  (Almost certainly not, per above, but verify once.)
2.  IGROUPR0 NS view is not `0xfe00ffff` -> SGIs or timer PPIs in
    Group 0 (secure -> FIQ).
3.  GICC_CTLR from the CPU's own view: bit 0 AND bit 1 clear / set
    differently than expected.
4.  GICC_PMR (0xf1002004) == 0xff -> priority mask blocks everything.
5.  The software-pended GICD_SPENDSGIR bit never becomes visible in
    GICC_HPPIR or in gic_handle_irq -> distributor -> CPU interface
    routing broken (secure bank, GICD_CTLR 1S/1NS, SCR_EL3).
6.  SCR_EL3 at BL31 handoff has IRQ/FIQ/EA set (bit 1/2/3) -> all
    interrupts trap to EL3; the kernel never sees them.

## The two patches (in ../patches/)

- `0001-irqchip-gic-hi3798mv310-grp1-and-state-dump.patch` (kernel,
  drivers/irqchip/irq-gic.c)
  - keeps GICC_CTLR.EnableGrp1 (bit 1),
  - writes GICD_IGROUPR0 = 0xffffffff (SGIs/PPIs -> Group 1),
  - writes GICD_CTLR bit 1 (EnableGrp1 under either banking),
  - adds a one-shot per-CPU dump in gic_cpu_init(): MV310-GIC[n] with
    GICD_CTLR/TYPER/IGROUPR0/ISENABLER0/ICFGR1/GICC_CTLR/GICC_PMR, with
    the offsets spelled out in the message so a log cannot be misread
    again.  The dump runs on CPU0 at boot and on each CPU as it comes
    up, before any interrupt can fire.
- `0002-atf-hi3798mv2x-grp1-and-scr_el3-dump.patch` (TF-A)
  - gicv2_distif_init(): also set GICD_CTLR.EnableGrp1 (bit 1) from
    EL3,
  - bl31_platform_setup(): print SCR_EL3 (bits [3:0]: EA/FIQ/IRQ/NS,
    bit 10: RW).  IRQ/FIQ/EA must read 0.

## Build + deploy (zero-write RAM boot, unchanged)

```
# kernel (worktree, keeps the messy working tree untouched)
git -C /mnt/hdd/hi3798mv310-stuff/kernel/linux-718 worktree add /tmp/mv310-verify HEAD
cp /mnt/hdd/hi3798mv310-stuff/kernel/linux-718/.config /tmp/mv310-verify/.config
cd /tmp/mv310-verify && git apply ../patches/0001-*.patch   # or copy the file
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 Image -j8
# sanity (see kconfig trap below):
grep -E 'CONFIG_SERIAL_AMBA_PL011|CONFIG_CMDLINE=' .config

# atf
cd /mnt/hdd/hi3798mv310-stuff/bootloader/atf
git apply ../patches/0002-*.patch     # or apply by hand
make PLAT=hi3798mv2x SPD=none POPLAR_RECOVERY=1 CROSS_COMPILE=aarch64-linux-gnu- bl31
# rebuild l-loader with the new bl31.bin, then:
cp bl31.bin /srv/tftp/...   # see mv310-uboot-port.md / ram-boot-test.md

# boot (unchanged three-piece RAM chain, /srv/tftp names per boot-log)
setenv ipaddr 10.42.0.81
setenv serverip 10.42.0.1
tftp 0x02000000 mv310-l-loader-<new>.bin
tftp 0x0f000000 mv310-tvbox-7.1.8.dtb
tftp 0x10000000 mv310-Image-<new>
go 0x0203F000
# at MV310#:
booti 0x10000000 - 0x0f000000
```

Never `saveenv`, `mmc write`, `mmc erase`.  Physical power-cycle to
reset (U-Boot `reset` once left the box with no serial output).

## Step 0 - read the new one-shot dump

Boot with the two patches applied, `maxcpus=1` in CONFIG_CMDLINE (the
devmem image already has it; keep it for the bisect phase).

Expected on CPU0:

```
MV310-GIC[0]: GICD_CTLR(+0x000)=0x00000001 GICD_TYPER(+0x004)=0x00000080
IGROUPR0(+0x080)=0xfe00ffff ISENABLER0(+0x100)=0x0000ffff
ICFGR1(+0xc04)=0x00000000 GICC_CTLR(+0x000)=0x000003e3 GICC_PMR(+0x004)=0x000000f8
```

plus, from the ATF patch: `MV310: SCR_EL3 = 0x...` with bits 3:0 == 0x5
(NS+RW) and bits 3:1 == 0.

Pass criteria / next steps:

- ISENABLER0 == 0xffff -> SGIs enabled, suspect 1 cleared.
- IGROUPR0 == 0xfe00ffff -> SGIs 0-7 + PPI 16-31 in Group 1, suspect 2
  cleared.
- GICC_CTLR == 0x3e3 -> bits 0+1 set, suspect 3 cleared.
- GICC_PMR == 0xf8 -> priority ok, suspect 4 cleared.
- SCR_EL3 bits 3:1 == 0 -> suspect 6 cleared (else: fix the ATF EL3
  exception routing, this is the root cause).
- `MV310-IRQ: cpu=0 irq=N` line *ever* appears (it did not in previous
  boots) -> delivery works, and the SMP deadlock should be gone with
  maxcpus=4.

If all pass and still zero interrupts, proceed to Step 1.  Record every
line verbatim in the notebook.

## Step 1 - software-pend SGIs from the initramfs (no rebuilds)

Initramfs script: `../scripts/mv310-gic-bisect.sh` (copy into the
devmem initramfs root, or run the equivalent devmem lines by hand on a
console that works).  Assumes the devmem image: maxcpus=1,
CONFIG_STRICT_DEVMEM off, devmem busybox applet in the initramfs.

The script:

1.  Reads GICD_ISENABLER0, IGROUPR0, GICC_CTLR, GICC_PMR (correct
    offsets), prints them.
2.  Self-pends SGI 8 (write GICD_SPENDSGIR = 0x100, target self) and
    waits 2 s.
3.  Reads GICC_HPPIR (0xf1002018).  0x3ff = nothing pended, the SGI did
    not reach the CPU interface.  ID 8 pending = the GICD->GICC path
    works and the failure is after the CPU interface (vectors / DAIF /
    SCR_EL3).
4.  Clears the pending SGI (GICD_CPENDSGIR = 0x100).

Interpretation:

- HPPIR shows ID 8 after the pend, and the kernel's own SGI (IRQ 0
  reschedule) also never fired -> trap-level issue; SCR_EL3 dump from
  Step 0 is the answer.
- HPPIR stays 0x3ff -> the distributor never forwarded a software
  interrupt to the CPU interface at all.  The fault is in the
  GICD_CTLR / IGROUPR0 / ISENABLER0 bank the kernel sees, or in the
  secure bank on top of it.  Compare with the U-Boot cold-boot values
  (GICD_CTLR=0x3 after the ATF patch, IGROUPR0=0xfe00ffff) and diff
  kernel-runtime vs U-Boot.
- SGI 8 *does* get handled (IRQ line in serial) -> the entire GIC path
  works and the SMP deadlock should not reproduce; re-test with
  maxcpus=4 and a clean image.

Do not use the old 0xf1001104 address for anything.  Do not read
GICC_* registers from the distributor base (0xf1001xxx) or vice versa:
GICC lives at 0xf1002000 and is banked per CPU.

## Step 2 - if the SGI never reaches HPPIR

At the U-Boot prompt (before `booti`), compare cold-boot values against
the Step 0 kernel-runtime values:

```
md.l 0xf1001000 1    # GICD_CTLR
md.l 0xf1001080 1    # IGROUPR0
md.l 0xf1001100 1    # ISENABLER0 (real one!)
md.l 0xf1002000 1    # GICC_CTLR (cold, CPU0 secure bank)
md.l 0xf1002004 1    # GICC_PMR
```

Then boot and compare with Step 0.  A GICD_CTLR that reads 0x1 in the
kernel but 0x3 at U-Boot is the banked-view distinction, not a bug.
The decisive bit is whether the *behavior* (SGI -> HPPIR) differs, not
the register image.

## Step 3 - only if everything above is clean

Try maxcpus=4 with the patched images and check for

```
smp: Brought up 1 node, 4 CPUs
```

and MV310-GIC[1..3] dumps appearing (proves the secondary warm path
runs gic_cpu_init and the banked GIC is per-CPU sane).  If CPU1-3 come
up but later crash, the remaining suspects are IPI routing
(gic_ipi_send_mask targets, GICD_ITARGETSR0) and the arch-timer PPIs,
both still Group 1 per IGROUPR0.

## Toolchain / kconfig traps (from the notebook, still true)

- Always `make ARCH=arm64 olddefconfig </dev/null` after touching
  .config, then grep
  `CONFIG_SERIAL_AMBA_PL011|CONFIG_SERIAL_AMBA_PL011_CONSOLE|CONFIG_CMDLINE=`.
  A kconfig interruption silently drops PL011 and CMDLINE -> boot with
  no console at all, previously misread as a secondary-core problem.
- `CONFIG_CMDLINE_FORCE=y` on this tree: the kernel ignores U-Boot
  bootargs; change CONFIG_CMDLINE to switch maxcpus.
- Kernel built with `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
  LLVM=1 LLVM_IAS=1 Image -j8`.
- "Warning: unable to open an initial console" in the log is a
  side-effect of the CRG clock driver failing to probe (bpll), which
  defers the AMBA PL011; it does not affect the GIC bisect.

## Files

- Patches: `../patches/0001-*.patch`, `../patches/0002-*.patch`
- Bisect script: `../scripts/mv310-gic-bisect.sh`
- Source of truth for registers: `include/linux/irqchip/arm-gic.h`
  (kernel) and `drivers/arm/gic/v2/gicv2_helpers.c` (TF-A).
- Full investigation: `/mnt/hdd/hi3798mv310-stuff/notes/mv310-secondary-investigation-notebook.md`
