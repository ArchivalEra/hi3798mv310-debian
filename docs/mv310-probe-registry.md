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

### ATF side (EL3)

| ID | Location | Fires | Reading | Status | Retire when |
|---|---|---|---|---|---|
| `MV310-BL31-GICD` | gicv2_distif_init tail | once per cold boot | S-view GICD_CTLR (`ctlr=0x3` = G0\|G1 open). Sentinel for the S-view state | SENTINEL | end of investigation |
| `MV310-CPUON-entry` / `-spinlock` / `-validated` / `-pwr_domain_on` / `-cm_init` / `-unlocked` | lib/psci/psci_on.c | once per CPU_ON | which stage of the CPU_ON path ran | DEGRADING: 6 lines spam; E1 trims to entry+unlocked (2) | CPU_ON path adjudicated |
| `MV310-GIC-on_finish` / `-on_finish-after` | plat/hisilicon/hi3798mv2x/plat_pm.c | once per secondary power-up | `after` printed = TF-A's banked writes on the secondary completed ⇒ wedge is in the kernel sequence; absent ⇒ wedge inside TF-A's gicv2_pcpu_distif_init | ACTIVE (this is the §8.4 E1.4 discriminator) | CPU1 death adjudicated |

### Retired

| ID | Why it existed | Retire note |
|---|---|---|
| `MV310-MAIN` / `MV310-HP` | hotplug-thread state on CPU0 (031546 era) | conclusion reached; removed from source; lives only in old logs |
| `MV310-IRQ` (old name) | after-IAR hit counter | renamed to `MV310-IRQ-IAR` (the old name would collide with the pre-IAR probe) |

### EL0-forbidden MMIO (never in an init script / devmem)

| Offset | Register | Why |
|---|---|---|
| `0xF1001100` | ISENABLER0 | historically fatal from EL0 (v3/v4); safe from EL1 (GICMAP probe) |
| `0xF1001C00` | ICFGR0 | historically fatal from EL0 (v5b) |
| `0xF1001300` | ISACTIVER0 | v3 death site (later retracted, still off-limits) |

EL0-safe set (proven, 031546): `0xF1001000`, `0xF1001080`, `0xF1001104`,
`0xF1001200`, all GICC (`0xF1002xxx`).  EL0 and EL1 access to the SAME
offset are NOT equivalent — never cross-apply a safety conclusion.

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

## 4. Open actions (before the next build)

1. **Trim `MV310-CPUON-*` from 6 lines to 2** (keep `entry` + `unlocked`).
2. **Register the new E1 probes**: `HB` (raw-UART heartbeat — NOT printk,
   no registry row possible in code, but document it here) and
   `GICCPU-STEP [CI-1..CI-7]` (per-MMIO-group markers in gic_cpu_init for
   the secondary path; low rate — once per CPU — so bare prints are fine).
3. **Freeze the GICMAP format**: it is the EL1-sanctioned ISENABLER0 reader
   and the §6 checklist reference; no more format drift.

## 5. Relationship to the three-piece deployment

Each deployment = Image / l-loader / dtb md5s + a probe-set version
(string, e.g. `probes-v6-e1`), bound in the changelog.  Log filenames carry
the probe-set tag; the registry is the single source of truth for what any
log's `MV310-*` lines mean.
