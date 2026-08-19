#!/bin/sh
# hi3798mv310 "write SGIR -> hang" layer bisect - no-sleep revision.
#
# 2026-08-19 expert review found the old initramfs test was followed by
# `sleep 1`, and this kernel receives zero interrupts the whole boot, so
# nanosleep never wakes: serial silence after STEP1 was NOT proof of a hang.
# This ladder contains no sleep before the final sanity step, so every
# "the next line printed" observation is real evidence.
#
# Same register discipline as scripts/mv310-gic-bisect.sh:
#   GICD 0xf1001000: CTLR +0x0, IGROUPR0 +0x80, ISENABLER0 +0x100,
#                    ISACTIVER0 +0x300, IPRIORITYR0 +0x400, SGIR +0xf00,
#                    CPENDSGIR0 +0xf10, SPENDSGIR0 +0xf20
#   GICC 0xf1002000: CTLR +0x0, PMR +0x4, HPPIR +0x18
#
# Decision matrix (last marker seen == the step that killed the box):
#   E0 (SGIR no-op write) dies   -> SGIR offset poisoned for NS writes
#   E1 (no-target SGIR) dies     -> SGIR write stalls the bus; delivery
#                                   question is moot until that is understood
#   E1 lives, E2b (PMR-masked
#     self-SGI) dies             -> the pend itself kills (GIC-internal)
#   E2b lives + SPENDSGIR0 bit0=1 (printed proof the pend registered),
#   E2c (prio restore) dies      -> delivery itself kills: write mechanics
#                                   and pend state are innocent
#   everything lives, HPPIR=0x0  -> SGI0 pending AND signalable but never
#     taken: fault sits at the CPU side (DAIF / VBAR / HCR_EL2 routing);
#     run the kernel entry probes (docs/mv310-board-handoff.md addendum 3)
#   everything lives incl. R    -> the original "STEP1 hang" was the sleep;
#                                   retract handoff finding A4
#   S prints POST-SLEEP-LIVE     -> timer IRQs actually work; re-examine the
#                                   whole zero-interrupt premise
#
# Deployed as builds/initramfs/init (CONFIG_INITRAMFS_SOURCE); after editing,
# re-link the Image (make Image in the kernel tree) and re-stage via fb-run.

echo "=== MV310-GIC-LADDER START (no-sleep revision) ==="

echo "--- L1: baseline registers (CPU0, NS view) ---"
echo "GICD_CTLR    (0xF1001000): $(devmem 0xF1001000)"
echo "GICC_CTLR    (0xF1002000): $(devmem 0xF1002000)"
echo "GICC_PMR     (0xF1002004): $(devmem 0xF1002004)"
echo "IGROUPR0     (0xF1001080): $(devmem 0xF1001080)"
echo "ISENABLER0   (0xF1001100): $(devmem 0xF1001100)"
echo "ISACTIVER0   (0xF1001300): $(devmem 0xF1001300)"
echo "SPENDSGIR0   (0xF1001F20): $(devmem 0xF1001F20)"
echo "GICC_HPPIR   (0xF1002018): $(devmem 0xF1002018)"
BASE_PRIO=$(devmem 0xF1001400 8)
echo "IPRIORITYR0.b0 SGI0 (0xF1001400): $BASE_PRIO"

echo "--- E0: SGIR no-op write (empty target list) ---"
echo "E0-MARKER-BEFORE"
devmem 0xF1001F00 32 0x00000000 || echo "E0 devmem FAILED rc=$?"
echo "E0-SURVIVED"

echo "--- E1: SGIR no-target (filter=01 all-but-self, nobody else alive) ---"
echo "E1-MARKER-BEFORE"
devmem 0xF1001F00 32 0x01000000 || echo "E1 devmem FAILED rc=$?"
echo "E1-SURVIVED -> SGIR write path clean, only delivery can kill"

echo "--- E2a: SGI0 priority 0xFF (above PMR 0xF0, unsignalable) ---"
devmem 0xF1001400 8 0xFF || echo "E2a devmem FAILED rc=$?"
echo "E2a prio readback: $(devmem 0xF1001400 8)"

echo "--- E2b: self SGI0 while PMR-masked ---"
echo "E2b-MARKER-BEFORE"
devmem 0xF1001F00 32 0x00010000 || echo "E2b devmem FAILED rc=$?"
echo "E2b-SURVIVED"
echo "SPENDSGIR0   (0xF1001F20): $(devmem 0xF1001F20)"
echo "GICC_HPPIR   (0xF1002018): $(devmem 0xF1002018)"

echo "--- E2c: restore SGI0 prio ($BASE_PRIO), signaling now legal ---"
echo "E2c-MARKER-BEFORE"
devmem 0xF1001400 8 $BASE_PRIO || echo "E2c devmem FAILED rc=$?"
echo "E2c-SURVIVED"
echo "GICC_HPPIR   (0xF1002018): $(devmem 0xF1002018)"
echo "SPENDSGIR0   (0xF1001F20): $(devmem 0xF1001F20)"

echo "--- E1b: positive control, SGIR filter=10 self-only ---"
echo "E1b-MARKER-BEFORE"
devmem 0xF1001F00 32 0x02000000 || echo "E1b devmem FAILED rc=$?"
echo "E1b-SURVIVED"

echo "--- R: verbatim replay of the original STEP1 ---"
echo "R-MARKER-BEFORE"
devmem 0xF1001F00 32 0x00010000 || echo "R devmem FAILED rc=$?"
echo "R-SURVIVED -> the original STEP1 hang was the sleep (retract A4)"
echo "GICC_HPPIR   (0xF1002018): $(devmem 0xF1002018)"

echo "--- counters ---"
echo "MV310-IRQ count: $(dmesg | grep -c 'MV310-IRQ')"
echo "=== LADDER BODY COMPLETE ==="

echo "--- S: sleep sanity, last (may never return) ---"
echo "S-PRE-SLEEP"
sleep 2
echo "S-POST-SLEEP-LIVE  <-- timer IRQs work if you can read this"
