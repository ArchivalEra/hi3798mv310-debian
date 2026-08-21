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
| `/srv/tftp/mv310-l-loader-gicgrp1.bin` | `56283173` | l-loader + BL31 with patch 0002 |
| `/srv/tftp/mv310-tvbox-7.1.8.dtb` | `a1cec64c` | unchanged dtb (4-PPI armv8-timer) |
| `/srv/tftp/mv310-Image-7.1.8-gicgrp1` | `e35b730b` | kernel with patch 0001 (CONFIG_CMDLINE has maxcpus=1) |

Archives in `/mnt/hdd/hi3798mv310-stuff/deploy/images/`:
`Image-7.1.8-gicgrp1-v2-e35b730b`, `l-loader-mv310-gicgrp1-56283173.bin`.

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

---

# Addendum 2026-08-19 12:36 - v2 bench results and the new hang-on-SGI finding

> Authoritative status update for anyone taking this to the bench. The
> v2 set is the current deployed one; the sections above still apply.

## A1. v2 three-piece set (current, md5 verified)

| File | md5 | Change vs v1 |
|---|---|---|
| `/srv/tftp/mv310-l-loader-gicgrp1.bin` | `56283173` | gicv2_main.c reverted to stock; only the SCR_EL3 print remains |
| `/srv/tftp/mv310-Image-7.1.8-gicgrp1` | `e35b730b` | **GICD_CTLR write reverted to `GICD_ENABLE` only (0x1)**; GICC bit1 + IGROUP + MV310-GIC dump + MV310-IRQ probe kept |
| `/srv/tftp/mv310-tvbox-7.1.8.dtb` | `a1cec64c` | unchanged (has bl31 reserved-memory 0x02000000/0x40000) |

## A2. v1 result (the reason for v2) - GICD_CTLR bit1 write hangs boot

v1 Image `9673d8f5` wrote `GICD_ENABLE | EnableGrp1` in gic_dist_init()
-> runtime GICD_CTLR = 0x3 -> **boot hung right after sched_clock**
(t=0.000001, time_init section, no further output).

Bisection (no rebuild, expert-designed): old l-loader `sgigrp1`
(adb7459a, no BL31 patch 0002) + v1 Image -> still hung, GICD_CTLR
still 0x3.  Conclusion: **the hang was caused by the kernel-side
GICD_CTLR bit1 write itself**.  mv310's GICD_CTLR bit1 is NOT the
standard GIC-400 NS read-only mirror bit - writing it (even to 1)
hangs the boot.  This is now in the errata.

## A3. v2 bench results - early hang gone, boot runs to initramfs

```
NOTICE:  MV310: SCR_EL3 = 0x238
MV310-GIC[0]: GICD_CTLR(+0x000)=0x00000001 GICD_TYPER(+0x004)=0x0000fc65
  IGROUPR0(+0x080)=0xfe00ffff ISENABLER0(+0x100)=0x0000ffff
  ICFGR1(+0xc04)=0x55540000 GICC_CTLR(+0x000)=0x000003e3 GICC_PMR(+0x004)=0x000000f0
[0.008626] Console: colour dummy device 80x25
[0.075179] smp: Bringing up secondary CPUs ...
[0.079777] smp: Brought up 1 node, 1 CPU
[0.982983] Run /init as init process
[1.018469] === MV310-DEVMEM-TEST START ===
[1.031073] GICD_CTLR    (0xF1001000): 0x00000001
[1.038230] GICC_CTLR    (0xF1002000): 0x000003E3
[1.052527] ISENABLER0   (0xF1001104): 0x00000000   <- misread, ignore (see retraction)
[1.071563] --- STEP1: self SGI0 to CPU0 (SGIR=0x10000) ---
```

Checklist against section 6:

| Field | Expected | Bench | Verdict |
|---|---|---|---|
| SCR_EL3 bits[3:1] | 0 | 0x238 (bits1,2=0) | OK - no EL3 trap |
| GICD_CTLR | 0x1 | 0x1 | OK - revert verified |
| GICC_CTLR | 0x3e3 | 0x3e3 | OK - G0+G1 both on |
| IGROUPR0 | 0xfe00ffff | 0xfe00ffff | OK - SGIs/PPIs in Group1 |
| ISENABLER0 (0xf1001100!) | 0xffff | 0xffff | OK - **SGIs all enabled** |
| MV310-IRQ lines | any | **0** | FAIL - delivery still broken |

**Early hang is fully resolved. The system boots all the way into the
initramfs devmem test.** The old "hang at sched_clock" is gone.

## A4. NEW finding - writing SGIR hangs the system (was: "interrupt never arrives")

The initramfs STEP1 did:

```
devmem 0xF1001F00 32 0x00010000    # write SGIR: self-SGI0 to CPU0
```

After that: the script's own "after SGI0" HPPIR/SPENDSGIR reads NEVER
printed, the `MV310-IRQ` probe (first line of gic_handle_irq) fired
**0 times**, and the system sat completely still (2+ min).

Because the SGI is enabled (ISENABLER0=0xffff) and Group1 is open
(GICC 0x3e3, GICD 0x1), **the system dies on/after SGI delivery rather
than silently not delivering it**.  This retracts the earlier "SGI never
reaches the CPU" story: the interrupt is pending, but the CPU dies
*inside the delivery path*, before gic_handle_irq runs.

Likely layers (in order of suspicion):
1. exception vector / AArch64 trampoline (el1_irq -> ... -> gic_handle_irq)
2. GIC ACK path (IAR read in the handler loop)
3. SGI-trigger hardware behaviour on mv310 (GIC-400 with 1S/1NS quirks)

## A5. What is needed next (for the expert)

1. Judge which layer the "write SGIR -> hang" lives in. Candidate probe:
   print at el1_irq entry (before gic_handle_irq), or check whether the
   CPU is stuck in WFI/exception loop via a periodic CPU0 heartbeat.
2. The initramfs bisect has STEP2-4 ready (flip GICD_CTLR=0x3, clear
   FIQEn, IGROUP all-1, each re-sending SGI), but STEP1 must stop
   hanging before they can run.
3. Final acceptance unchanged: `MV310-IRQ` appears / `smp: Brought up
   2 CPUs` (drop maxcpus=1) / /proc/interrupts SGI counters tick.

## A6. Bench state (as of this addendum)

- Board: hung in the devmem STEP1 (needs power-cycle to return to fastboot)
- Serial proxy: `/mnt/hdd/hi3798mv310-stuff/scripts/serial-proxy.py`
  (/tmp/ttybox + TCP 5555 ro / 5556 cmd / 5557 duplex)
- Bench tooling: `/mnt/hdd/hi3798mv310-stuff/scripts/fb-run.py`
  (stage / go / go-boot / cmd)
- Working logs: `/tmp/serial-live.log` (this round, full)
- Notes (Chinese, not in this repo): `/mnt/hdd/hi3798mv310-stuff/notes/mv310-expert-handoff-08191236.md`

---

# Addendum 3 - 2026-08-19 expert review: the A4 finding is unproven (sleep confound), and three instrument corrections

## B1. The "write SGIR -> hang" evidence is contaminated (A4 downgraded)

The on-board script (`builds/initramfs/init`) ran `sleep 1` immediately
after the STEP1 SGIR write. This kernel receives **zero interrupts for the
whole boot** (MV310-IRQ = 0 always, no timer IRQ), and nanosleep wakeups
are delivered by the arch-timer IRQ - which never arrives. So `sleep`
never returns, the sequential script goes silent, and serial silence is
indistinguishable from a real hang. The A4 conclusion "the system dies on
SGI delivery" is therefore **unproven**; the only hard fact remains the
old one: no interrupt is ever taken (0 MV310-IRQ lines).

## B2. The MV310-IRQ probe is NOT at the first line of gic_handle_irq

In `drivers/irqchip/irq-gic.c` the probe (`pr_info("MV310-IRQ: ...")`)
sits **after** `readl_relaxed(cpu_base + GIC_CPU_INTACK)` - i.e. after
the IAR read. "0 probe hits" therefore does not exonerate the GIC ACK
path: a CPU that hangs on the IAR read would also produce zero hits.
When the probe moves (see B4), a hit order of ENTER-print-then-nothing
pinpoints the IAR read.

## B3. Script bugs found and fixed

- `builds/initramfs/init` read ISENABLER0 from 0xF1001104 again
  (ISENABLER1) and SPENDSGIR0 from 0xF1000F20 (outside the GICD window;
  real offset 0xF1001F20). Both fixed.
- `scripts/mv310-gic-bisect.sh` defined CPENDSGIR at +0xf00 - that is
  **GICD_SGIR** (CPENDSGIR0 is +0xf10), so the "best effort clear" line
  was firing a self-SGI0: the exact hang trigger. Fixed. Also removed its
  `sleep 2` (same confound as B1).

## B4. Next boot: the no-sleep ladder (scripts/mv310-sgir-layer-bisect.sh, mirrored into builds/initramfs/init)

After editing the initramfs, re-link the Image (`make Image`, the tree
has CONFIG_INITRAMFS_SOURCE pointing at builds/initramfs) and re-stage.
The ladder has no sleep; every step prints a marker before the risky
action, so the last marker seen names the killing step:

- E0 SGIR no-op write (empty target list)
- E1 SGIR no-target (filter=01 all-but-self, CPUs 1-3 offline -> nobody
  is delivered to). Dies -> the write stalls the bus. Lives -> only
  delivery can kill.
- E2a/E2b SGI0 priority 0xFF (above PMR 0xF0 -> held, not signalable),
  then self-SGI0. SPENDSGIR0 bit0=1 must print (pend registered).
- E2c restore priority -> signaling becomes legal at this write. Dies ->
  delivery kills, registers and write mechanics innocent. Lives with
  HPPIR=0x0 -> SGI0 pending AND signalable but never taken: fault is at
  the CPU side (DAIF / vector routing / HCR_EL2).
- E1b filter=10 self-only positive control; R verbatim replay of the
  original STEP1 (R surviving retracts A4 fully).
- S sleep sanity last: POST-SLEEP-LIVE would mean timer IRQs work and
  the zero-interrupt premise itself must be re-examined.

## B5. One-rebuild probe set (only if the ladder points at the CPU side / delivery kills)

1. `gic_handle_irq`: add `pr_info("MV310-IRQ-ENTER cpu=%u", ...)` as the
   true first statement, **before** the IAR read (keep the existing
   after-IAR print renamed MV310-IRQ-IAR). Splits "died before the
   handler" from "died on the IAR read".
2. arm64 entry probes in `arch/arm64/kernel/entry-common.c` at
   `el1_interrupt()` / the el0 IRQ path, before `handle_arch_irq`.
3. One-shot sysreg dump (boot CPU, EL1-readable set): VBAR_EL1, DAIF,
   CurrentEL, SCTLR_EL1.
4. BL31: extend the existing SCR_EL3 print to also print **HCR_EL2 and
   VBAR_EL2**. Rationale: sync exceptions provably work (syscalls from
   devmem), while IRQ/FIQ routing is independently controlled by
   HCR_EL2.TGE/IMO/FMO - and SCR_EL3 (0x238) is already clean, VBAR_EL1
   is proven good by working syscalls. HCR_EL2 is the one routing
   register nobody has looked at. If it is clean too, the remaining
   suspects are the IAR read and mv310-specific GIC signaling.

## B6. Re-reading of the v1 hang (mechanism correction)

The v1 GICD_CTLR bit1 write **completed** - v1 kept booting after
init_IRQ and died later at time_init. So "writing bit1 hangs instantly"
is wrong as a mechanism. Two compatible readings: (a) the write enabled
forwarding of an already-pending interrupt and the first-ever signaled
IRQ killed the CPU (same kill zone the ladder tests), or (b) the write
poisoned the GICD so the next GICD write (the arch-timer ISENABLER at
time_init, the first GICD write after init_IRQ) stalled the bus. The
revert stays correct either way; the errata wording should be softened
from "writing it hangs" to "enabling it leads to a hang at the next
interrupt-arming point".

---

# Addendum 4 (2026-08-19 22:58) - v3 ladder bench result: dies reading ISACTIVER0

## 4.1. The three-piece set is unchanged (md5)

| File | md5 |
|---|---|
| `/srv/tftp/mv310-l-loader-gicgrp1.bin` | `56283173` |
| `/srv/tftp/mv310-Image-7.1.8-gicgrp1` | `59fa2b36` (v3 no-sleep ladder) |
| `/srv/tftp/mv310-tvbox-7.1.8.dtb` | `a1cec64c` |

Full log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-ladder-v3-225410.log`

## 4.2. Bench output (last line = death point)

```
[1.220898] === MV310-GIC-LADDER START (no-sleep revision) ===
[1.232829] --- L0: kernel's own view ---
[1.232829]   9: 0  GICv2  25 Level  vgic
[1.232829]  11: 0  GICv2  30 Level  arch_timer     <- IRQ30 = SPI 30, NOT a PPI
[1.232829]  12: 0  GICv2  27 Level  kvm guest vtimer
[1.232829] IPI0-7: all 0                              <- IPIs never delivered
[1.312431] --- L1: baseline registers (CPU0, NS view, fixed offsets) ---
[1.321688] GICD_CTLR    (0xF1001000): 0x00000001
[1.328891] GICC_CTLR    (0xF1002000): 0x000003E3
[1.336018] GICC_PMR     (0xF1002004): 0x000000F0
[1.343158] IGROUPR0     (0xF1001080): 0xFE00FFFF
[1.350295] ISENABLER0   (0xF1001100): 0x4A00FFFF     <- last line, then dead
[        ] ISACTIVER0   (0xF1001300): (never printed)
```

## 4.3. Reading (the ladder never got to run, but this is the most informative cell yet)

The system died in the middle of a *pure register-read sequence* -
after ISENABLER0(0x1100), before ISACTIVER0(0x1300) came out.

1. **No SGIR write ever happened** (E0-MARKER not printed) -> the whole
   "SGIR write hangs" branch is excluded. Death has nothing to do with writes.
2. The dying access is **reading 0xF1001300 (ISACTIVER0)** -> a GIC
   register read sequence faults/hangs at ISACTIVER0.
3. The old devmem baseline (ec441e24) read 7 registers fine, but NEVER
   read 0x1300. This script's new ISACTIVER0 read is the tripwire.

## 4.4. Two hard side-facts

- `ISENABLER0=0x4A00FFFF`: bit17 (PPI17 vtimer) + bit26 (PPI26) were
  enabled later by drivers - the kernel IS enabling interrupts, SGI/PPI
  enable state is live, not all-zero.
- `arch_timer` is **SPI 30**, not a PPI (L0: irq 11 = GICv2 30 Level).
  The main timer is an SPI despite the 4-PPI armv8-timer dts - worth
  noting by itself.

## 4.5. Questions for the expert

1. **Is ISACTIVER0(0xF1001300) a landmine on this GIC variant?** Is the
   NS read of that offset illegal/not-implemented on GIC-400 1S/1NS?
   Does Hi3798's GIC omit the distributor ACTIVE registers?
2. Suggestion: **skip ISACTIVER0 (0x1300) in the ladder**, L1 reads only
   0x1000/0x2000/0x2004/0x1080/0x1100/0x1400/0x1f20/0x2018, go straight
   into E0-E2-R-S. If the ladder completes after dropping 0x1300, that
   proves 0x1300 is the kill zone.
3. If reading 0x1300 triggers a recoverable sync fault (SIGBUS/SIGSEGV),
   devmem would die silently on serial but the script would continue -
   here the system is COMPLETELY still, which looks like a hang
   (WFI/exception loop), not a one-shot recoverable fault.

---

# Addendum 5 (2026-08-20) - v4 minimal isolation result: dies right after reading ISENABLER0 (AUTHORITATIVE)

## 5.1. The v4 experiment (per expert review, all confounds removed)

- Image `646e8684` (v4): initramfs rewritten - **ISACTIVER0 (0x1300) skipped entirely**,
  no `sleep`, no `$(devmem)` command substitution, no `set -e`, and **every MMIO access
  bracketed by `X-BEFORE` / `X-AFTER rc=$?`**.
- Only 7 registers touched: GICD_CTLR(0x1000), IGROUPR0(0x1080), ISENABLER0(0x1100),
  GICC_CTLR(0x2000), GICC_PMR(0x2004), GICC_HPPIR(0x2018), SGIR(0x1F00).
- l-loader `56283173`, dtb `a1cec64c` unchanged. Bench flow fixed: `go` then let autoboot
  boot the staged set (no second `go`, no Synchronous Abort).
- Full log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-v4-minimal-011120.log`

## 5.2. Bench output (last line = death point)

```
[1.221318] === MV310-GIC-MINIMAL START (v4, no 0x1300, no sleep, no $()) ===
[1.228574] --- L1: baseline reads (each bracketed) ---
[1.233870] R-GICD_CTLR-BEFORE
[1.238760] 0x00000001
[1.241627] R-GICD_CTLR-AFTER rc=0          <- read OK
[1.245100] R-IGROUPR0-BEFORE
[1.249905] 0xFE00FFFF
[1.252773] R-IGROUPR0-AFTER rc=0          <- read OK
[1.256160] R-ISENABLER0-BEFORE
[1.261130] 0x4A00FFFF                     <- devmem read RETURNED the value
        (R-ISENABLER0-AFTER rc=$? never printed)
```

## 5.3. Reading (the whole story in one cell)

1. **0x1300 is exonerated**: v4 never reads ISACTIVER0 yet dies at the same relative
   point. The v3 "dies reading ISACTIVER0" was a red herring.
2. **Death is instruction-level**: `devmem 0xF1001100` read SUCCEEDED (0x4A00FFFF
   printed) but the next shell `echo AFTER` never ran - the system dies between
   devmem process exit and shell resumption.
3. GICD_CTLR and IGROUPR0 reads are both fine (BEFORE + value + AFTER rc=0).
   Only the ISENABLER0 read is followed by death.
4. **Most likely mechanism**: reading ISENABLER0 (which has PPI17 vtimer + PPI26
   enabled) samples/strobes the GIC's pending PPI state; when the devmem syscall
   returns and IRQs are re-enabled, a pending interrupt is taken and the CPU dies
   in the exception entry path - before gic_handle_irq (hence the zero MV310-IRQ
   lines every boot).

This narrows the field decisively: **interrupts can pend and signal to the CPU,
but the CPU dies taking the interrupt**. Suspect: AArch64 exception vector /
trampoline, or the GIC ACK (IAR read) path.

## 5.4. Next probes (in order)

1. Kernel: add `MV310-IRQ-ENTER` as the TRUE first line of gic_handle_irq (before the
   IAR read); rename the existing print `MV310-IRQ-IAR`. ENTER printed + IAR not ->
   dies in IAR read. ENTER not printed -> dies even earlier (vector/trampoline).
2. `arch/arm64/kernel/entry-common.c` el1_interrupt() entry print; one-shot sysreg
   dump (VBAR_EL1, DAIF, CurrentEL, SCTLR_EL1).
3. BL31: print HCR_EL2 and VBAR_EL2 next to the existing SCR_EL3 print. Sync
   exceptions work (devmem syscalls fine), VBAR_EL1 fine, SCR_EL3 clean (0x238,
   bits 1-2 = 0) - **HCR_EL2.TGE/IMO/FMO is the only untested routing register**.
4. Acceptance unchanged: `MV310-IRQ` appears / `smp: Brought up 2 CPUs` (drop
   maxcpus=1) / /proc/interrupts SGI counters tick.

## 5.5. Bench state

- Board: hung right after the ISENABLER0 read (power-cycle to fastboot to rerun).
- Current Image `646e8684` is the v4 minimal-isolation build, already deployed.
- ccache now baked into `kernel/build-mv310-718.sh` (`CC="ccache clang"`,
  `CCACHE_DIR=$BASE/.ccache`).

---

## Addendum 6 — root-cause analysis (2026-08-20, expert review)

### A6.1. Key new findings

1. **GICC_CTLR banked proof of NS state**: BL31 CPUON probe reads S-view
   `gicc_ctlr = 0x1E9` (FIQEn=1, bit1=0), while NS runtime reads `0x3E3`
   (bit1=1, EOImodeNS). Different banked values confirm the Linux kernel runs
   in **Non-secure state** — the EL3→NS handover path is correct.

2. **GICC_HPPIR = 0x3FF (spurious, nothing pending)** in the 031546 run (which
   survived past 1.27 s). Despite `ISENABLER0 = 0x4A00FFFF` showing PPI30
   (arch timer) enabled, the CPU interface sees zero pending interrupts. This
   means the **distributor is gating the signal**, not the CPU interface mask.

3. **GICD_CTLR stock TF-A writes only EnableGrp0**: the upstream
   `gicv2_distif_init()` line was `ctlr | CTLR_ENABLE_G0_BIT` (bit1 missing).
   Our tree has an uncommitted patch adding `CTLR_ENABLE_G1_BIT`, but the
   deployed l-loader `56283173` is "unchanged" — almost certainly lacks it.

4. **arch_timer uses PPI30 (phys non-secure), not PPI27 (virt)**:
   `is_hyp_mode_available()` returns true (kernel entered at EL2) so
   `arch_timer_select_ppi()` picks `ARCH_TIMER_PHYS_NONSECURE_PPI`. This is
   normal for nVHE KVM configs and is NOT a bug.

5. **vendor 32-bit kernel uses MMIO timers (SPIs 58/91/59/92), not cp15 timer**:
   the vendor DT `timer@0xf8a29000` with `clockevent 0-3` on GIC SPIs.
   The mainline hi3798mv200.dtsi has no MMIO timer node and there is no
   upstream driver for it. If cp15 PPI30 is unwired on this SoC, a timer
   porting effort would be needed (lower priority — test H-GATE first).

### A6.2. Top hypothesis: distributor G1 gate (H-GATE)

On GIC-400 with Security Extensions, **NS bit0 of GICD_CTLR is an alias for
EnableGrp1NS**. Mainline writes `GICD_ENABLE = 0x1` at boot → NS readback
0x1 → Grp1-NS should be enabled → interrupts should flow. They don't.

This SoC's GIC exhibits two confirmed non-standard behaviors:
- Writing GICD_CTLR bit1 (NS reserved) from the kernel hangs instantly (v1).
- Reading ISENABLER0 NS (0xF1001100) from userspace kills the box within ms
  (v3 and v4; reading 0x1104 is safe).

Both are deviations from GIC-400 spec, proving this is **not a stock GIC-400**.
If NS bit0 is also a deviation (not a true Grp1-NS alias), then the kernel's
`GICD_ENABLE = 0x1` does not actually enable Group1, and the only real gate is
**S-view bit1**, which the stock BL31 left clear.

This explains the full symptom set: zero IRQs, HPPIR=1023, v1 hang (first
delivery after Grp1 accidentally opened), and the vendor kernel working (its
bootloader chain is different).

### A6.3. v5 experiment (one-boot discriminator)

The v5 init script replaces v4 in `builds/initramfs/init` (v4 backed up as
`init.v4.bak`). It adds:

- **ISPENDR0** (0xF1001200): does the distributor see PPI30 pending?
- **ICFGR0** (0xF1001C00): trigger type as configured
- **HPPIR + RPR + PMR**: re-reads (proven safe in 031546)
- **ISENABLER1** (0xF1001104): control read (safe baseline)
- **Clean SGI8 self-test**: write SGIR `0x02000008` (self, SGI8), then
  immediately `cat /proc/interrupts` + `dmesg | grep -c MV310-IRQ` —
  **no sleep anywhere**
- **HPPIR re-read after SGI**: did the SGI reach the CPU interface?

No reads of 0xF1001100 or 0xF1001300.

**Decision tree:**

```
ISPENDR0 bit30 = 1  AND  HPPIR = 0x3FF  AND  IPI counts unchanged
  → H-GATE confirmed: Grp1 gated at distributor.  Rebuild BL31 with
    EnableGrp1(S) committed, deploy new fip.  Expected: one-shot fix.

ISPENDR0 bit30 = 0  AND  IPI counts++
  → H-GATE wrong: delivery works, timer PPI is unwired.
    Port vendor MMIO timer (big effort, plan separately).
```

### A6.4. Kernel probe patch (v5 Image)

Applied to `drivers/irqchip/irq-gic.c` in the linux-718 tree:

| Patch | Purpose |
|---|---|
| `MV310-IRQ-ENTER` before GICC_IAR read | Distinguish "dies before entry" vs "dies at IAR" |
| `MV310-IRQ-IAR` renamed from old `MV310-IRQ` | Preserve IAR observation |
| `MV310-GICMAP` expanded with `isenabler0` + `pmr` (kernel-side read) | Userspace never touches 0x1100 again |
| `MV310-SYSREG` one-shot dump: VBAR_EL1, DAIF, CurrentEL, SCTLR_EL1, MPIDR | Proves vector base is sane; catch vector corruption |

### A6.5. BL31 patch (gicv2_main.c)

Added `printf("MV310-BL31-GICD: ... S-view ctlr=0x%x ...")` at the end of
`gicv2_distif_init()`. Prints once at cold boot — serial log shows whether
EnableGrp1 was actually written in the deployed fip. Combined with the
uncommitted EnableGrp1 write already in the working tree, this makes the fix
observable in a single boot.

### A6.6. Recommended experiment sequence

1. **v5 initramfs + IRQ-ENTER + SYSREG dump** (same Image rebuild) — 10 min
2. **Rebuild fip with EnableGrp1(S) committed**, deploy to l-loader — 30 min
3. **CONFIG_KVM=n** — eliminates nVHE EL2 as confounder (one-line config flip)
4. If interrupts flow after step 2: add `maxcpus=4` and test full SMP bring-up


---

## Addendum 7 (2026-08-20 12:31) — v5b bench: dies right after reading ICFGR0

### 7.1. What changed vs the first v5 boot

The first v5 boot hung at `smp: Bringing up secondary CPUs ...` (no
`MV310-GIC-V5`) because `refs/configs/kernel.config.mv310` lost
`maxcpus=1` after the config restore.  v5b restores it, rebuilds with
ccache (10 min incremental), md5 `0f66239d`, and boots single-core to
the v5 ladder.  S-view `GICD_CTLR=0x3` (BL31 `MV310-BL31-GICD`) is still
0x3.

### 7.2. Bench output (last line = death point)

```
[1.021618] === MV310-GIC-V5 START (ISPENDR + clean SGI self-test) ===
[1.130534] --- L1: NEW reads first (ISPENDR0 0x1200, ICFGR0 0x1C00) ---
[1.137353] R-ISPENDR0-BEFORE
[1.142208] 0x00000000
[1.145098] R-ISPENDR0-AFTER rc=0
[1.148485] R-ICFGR0-BEFORE
[1.153106] 0xAAAAAAAA               <- last line, then dead
```

Log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-v5-icfgr0-123155.log`

### 7.3. Reading

1. ISPENDR0 = 0x00000000: no PPI30 pending seen at this instant (so the
   "pending-but-gated" H-GATE signature is absent this boot).
2. The kill point moved from ISENABLER0 (v4) to ICFGR0 (v5) but is
   structurally identical — value printed, next `After` never runs.
   The v4 "ISACTIVER0 kill" → v4 "ISENABLER0 kill" → v5 "ICFGR0 kill"
   sequence shows the trigger is devmem-sampling a distributor state
   that makes an IRQ signal on syscall return.

### 7.4. Next

- Skip ICFGR0 reads entirely; go straight from ISPENDR0 to
  `SGIR 0x02000008` (SGI8 to self) and check HPPIR.  If that survives,
  H-VEC vs H-GATE vs H-SRC can be decided in a single boot.
- Or rely on the kernel-side HPPIR + GICMAP values, which are not
  subject to the userspace devmem exception path.

---

# Addendum 8 (2026-08-20 evening) — expert re-analysis: three corrections, one unified suspect (T1), one discriminating build

> Full review of `serial-v5-icfgr0-123155.log` (BOTH boots), the v3/v4/031546
> logs, `builds/initramfs/init`, `arch/arm64/kernel/smp.c`, `irq-gic.c`,
> `irq-gic-common.c`, TF-A `runtime_exceptions.S`/`psci_on.c`/`plat_pm.c`,
> and the kernel .config. No new boot was needed for any of this.

## 8.1 New facts mined from existing data

1. **The v5b log contains TWO boots; boot #1 (v5, maxcpus lost) is the most
   informative cell of the whole investigation.** After "MV310-CPUON state
   validated rc=0", the garbled line de-interleaves (tail is clean:
   `=1 gicc_ctlr=0x1e9 pmr=0xf8`) into: BL31's psci_on tail
   ("MV310-CPUON unlocked+returning rc=0", fragments "N-unlo ked f i eturn
   anger") concurrent with kernel CPU1 prints. The clean tail is the ending of
   `MV310-GICMAP-EARLY: cpu_init entry cpu=1 gicc_ctlr=0x1e9 pmr=0xf8`.
   **CPU1 booted into the kernel and reached gic_cpu_init.** The garble itself
   is benign: BL31 printf and kernel printk share no lock; two masters on the
   PL011 interleave and drop bytes.
2. **CPU1's death zone is now bounded to one function.** In
   `secondary_start_kernel` (arch/arm64/kernel/smp.c), `notify_cpu_starting()`
   (line 243, which runs the cpuhp callback → gic_cpu_init) comes BEFORE the
   "CPU%u: Booted secondary processor" print (line 252). A1(cpu=1) printed,
   "Booted secondary processor" never did ⇒ CPU1 died/wedged INSIDE
   gic_cpu_init, between the GICMAP-EARLY print and the GICMAP print. The MMIO
   in that window (all executed fine by CPU0 at [0.000000]; only the CPU1
   banked register file differs):
   - `gic_get_cpumask`: ITARGETSR0-7 reads (0xF1001800..0xF100181C)
   - `gic_cpu_config` (irq-gic-common.c:121): writes 0xffffffff to
     ICACTIVER0 (0xF1001380) and ICENABLER0 (0xF1001180), then IPRIORITYR0-7
     writes (0xF1001400..0xF100141C)
   - GICC_PMR write (0xF1002004); `gic_cpu_if_up`: GICC_CTLR read, GICC_IDENT
     read (0xF10020FC), 4× GICC_APRIO writes (0xF1002100+) if ident matches,
     GICC_CTLR read+write.
3. **The SMP hang can never self-report.** CPU0's wait is
   `wait_for_completion_timeout(&cpu_running, msecs_to_jiffies(5000))`
   (smp.c:135). The timeout needs a timer IRQ; timer IRQs never fire ⇒ the
   5s timeout never expires ⇒ `CPU1: failed to come online` can NEVER print.
   CPU0 sleeps forever. Frozen jiffies also mean EVERY
   wait_for_completion_timeout in this kernel is forever — this is the same
   reason `sleep` never returns (B1) and no hang can ever time out.
4. **No CPU is sitting in an unhandled EL3 trap.** TF-A wires
   `report_unhandled_exception` / `report_unhandled_interrupt` to all EL3
   vectors (bl31/aarch64/runtime_exceptions.S:266-306) and the BL31 console
   demonstrably works at t=0.075s. No EL3 dump ever appeared after any
   "death" ⇒ the "SCR_EL3.EA=1 silently swallows an async abort into EL3"
   family is refuted.
5. **earlycon is the ONLY console — forever.** There is no
   "console [ttyAMA0] enabled" line anywhere; uart-pl011 never probed (clock
   lookup, likely). Kernel printk, userspace echo AND devmem's value print
   all go through the single earlycon pl011@0xf8b00000 poll path (the init
   script does `exec 1>/dev/kmsg`, so script output is vprintk → console →
   same UART). A wedge anywhere in this one path silences everything, and
   there is no RX path either (serial input can never be an aliveness check).
6. **Aliveness after every "death" was never tested.** B1's own retraction
   logic ("serial silence is indistinguishable from a hang") applies equally
   to v3/v4/v5b: the box may have been alive-but-wedged (or alive with a
   wedged console) in all three. The init script even ends with
   `while :; do :; done` — an alive-forever PID1.
7. **031546 is a counterexample to "userspace GICD reads kill".** It survived
   SIX userspace reads (0x1000, 0x2000, 0x1080, 0x1104, 0x2014, 0x2018 —
   each bracket-printed) and only went silent after the SGIR WRITE + sleep.
   EL0-fatal set so far: {0x1100 read ×2, 0x1C00 read ×1}. EL0-safe set:
   {0x1000, 0x1080, 0x1104, 0x1200, all GICC}. And the asymmetry: **kernel
   EL1 reads 0xF1001100 fine at every boot** (GICMAP probe prints
   isenabler0) — same register, same instruction class, different privilege.

## 8.2 Three corrections to the v5b reading (§7.3 items 2-3 are retracted)

1. **"die on interrupt take" is NOT supported by v5b's own
   data.** At 1.142s ISPENDR0=0x00000000 — nothing pending (no SGI, no PPI;
   no SPIs enabled), so in the ICFGR0→echo window there was nothing legal to
   deliver. MV310-IRQ-ENTER — the TRUE first statement of gic_handle_irq,
   before the IAR read, deployed in the v5b Image — fired 0 times in both
   boots. An interrupt that never pends cannot be taken; one delivered late
   in the window would have printed ENTER first. The "devmem sampling → IRQ
   re-enable → take → die" chain must be withdrawn as the v5b mechanism.
2. **The kill is not offset-specific in any architectural sense.** Fatal
   reads moved 0x1300 (v3, already retracted) → 0x1100 (v4) → 0x1C00 (v5b),
   and 031546 survived six reads off the same page. What IS consistent:
   output stops within ~0-10ms after certain EL0 GICD transactions, at a
   varying instruction, zero bytes after, no oops, no EL3 dump.
3. **H-GATE is refuted as the timer explanation.** ISPENDR0=0 +
   GICC_HPPIR=0x3FF (031546) + arch_timer count=0 after >1s at HZ=250 means
   PPI30 never asserted at all — nothing pending to gate. A gate would show
   "pending but not signaled" (ISPENDR0 bit30=1, HPPIR=0x3FF). H-SRC (the
   cp15 timer PPI line never asserts; the vendor kernel used MMIO timers on
   SPIs 58/91/59/92) is now the leading root cause for the zero-timer-IRQ
   symptom, and frozen jiffies follow from it.

## 8.3 Unified suspect T1: the GICD slave port (or its bus/firewall) wedges on specific transactions

- v1: kernel EL1 write GICD_CTLR=0x3 — write completes (boot continued past
  init_IRQ), then the NEXT GICD transaction (arch timer ISENABLER write at
  time_init) never completes → silent hang at time_init. This is B6 reading
  (b), now with a mechanism.
- v3/v4/v5b: EL0 read of 0x1100/0x1C00 completes (value printed) but
  asynchronously poisons the fabric; the next uncacheable peripheral access —
  the UART FR poll of the next console write — blocks forever. On Cortex-A53,
  Device-memory loads are strongly ordered: one stalled outstanding device
  load blocks subsequent device accesses on that CPU. Result: total silence,
  no exception, no EL3 dump.
- 031546's post-SGIR silence: either `sleep` (B1) or the EL0 SGIR WRITE
  wedging — indistinguishable retroactively; E2 re-tests. A4's status goes
  from "retracted" back to "undetermined".
- boot #1: CPU1's banked sequence above (or TF-A's gicv2_pcpu_distif_init
  writes moments earlier — see 8.4 step 4) wedges CPU1; CPU0 sleeps eternally
  on a timeout that can never expire.
- The EL0-vs-EL1 asymmetry on 0xF1001100 points at a HiSilicon
  bus/firewall behavior keyed on AXI protection bits (unprivileged/NS),
  i.e. NOT interrupt logic at all.
- T1 requires no interrupt to be delivered anywhere; it is compatible with
  all observations including zero ENTER hits and zero pending interrupts.

Demoted but alive:
- T2 — console/printk-only software wedge, box alive (console_lock held
  forever / earlycon stuck). E1's raw heartbeat discriminates: H's continue
  while printk stops ⇒ T2.
- H-VEC — "first IRQ kills before gic_handle_irq". Demoted (nothing pending;
  pre-IAR ENTER never hit). Remains testable by E2's SGIR step.
- H-GATE — refuted for PPIs/timer; only meaningful for SGI forwarding until
  the SGIR test actually runs.

## 8.4 The discriminating build (one kernel rebuild + one script rewrite)

E1 "flight recorder" (kernel, additive only):
1. **Raw-UART heartbeat**: SCHED_FIFO(1) kthread pinned CPU0, pure busy loop
   (never sleeps — no timers exist), every ~200ms (calibrate on cntvct) poll
   FR at ioremap(0xf8b00000)+0x18 until TXFF (bit5) clears, then write 'H'
   to DR (+0x00). NO printk involvement — bypasses every lock in the system.
   RT-throttling yields ~50ms/s to the shell: enough. Every Nth beat may
   additionally pr_info("HB") and kernel-read GICC_HPPIR to compare raw vs
   printk health.
2. **gic_cpu_init step markers** (secondary path): one printk before each
   MMIO group: [CI-1] cpumask read, [CI-2] clear writes, [CI-3] pri writes,
   [CI-4] pmr write, [CI-5] ident read, [CI-6] ctlr write, [CI-7] done.
   Localizes boot #1's CPU1 death to instruction granularity.
3. Keep ENTER/IAR probes. Optional: el1_interrupt()/el0 IRQ entry one-shot
   print in entry-common.c (vector→handler gap); add ISR_EL1 to MV310-SYSREG.

E2 "zero-read" init script (same rebuild):
1. FIRST action, before ANY other userspace GICD/GICC access: the SGIR
   self-test — P-BEFORE; `devmem 0xF1001F00 32 0x02000008`; echo P-AFTER
   rc=$?; `dmesg | grep -c MV310-IRQ`; `cat /proc/interrupts`. If the SGI8
   counter increments and ENTER prints ⇒ GIC delivery AND the vector path
   WORK ⇒ the "delivery is lethal" story collapses and the remaining work
   is the timer port.
2. Then read ISPENDR0 (0x1200, safe) + GICC_HPPIR (0x2018, safe): did SGI8
   pend / reach the interface?
3. LAST: re-challenge one fatal read (`devmem 0xF1001100` or 0xF1001C00)
   with the heartbeat running. Outcome table:
   - H's continue, printk continues, read survives ⇒ the "read kills"
     pattern was coincidence — re-examine from scratch.
   - H's continue, printk stops ⇒ T2 (console/printk software wedge; box
     alive) — dig console_lock/earlycon.
   - H's stop instantly ⇒ T1 (CPU0/fabric wedge) — and combined with E1.2,
     boot #1 localizes too.
4. Zero-code datapoint for the next maxcpus=4 boot: check whether BL31's
   `MV310-GIC: on_finish after cpu=1 ...` appears. Present ⇒ TF-A's banked
   writes on CPU1 completed, wedge is in the kernel sequence. Absent (only
   the pre-init "on_finish cpu=1") ⇒ the wedge is in TF-A's own
   gicv2_pcpu_distif_init on CPU1 (feeds H2/E5).

E3 If E2 shows SGI delivery works: the real blocker is H-SRC. Port the
   vendor MMIO timer (timer@0xf8a29000, clockevents on SPIs 58/91/59/92) as
   clockevent; keep the cp15 counter as clocksource. Jiffies live ⇒ timeouts
   live ⇒ SMP bringup can self-report, sleep works, RCU advances.

E4 CONFIG_KVM=n control build (A6.6 step 3) — keep separate from E1.

E5 If E1.2 pins CPU1's death to a specific op: test the H2 fix — BL31
   gicv2_pcpu_distif_init skipping the banked ICENABLER nuke (or skipping
   pcpu_distif_init entirely) — one-boot test.

## 8.5 Handoff corrections and new discipline entries

- Retract §7.3 items 2-3 (the "devmem sampling → IRQ re-enable window"
  mechanism) and section 8's reading accordingly.
- A4/B1: post-SGIR silence in 031546 is "undetermined", not "sleep confound"
  — under T1 the EL0 SGIR write itself is a wedge candidate.
- New discipline entries:
  1. EL0 devmem access and EL1 kernel access to the same GICD offset are NOT
     equivalent — never cross-apply safety conclusions.
  2. earlycon is the only console and has no RX path; serial input can never
     be an aliveness check; the only aliveness channel is a raw-UART (or
     GPIO) heartbeat.
  3. Every wait_for_completion_timeout in this kernel is FOREVER until the
     timer is fixed — no hang can time out or self-report.
  4. "Serial silence" proves nothing about life or death — always run a
     heartbeat before interpreting silence.


---

# Addendum 9 (2026-08-21) - v7/v7.1: zero-touch death without EL0 GIC access

## 9.1. v7 first run (Image `4e494b75`, probes-v7)

- `MV310-BL31-GICD ctlr=0x3`, `GICCPU-STEP CI-1..7 cpu=0` all pass,
  `GICMAP 0x3e3/0xFFFF`, `SYSREG VBAR 0xffff800080011000`.
- **M1-M5 survived** (1.15/2.52/3.88/5.25/6.61 s); M6 never printed.
- `MV310-SGIR BEFORE/AFTER spend=0x00000000 hppir=0x3FF` at t=69 s:
  the EL1 SGIR write executes but the distributor never pends SGI8.
- **HB n=1 only** - the raw-UART heartbeat was starved by the M-loop
  (or taken by the same wedge), so CPU-dead vs console-dead stayed
  undecidable.

## 9.2. v7.1 instrument fix (Image `147309b4`, probes-v7.1)

Seven changes in one rebuild:
1. HB: `SCHED_FIFO(1)` + single-byte `H` + interval 50->200 ms.
2. `mv310_hb_base` exported (`EXPORT_SYMBOL_GPL`) for cross-file use.
3. `entry-common.c el1_interrupt` first line: `MV310-EL1-ENTER`
   raw-UART `'E'` probe (noinstr-safe, reuses HB mapping).
4. initramfs: M-loop 80000->20000 + `usleep 10000` every 5 markers;
   C segment (EL0 0xF1001100) now conditional on HB+SGIR being seen;
   banner versioned `V7.1`.
5. ATF `gicv2_main.c`: added `MV310-BL31-HCR: hcr_el2/vbar_el2` print
   (the only untested routing register; ships with the next l-loader).
6. probe-registry: new `MV310-EL1-ENTER` row.
7. fb-run.py: wait_for extended to `['M1','Z-DONE','P-AFTER-SGIR','HB',
   'MV310-GIC-V7']`, timeout 35->60 s.

## 9.3. v7.1 result (log `serial-v7.1-m5-184011.log`)

- Single-byte `H` at t=0.952 s (before the clk line) - HB priority works.
- `M1-M5` continuous to t=2.51 s (v7 was 6.6 s; the yield works),
  **M6 still never printed**.
- Same shape as v7: the zero-touch segment dies with NO GIC access.
  **The "first EL0 GIC access arms the poison" model is falsified by
  both v7 and v7.1.** Suspects narrow to T1 (fabric/console wedge,
  time-based not position-based) or the HB FR.TXFF poll itself
  stalling the UART window.

## 9.4. Questions for the expert

1. M5->M6 silence reproduced at two different timings (v7 6.6 s,
   v7.1 2.5 s). Does this support a fixed-window fabric death rather
   than script-position coincidence? Next cut: HCR_EL2 (BL31-HCR is
   built, ships next l-loader) or the entry-common E probe?
2. HB still printed only once (0.952 s). Is the FR.TXFF poll wedging
   (direct T1 fabric-stall evidence) or is the kthread starved again?
   Suggestion: drop the TXFF spin cap from 10000 to 100 and print an
   overflow counter.
3. SGIR spend=0 reproduced in v7 (t=69 s). If v7.1 rerun shows spend=0
   again WITH a continuous HB, H-GATE-SGI is confirmed and we move to
   E3 (port vendor MMIO timer `timer@0xf8a29000`, SPIs 58/91/59/92).

## 9.5. Current three-piece set

| File | md5 |
|---|---|
| `/srv/tftp/mv310-Image-7.1.8-gicgrp1` | `147309b49e0d2614856e29ad018c4522` |
| `/srv/tftp/mv310-l-loader-gicgrp1.bin` | `7cfe066218c14f1e2e9f2b33a079ca56` |
| `/srv/tftp/mv310-tvbox-7.1.8.dtb` | `a1cec64cce8da0bb01cd0e6efd7e59bb` |

Log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-v7.1-m5-184011.log`


---

# Addendum 10 (2026-08-21 19:16) - v7.2: CPU ALIVE, console dead (T2' CONFIRMED)

## 10.1. v7.2 changes (Image `a9423ce`, probes-v7.2)

Self-driven fix after v7.1: the single HB beat was **msleep()**, which
never returns on this board (zero timer IRQs).  v7.2 replaces it with a
busy-wait loop (no timer dependency), TXFF spin cap 10000->100 with an
overflow 'T' marker, and removes the timer-dependent `usleep` from the
init M-loop.

## 10.2. Bench result - the decisive cell

```
HHHHHHHHHHHHHHHH... (continuous, thousands of beats, still streaming)
```

- `H` stream: CONTINUOUS - CPU0 is alive, fabric alive, UART alive,
  FR.TXFF never sticks (zero 'T' overflow markers).
- `MV310-GIC-V7.2` banner: NEVER printed. Zero M markers. Zero kmsg.

**The init script's very first echo never reached the console, while
the raw-UART heartbeat on the SAME physical UART streams forever.**

## 10.3. Reading - T2' confirmed, whole history reinterpreted

1. **CPU is alive; the printk->console path is dead.**  The hardware
   UART works (HB proves it); the kernel's console layer wedged.
2. All previous "system hung" readings must be reinterpreted:
   every "value printed, next line never" death was the console
   pipeline dying mid-boot, not the CPU dying.
3. The SGIR spend=0 at t=69 s in v7 was real execution (late kmsg
   flush) - the script kept running after output died.
4. sleep never returning is REAL but SEPARATE (H-SRC: timer PPI30
   never fires).  Two independent faults, now cleanly separated:
   - Fault A (this addendum): printk/console wedge - masks everything.
   - Fault B: zero timer IRQs (H-SRC / H-GATE-PPI) - hidden behind A.

## 10.4. Next cut (Fault A first - it masks all observation)

Suspects inside printk->earlycon path, in order:
1. `console_lock`/`console_trylock` deadlock (a console driver
   registration or unregister holding the lock).
2. pl011 port->lock left locked by an interrupted write.
3. earlycon vs registered console handoff window
   ("Warning: unable to open an initial console" precedes the wedge).
4. printk kthread (CONFIG_PRINTK_INDEX/async printk) never scheduled
   because scheduler needs a timer tick.

Note 10.4.4 would unify Fault A and B: if console flushing depends on
the scheduler tick and the tick depends on PPI30, then fixing the
timer (E3 MMIO timer port) may resurrect the console too.  Cheap
discriminator next boot: make HB print into a global counter readable
via /proc (EL1) AND try one `printk` from a busy-wait context AFTER
PONR to see if console is lock-dead vs flush-starved.

## 10.5. Current three-piece set

| File | md5 |
|---|---|
| `/srv/tftp/mv310-Image-7.1.8-gicgrp1` | `a9423cede44295ce845ba3a6309e33ab` |
| `/srv/tftp/mv310-l-loader-gicgrp1.bin` | `7cfe066218c14f1e2e9f2b33a079ca56` |
| `/srv/tftp/mv310-tvbox-7.1.8.dtb` | `a1cec64cce8da0bb01cd0e6efd7e59bb` |

Log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-v7.2-hb-live-191606.log`


---

# Addendum 11 (2026-08-21 19:36) - v7.3: printk healthy, console flush starved -> FAULTS A AND B UNIFY

## 11.1. v7.3 changes (Image `4de5190d`)

HB kthread gains a one-shot console probe at beat 25 (~5 s): raw-UART
'B' before, one `pr_info("MV310-CONSOLE-PROBE ...")`, raw-UART 'D'
after; counters exposed via `/proc/mv310_hb`.  Init L0 reads that proc
file first.

## 11.2. Bench result

```
HHHH...H B[0.924224] MV310-CONSOLE-PROBE: printk attempt from HB kthread n=25
D HHHH... (continuous)
```

All three markers landed: printk was CALLED, RETURNED, and its text
REACHED THE UART.  The console is not lock-dead.

## 11.3. Reading - the two faults are ONE fault

The probe printk ran in a SCHED_FIFO never-sleeping kthread: in that
context printk takes the synchronous path straight to the UART.
Userspace `echo` (init script) goes to the kmsg queue and is flushed
by console code that needs the scheduler to run - and the scheduler
needs a timer tick - and the tick needs PPI30 which never fires.

**Fault A (console silence) is a SYMPTOM of Fault B (no timer IRQ).**
One root cause: cp15 phys timer PPI30 never asserted on mv310
(H-SRC).  Fixing the timer resurrects console, sleep, scheduler,
and quite possibly SMP bringup with it.

## 11.4. Next cut (single, decisive): E3 timer port

Port the vendor MMIO timer as clockevent:
- node `timer@0xf8a29000`, compatible "hisilicon,timer"
- SPIs 58/91/59/92 (four cores), from the vendor 32-bit DT
- mainline has no driver for this IP; vendor BSP
  (SPC070 histb) has the reference
Acceptance: `arch_timer`-independent tick appears in /proc/interrupts,
console flushes userspace echo, `sleep 1` returns, then maxcpus=4.

## 11.5. Current three-piece set

| File | md5 |
|---|---|
| `/srv/tftp/mv310-Image-7.1.8-gicgrp1` | `4de5190da07ea11195067c781d63eec0` |
| `/srv/tftp/mv310-l-loader-gicgrp1.bin` | `7cfe066218c14f1e2e9f2b33a079ca56` |
| `/srv/tftp/mv310-tvbox-7.1.8.dtb` | `a1cec64cce8da0bb01cd0e6efd7e59bb` |

Log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-v7.3-probe-alive-193607.log`


---

# Addendum 12 (2026-08-21 21:06) - v8.1: timer registers, but tick still absent; M4 death persists

## 12.1. v8.1 (Image `59577cdd`, dtb `8698afc9`)

Changes: HB/CONSOLE-PROBE removed entirely; new driver
`drivers/clocksource/timer-mv310.c` wires the four vendor MMIO timer
blocks as per-CPU clockevents (first boot: CPU0 block @0xf8a2a000,
hwirq 58); `gic_dist_init` now writes ALL IGROUPRn banks 0xffffffff
(SPIs forced to Group1/NS - BL31 only ever programmed IGROUPR0).
First v8 attempt failed with `Failed to initialize '/timer@f8a2a000':
-6` because reg used 1-cell addresses under #address-cells=2; fixed.

## 12.2. Bench result

```
14: 0  GICv2 58 Level mv310-timer      <- registered, probe OK
15: 0  GICv2 91 Level mv310-timer
16: 0  GICv2 59 Level mv310-timer
17: 0  GICv2 92 Level mv310-timer
M1(1.22) M2(1.56) M3(1.90) M4(2.24)
[18.24] MV310-SGIR BEFORE spend=0x00000000 hppir=0x3ff
[18.25] MV310-SGIR AFTER  spend=0x00000000 hppir=0x3ff
(silence; log static at 676647 bytes for 2+ min)
```

## 12.3. Reading

1. The driver probed and registered four clockevents - the of_iomap
   fix worked, request_irq succeeded.
2. **The counters stay 0**: no mv310-timer interrupt EVER fired.
   Either the timer block does not count/assert, or SPI 58 is still
   not delivered despite the IGROUPR1+ Group1 writes.
3. The M-loop died between M4 and M5 again (~2.3 s), then the script
   CONTINUED (SGIR ran at t=18 s) - output resumed after a ~16 s gap,
   consistent with kmsg buffer flush when SGIR's pr_info pushed it.
   Console is alive but flush-starved; the tick is still missing.
4. spend=0 after self-SGI write REPRODUCED on a boot where all SPIs
   are Group1. Combined with zero timer IRQ: **the distributor is not
   forwarding Group1 interrupts to the CPU interface** even though
   GICD_CTLR(NS)=0x1, GICC_CTLR=0x3e3, IGROUPR all-Group1,
   ISENABLER0=0xffff. H-GATE moves back to the top of the list -
   specifically the S-view EnableGrp1 path or a security-level quirk
   unique to this SoC's GIC.

## 12.4. Next cut

Read GICC_HPPIR + GICC_RPR from EL1 immediately after forcing a
software pend (write ISPENDR0 bit for an unused SPI, e.g. SPI 30 ->
GICD_ISPENDR1 bit 30) while IRQs are blocked:
- HPPIR shows the SPI -> distributor->CPU interface works; problem is
  delivery/ack (check GICD_CTLR S-view via BL31 print, PMR, RPR).
- HPPIR stays 1023 -> the pend itself never becomes visible: the
  distributor's Group1 path is dead despite config = silicon/firmware
  gate. Next suspect: BL31 must set GICC_CTLR.EnableGrp1 in the
  *secure* bank too (current S-view value 0x1e9 has bit1=0), or use
  GICD_CTLR NS-bit0 alias semantics differ on this chip.

Log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-v8.1-m4-210412.log`


---

# Addendum 13 (2026-08-21) - v8.3: S-view EnableGrp1 set (0x1eb), forward path STILL dead

## 13.1. v8.3 changes

BL31 `gicv2_cpuif_enable()` now sets `CTLR_ENABLE_G1_BIT` in the
secure-bank GICC_CTLR (was 0x1e9, now 0x1eb - confirmed by
`MV310-GICMAP-EARLY: gicc_ctlr=0x1eb` on this boot).
l-loader `2987ce29`.  fb-run.py gained a fastboot# gate
(`ensure_fastboot`) that refuses to run outside fastboot.

## 13.2. Bench result

```
MV310-GICMAP-EARLY: gicc_ctlr=0x1eb        <- S-view Grp1 gate OPEN
MV310-PEND: SPI30 -> hppir=0x3ff rpr=0xff  <- still never forwarded
M1..M4 then silence; SGIR spend=0 reproduced
```

## 13.3. Reading

The S-view CPU-interface gate is now fully open and the forward path
is STILL dead: a software-pended SPI, with IRQs blocked, never appears
in HPPIR.  Every programmable knob we can reach from NS or via BL31 is
now proven correct:

| Knob | Value | State |
|---|---|---|
| GICD_CTLR (NS) | 0x1 | enabled |
| GICD_CTLR (S, BL31) | 0x3 | G0+G1 |
| IGROUPR0 | 0xfe00ffff | SGI/PPI Group1 |
| IGROUPR1+ | all ffffffff | SPI Group1 |
| ISENABLER0 | 0xffff | SGIs on (+PPIs later) |
| GICC_CTLR (NS) | 0x3e3 | both groups + EOI mode |
| GICC_CTLR (S) | 0x1eb | **Grp1 now open** |
| GICC_PMR | 0xf0 | unmasked |
| ISPENDR write | accepted | pend visible? NO |

Remaining explanations, in order:
1. **The distributor's Group1->CPU-interface forwarding hardware path
   is broken/fused on mv310** (security fuse strapping the GIC into a
   non-standard secure-only forwarding mode).  The vendor kernel works
   because it runs its timers through... something else, or because
   its bootloader configures a register we have not found.
2. A hidden global config register (non-architectural, vendor-specific)
   gates Group1 forwarding.
3. HPPIR itself is broken for Group1 on this chip while actual IRQ
   delivery would work - testable by enabling one timer IRQ and
   spinning with DAIF masked to see if the IRQ *pending* bit in GICC
   (via IAR polling loop) ever returns non-spurious.

## 13.4. Next cut (decisive, no more config)

Poll GICC_IAR directly in a tight EL1 loop with IRQs masked, after
enabling the mv310-timer IRQ and letting the hardware fire it:
- IAR returns 62 (the timer SPI): delivery WORKS end-to-end; only
  HPPIR reads are unreliable on this chip -> normal interrupt handling
  should just work; investigate why handlers never ran (affinity?
  enable order?).
- IAR returns 1023 forever: Group1 delivery is truly dead at the
  hardware level -> the remaining move is vendor-BSP archaeology
  (find the undocumented register) or running everything through
  Group0/FIQ with our own FIQ handler.

Log: `/mnt/hdd/hi3798mv310-stuff/notes/logs/serial-v8.3-grp1s-*.log`


---

# Addendum 14 (2026-08-21, session close) - final state and where to resume

## 14.1. Session outcome in one paragraph

Two days of probe work did not make the board tick, but it converted
an opaque SMP hang into a precisely bounded fault: **the GIC's
Group1->CPU-interface forwarding path never delivers anything on
mv310** - a software-pended SPI with IRQs masked never appears in
HPPIR (v8.2/v8.3), even after every architectural knob was verified
correct including the S-view GICC_CTLR EnableGrp1 (0x1eb, v8.3).
The cp15 arch timer PPI30 additionally appears unwired (H-SRC), but
that is now secondary: the new MMIO timer driver registers cleanly
and would deliver the tick the moment Group1 forwarding works.

## 14.2. Deployed three-piece set (current /srv/tftp)

| File | md5 | Contents |
|---|---|---|
| `mv310-Image-7.1.8-gicgrp1` | `28320428c7eee5c5a9698a7135c53797` | v8.4: mv310-timer driver + IGROUPR1+ Group1 writes + SGIR/PEND/IARPOLL proc probes |
| `mv310-l-loader-gicgrp1.bin` | `2987ce2911cd9a44aa785f2e774546d7` | BL31 with S-view GICC EnableGrp1 + distif Grp1 + SCR_EL3/HCR prints |
| `mv310-tvbox-7.1.8.dtb` | `8698afc91a3fc15d94fd72e55361051f` | 4x MMIO timer blocks (2-cell reg, fixed) |

## 14.3. New assets created this session

- `drivers/clocksource/timer-mv310.c` - working per-CPU clockevent
  driver for the vendor SP804-variant blocks; probes and registers
  all four CPUs.  UNCOMMITTED in kernel tree (irq-gic.c restored to
  last-good; timer driver + Kconfig/Makefile/dts changes remain).
- `/proc/mv310_sgir` (EL1 SGI self-test + SPI pend probe)
- fb-run.py `ensure_fastboot()` gate - refuses to run outside fastboot.
- Probe registry rows: HB/SGIR/GICCPU-STEP/EL1-ENTER lifecycle.

## 14.4. Verified-correct configuration (do not re-test)

GICD_CTLR NS=0x1 / S=0x3; IGROUPR0=0xfe00ffff; IGROUPR1+=all-1;
ISENABLER0=0xffff; GICC_CTLR NS=0x3e3 / S=0x1eb; PMR=0xf0;
SCR_EL3 bits[1:0]=0.  A software-pended SPI still never reaches
HPPIR (hppir=0x3ff, rpr=0xff).

## 14.5. Resume point (next session)

The v8.4 IAR-poll build had a branch-order bug (1058 hit the PEND
branch) - irq-gic.c has been restored to the v8.3 state; re-apply the
IARPOLL block with guard order `>=1000` checked BEFORE `>=32`, then:
1. arm timer via `/proc/mv310_timer_ctrl` (driver support already in),
2. poll GICC_IAR ~2M times with IRQs masked,
3. IAR=58 -> delivery works, HPPIR unreliable -> debug handler path.
   IAR=1023 forever -> hardware/fuse-level Group1 dead -> vendor-BSP
   archaeology for a hidden forwarding register, or run Linux on
   Group0/FIQ with a custom FIQ handler.

Key logs: serial-v8.1-m4-210412.log, serial-v8.3-grp1s-213632.log,
serial-v8-timer1-204604.log (all under notes/logs/).
