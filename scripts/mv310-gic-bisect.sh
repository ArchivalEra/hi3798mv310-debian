#!/bin/sh
# hi3798mv310 GIC delivery bisect - run from the initramfs (devmem image:
# maxcpus=1, CONFIG_STRICT_DEVMEM off, busybox devmem available).
#
# Goal: decide whether a software-pended SGI reaches the CPU interface.
#   HPPIR shows ID 8  -> GICD->GICC path works, failure is after the
#                        CPU interface (vectors / DAIF / SCR_EL3).
#   HPPIR stays 0x3ff -> the distributor never forwarded it; compare
#                        kernel-runtime vs U-Boot cold-boot register
#                        images (see docs/mv310-gic-bisect-runbook.md).
#
# Correct register offsets (never read 0xf1001104 - that is ISENABLER1):
#   GICD base 0xf1001000:  CTLR +0x0, IGROUPR0 +0x80, ISENABLER0 +0x100,
#                          SPENDSGIR +0xf20 (0xf1001f20)
#   GICC base 0xf1002000:  CTLR +0x0, PMR +0x4, HPPIR +0x18 (0xf1002018)
set -e

DIST=0xf1001000
CPU=0xf1002000
ISEN0=$((DIST + 0x100))
IGROUP=$((DIST + 0x80))
SPENDSGIR=$((DIST + 0xf20))
CPENDSGIR=$((DIST + 0xf00))
CTLR=$DIST
GICC_CTLR=$CPU
PMR=$((CPU + 0x4))
HPPIR=$((CPU + 0x18))

echo "=== MV310-GIC-BISECT START ==="
echo "-- distributor (NS view) --"
printf 'GICD_CTLR     (+0x000) = 0x%08x\n' "$(devmem $CTLR 32)"
printf 'IGROUPR0      (+0x080) = 0x%08x\n' "$(devmem $IGROUP 32)"
printf 'ISENABLER0    (+0x100) = 0x%08x\n' "$(devmem $ISEN0 32)"
echo "-- cpu interface (banked, this CPU) --"
printf 'GICC_CTLR     (+0x000) = 0x%08x\n' "$(devmem $GICC_CTLR 32)"
printf 'GICC_PMR      (+0x004) = 0x%08x\n' "$(devmem $PMR 32)"
printf 'GICC_HPPIR    (+0x018) = 0x%08x\n' "$(devmem $HPPIR 32)"

echo "-- pend self SGI 8 (GICD_SPENDSGIR=0x100) --"
devmem $SPENDSGIR 32 0x100
sleep 2
echo "-- after 2s --"
printf 'GICD_SPENDSGIR(+0xf20) = 0x%08x\n' "$(devmem $SPENDSGIR 32)"
printf 'GICC_HPPIR    (+0x018) = 0x%08x\n' "$(devmem $HPPIR 32)"

HPPIR_VAL=$(devmem $HPPIR 32)
if [ "$HPPIR_VAL" = "0x000003FF" ] || [ "$HPPIR_VAL" = "0x000003ff" ]; then
    echo "RESULT: SGI NOT pending at CPU interface (HPPIR=0x3ff)."
    echo "  -> distributor never forwarded it. Compare kernel-runtime vs U-Boot cold values."
    echo "  -> See runbook Step 2."
else
    echo "RESULT: SGI 8 reached the CPU interface (HPPIR=$HPPIR_VAL)."
    echo "  -> GICD->GICC works. Failure is after the CPU interface:"
    echo "     check SCR_EL3 (BL31 MV310 line, bits 3:1 must be 0) and DAIF/VBAR."
fi

# clear the pending SGI (best effort, ignore errors)
devmem $CPENDSGIR 32 0x100 || true
echo "=== MV310-GIC-BISECT END ==="
