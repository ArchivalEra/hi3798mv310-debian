# hi3798mv310 board handoff - what the patches do and where to go next

> Date: 2026-08-19. Take this with you to the bench.
> Repo: `~/plum/zcode-projects/hi3798mv310-debian` (committed as c9881a5).
> Kernel tree: `/mnt/hdd/hi3798mv310-stuff/kernel/linux-718` (HEAD 226573818).
> ATF tree: `/mnt/hdd/hi3798mv310-stuff/bootloader/atf` (HEAD 4bfb412).
> Full investigation: `/mnt/hdd/hi3798mv310-stuff/notes/mv310-secondary-investigation-notebook.md`.

## 1. One-paragraph status

The mv310 deadlocks in SMP bringup because no GIC interrupt ever
reaches any CPU (zero `MV310-IRQ` lines even for CPU0, not even a self
SGI).  The two "root causes" that drove the previous fix attempts were
both register misreads (see section 5).  The GIC *configuration* looks
correct; the fault is in interrupt *delivery*.  The reference board
(mv300, same TF-A platform, unmodified mainline kernel) delivers SGIs,
arch-timer PPIs and IPIs fine, so this is not a "fix the GIC config"
problem - it is a "find where the delivery path breaks" problem.

## 2. The three-piece boot set (deployed, zero-write RAM boot)

| File | md5 | Role |
|---|---|---|
| `/srv/tftp/mv310-l-loader-gicgrp1.bin` | `f8cf9a38` | l-loader + BL31 with patch 0002 |
| `/srv/tftp/mv310-tvbox-7.1.8.dtb` | `a1cec64c` | unchanged dtb (4-PPI armv8-timer) |
| `/srv/tftp/mv310-Image-7.1.8-gicgrp1` | `9673d8f5` | kernel with patch 0001 (CONFIG_CMDLINE has maxcpus=1) |

Archives in `/mnt/hdd/hi3798mv310-stuff/deploy/images/`:
`Image-7.1.8-gicgrp1-dump-9673d8f5`, `l-loader-mv310-gicgrp1-f8cf9a38.bin`.

Boot sequence:

```
setenv ipaddr 10.42.0.81
setenv serverip 10.42.0.1
tftp 0x02000000 mv310-l-loader-gicgrp1.bin
tftp 0x0f000000 mv310-tvbox-7.1.8.dtb
tftp 0x10000000 mv310-Image-7.1.8-gicgrp1
go 0x0203F000
# at MV310#:
booti 0x10000000 - 0x0f000000
```

Never `saveenv`, `mmc write`, `mmc erase`.  Physical power-cycle to
reset.  Console: `/dev/ttyACM0` via `/home/archivalera/reasonix-work/box2/serial-proxy.py` (TCP 5555 ro / 5556 cmd / 5557 duplex).

## 3. What patch 0001 (kernel, drivers/irqchip/irq-gic.c) does

Every change is marked: FIX = may actually unblock the deadlock,
HARDEN = harmless belt-and-braces, DIAG = instrumentation.

| Change | Location | Type | Note |
|---|---|---|---|
| `GICC_CTLR` also set bit1 (EnableGrp1) | `gic_cpu_if_up()` | **FIX (candidate)** | Already validated: your 8/19 grp1fix image logged `gicc_ctlr=0x3e3` (bit1=1). Kept because it is the only GIC change proven to take effect and is directionally correct. |
| Write `GICD_IGROUPR0 = 0xffffffff` | `gic_dist_init()` | HARDEN | The relevant bits (SGI 0-7, PPI 16-31) already read 1 in the runtime dump; writing 0xffffffff is a no-op on GIC-400. |
| `GICD_CTLR` also set bit1 | `gic_dist_init()` | HARDEN | In the NS banking of GICD_CTLR, bit0 is the EnableGrp1(NS) alias and bit1 reads 0, so this write is for the secure banking only. |
| `MV310-GIC[n]` one-shot per-CPU register dump | `gic_cpu_init()` | **DIAG (the core deliverable)** | Prints GICD_CTLR(+0x000), GICD_TYPER(+0x004), IGROUPR0(+0x080), ISENABLER0(+0x100), ICFGR1(+0xc04), GICC_CTLR(+0x000), GICC_PMR(+0x004) with the offsets spelled out in the message so a log cannot be misread again. Runs on CPU0 at boot and on every secondary as it runs gic_cpu_init. |

## 4. What patch 0002 (TF-A) does

| Change | Location | Type | Note |
|---|---|---|---|
| `GICD_CTLR` set EnableGrp1 (bit1) from EL3 | `gicv2_distif_init()` | HARDEN | From the GIC-400 1S/1NS model, NS Group 1 is gated by EnableGrp1NS (bit0 of the NS view), which the kernel already writes. The secure-side bit1 does not gate NS interrupts, so this is almost certainly a no-op - but it makes the EL3 cold-boot GICD_CTLR read 0x3 at U-Boot, which is a useful reference point. |
| Print `MV310: SCR_EL3 = 0x...` | `bl31_platform_setup()` | **DIAG** | SCR_EL3 bits [3:1] = EA/FIQ/IRQ trap enables. If any is 1, every EL1/EL2 interrupt traps to EL3 and the kernel never sees it - this is the last completely untested suspect for "pending at GIC, never taken". |

## 5. The two retracted findings (read before touching registers)

1.  "ISENABLER0 == 0 -> SGIs never enabled": the read was taken at
    `0xf1001104`, which is **GICD_ISENABLER1 (SPI 32-63)**.  Reading 0
    there is normal (SPIs are disabled then enabled by request).
    The real **ISENABLER0 is at `0xf1001100`**, written 0xffff
    (GICD_INT_EN_SET_SGI) by gic_cpu_config() on every CPU.
2.  "GICD_CTLR == 0x1 -> kernel cleared EnableGrp1": in the NS banking
    of GICD_CTLR, bit0 is the alias of EnableGrp1(NS).  0x1 is the
    *good* state.

Do not read 0xf1001104 again while debugging this.  Do not read GICC
registers from the distributor base (0xf1001xxx) or vice versa; GICC
is at 0xf1002000 and is banked per CPU.

## 6. Judgment criteria on the next boot (the checklist)

Boot, then look for these lines.  Record all verbatim.

```
MV310: SCR_EL3 = 0x...            <- from BL31 (patch 0002)
MV310-GIC[0]: GICD_CTLR(+0x000)=0x00000001 GICD_TYPER(+0x004)=0x00000080
  IGROUPR0(+0x080)=0xfe00ffff ISENABLER0(+0x100)=0x0000ffff
  ICFGR1(+0xc04)=0x00000000 GICC_CTLR(+0x000)=0x000003e3 GICC_PMR(+0x004)=0x000000f8
```

| Field | Expected | If different |
|---|---|---|
| SCR_EL3 bits [3:1] | 0 | != 0: root cause is EL3 exception routing. Fix = clear IRQ/FIQ/EA in BL31's SCR_EL3 setup (platform EL3 exception config), then re-test. |
| IGROUPR0 | 0xfe00ffff | SGIs 0-7 or PPIs in Group 0 -> those interrupts go FIQ; verify with a software pend. |
| ISENABLER0 (0xf1001100!) | 0xffff | any SGI/PPI disabled -> distributor never signals them; this is then the root cause (see H1/H2 below). |
| GICC_CTLR | 0x3e3 | bit0 or bit1 clear -> CPU interface gating. |
| GICC_PMR | 0xf8 | 0xff would mask everything. |
| MV310-IRQ lines | any | previously zero for the whole boot; any occurrence means the delivery path works and SMP should follow. |

## 7. New hypotheses surfaced by the code audit (verify with the dump)

**H1 - BL31 cold boot disables all SGIs/PPIs.**
`gicv2_secure_ppi_sgi_setup_props()` starts with
`gicd_write_icenabler(gicd_base, 0, ~0U)` (disable SGI 0-31 and PPI
16-31) and then enables only the *secure* mask.  Linux re-enables SGIs
on every CPU at gic_cpu_init(), and PPIs on request, so on CPU0 the
net effect should be 0xffff - *if* the kernel's enable writes stick.
The new dump prints ISENABLER0 from the real offset, so this is now
directly observable instead of guessable.

**H2 - BL31 secondary on_finish re-runs the disable.**
`poplar_pwr_domain_on_finish()` calls `poplar_gic_pcpu_init()` ->
`gicv2_pcpu_distif_init()` -> the same `gicd_write_icenabler(0, ~0)`
disables all SGIs/PPIs on the secondary just before Linux secondary
startup.  Linux re-enables SGIs in the secondary's gic_cpu_init(), but
any PPI whose enable happens earlier (tick setup ordering) could be
left disabled on CPU1-3.

**How to test both with one boot:** enable maxcpus=4 (edit
CONFIG_CMDLINE, rebuild) and compare the dumps:

```
MV310-GIC[0]: ... ISENABLER0(+0x100)=0x0000ffff ...
MV310-GIC[1]: ... ISENABLER0(+0x100)=0x????????
```

- CPU0 0xffff, CPU1 0x0000 -> H2 confirmed: BL31 on_finish killed the
  secondary's SGI/PPI enables.  Fix: in `poplar_pwr_domain_on_finish`
  (or gicv2_pcpu_distif_init), re-enable the non-secure mask, or stop
  the ICENABLER write from touching Group 1 interrupts.
- CPU0 not 0xffff -> H1 confirmed: the kernel's own enable writes are
  not sticking.  Look at gic_cpu_config() / GICD_ENABLE_SET writes and
  the secure-bank view over them.

## 8. Next steps in order

1.  **Boot the three-piece set, capture the full log** (5+ minutes),
    grep for `SCR_EL3`, `MV310-GIC`, `MV310-IRQ`, `smp: Brought up`.
    Apply the checklist in section 6.
2.  If SCR_EL3 bits[3:1] != 0 -> fix the BL31 exception routing, done.
3.  If the dump is all-green but still zero interrupts, run the
    initramfs bisect (`scripts/mv310-gic-bisect.sh`, needs the devmem
    image: maxcpus=1, STRICT_DEVMEM off): it self-pends SGI 8 and
    reads GICC_HPPIR (0xf1002018).
    - HPPIR shows 8 -> GICD->GICC works; the break is at the exception
      vector / DAIF.  Check VBAR_EL1, DAIF.IRQ, el1_irq vector.
    - HPPIR stays 0x3ff -> the distributor never forwarded it.  This
      is where H1/H2 and the GICD_CTLR banking become the suspects.
4.  maxcpus=4 boot to test H2 (CPU1-3 dumps) and to see whether the
    SMP bringup completes now that the dumps are observable.
5.  If everything is green and SMP still stalls, the remaining
    unexplored angle is a *hardware* GIC difference between mv300 and
    mv310 (secure fuse / Group 1 routing).  The original 32-bit
    firmware delivers IPIs to all four cores, so the GIC hardware can
    do it; compare its GICD_CTLR/IGROUPR0 cold-boot values from U-Boot
    (`md.l 0xf1001000 1`, `md.l 0xf1001080 1`, `md.l 0xf1001100 1`)
    against the mainline values.

## 9. Discipline (from the notebook, still binding)

- Never read 0xf1001104 as "ISENABLER0".  Real: 0xf1001100.
- Per-CPU registers (GICC_CTLR/PMR/HPPIR, CNTP_CTL) must be read on
  that CPU.
- gic_handle_irq must not read GIC_CPU_INTACK extra times (breaks ACK).
- After any .config change: `make ARCH=arm64 olddefconfig </dev/null`
  then grep `CONFIG_SERIAL_AMBA_PL011|CONFIG_CMDLINE=`.
- Every new image: independent filename + md5, archive in
  `/mnt/hdd/hi3798mv310-stuff/deploy/images/`.
- The devmem Image has `maxcpus=1` in CONFIG_CMDLINE (CMDLINE_FORCE=y,
  U-Boot bootargs are ignored); change CONFIG_CMDLINE for maxcpus=4.
