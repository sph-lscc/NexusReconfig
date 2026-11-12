#!/bin/sh
# -----------------------------------------------------------------------------
# Extract the original SystemVerilog sources from git as the reference for the
# VHDL-2008 conversion checks. Writes to sim/mcp_sim/sv_ref/ (not versioned):
#   orig/*.sv  unchanged copies, for tb_reconfig_core against the reference
#   ref_*.sv   module names prefixed with ref_, for the lock-step tb_equiv
# Usage: scripts/make_sv_ref.sh [commit]   (default 41439d8, last SystemVerilog
#        version on main)
# -----------------------------------------------------------------------------
set -eu
REF=${1:-41439d8}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/sim/mcp_sim/sv_ref
rm -rf "$OUT"
mkdir -p "$OUT/orig"
for m in uart_tx lmmi_refresh reconfig_core; do
    git -C "$ROOT" show "$REF:src/$m.sv" > "$OUT/orig/$m.sv"
    sed -E 's/\b(reconfig_core|lmmi_refresh|uart_tx)\b/ref_\1/g' "$OUT/orig/$m.sv" > "$OUT/ref_$m.sv"
done
echo "SystemVerilog reference from $REF written to $OUT"
