#!/bin/sh
# -----------------------------------------------------------------------------
# Prepare the SystemVerilog side of the lock-step equivalence check
# (tb/tb_equiv.sv). Both implementations use the same module and entity names,
# so the SystemVerilog copies get a ref_ prefix to share one library with the
# VHDL-2008 design. Writes sim/mcp_sim/sv_ref/ref_*.sv (not versioned).
# Usage: scripts/make_sv_ref.sh
# -----------------------------------------------------------------------------
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/sim/mcp_sim/sv_ref
rm -rf "$OUT"
mkdir -p "$OUT"
for m in uart_tx lmmi_refresh reconfig_core; do
    sed -E 's/\b(reconfig_core|lmmi_refresh|uart_tx)\b/ref_\1/g' "$ROOT/src/sv/$m.sv" > "$OUT/ref_$m.sv"
done
echo "SystemVerilog sources with ref_ prefix written to $OUT"
