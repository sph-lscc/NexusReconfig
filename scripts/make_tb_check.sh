#!/bin/sh
# -----------------------------------------------------------------------------
# Prepare the fault-injection check of the VHDL testbench conversion.
# Writes to sim/mcp_sim/tb_check/ (not versioned):
#   tb_reconfig_core.sv   SystemVerilog testbench of commit 358c619
#   <m>/*.vhd             copy of src/*.vhd with one injected fault
#   <m>_vhdtb.f           VHDL testbench (tb/tb_reconfig_core.vhd) on mutant <m>
#   <m>_svtb.f            SystemVerilog testbench on mutant <m>
# Both testbenches must report TEST FAILED on every mutant, with the same checks.
# Usage: scripts/make_tb_check.sh [commit of the SystemVerilog testbench]
# -----------------------------------------------------------------------------
set -eu
REF=${1:-358c619}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/sim/mcp_sim/tb_check
rm -rf "$OUT"
mkdir -p "$OUT"
git -C "$ROOT" show "$REF:tb/tb_reconfig_core.sv" > "$OUT/tb_reconfig_core.sv"

# mutant  file  sed expression
mutate() {
    m=$1; f=$2; expr=$3
    mkdir -p "$OUT/$m"
    cp "$ROOT"/src/nexus_reconfig_pkg.vhd "$ROOT"/src/uart_tx.vhd \
       "$ROOT"/src/lmmi_refresh.vhd "$ROOT"/src/reconfig_core.vhd "$OUT/$m/"
    sed -i -E "$expr" "$OUT/$m/$f"
    if cmp -s "$ROOT/src/$f" "$OUT/$m/$f"; then
        echo "mutation $m did not change $f" >&2; exit 1
    fi
    for tb in vhdtb svtb; do
        {
            echo "-vcom.options -2008 -end"
            echo "-do $ROOT/sim/run_vhdl.do"
            for s in nexus_reconfig_pkg uart_tx lmmi_refresh reconfig_core; do echo "$OUT/$m/$s.vhd"; done
            if [ $tb = vhdtb ]; then echo "$ROOT/tb/tb_reconfig_core.vhd"; else echo "$OUT/tb_reconfig_core.sv"; fi
        } > "$OUT/${m}_$tb.f"
    done
}
mutate m1_opcode   lmmi_refresh.vhd  's/(LSC_REFRESH : std_logic_vector\(7 downto 0\) := )x"79"/\1x"78"/'
mutate m2_offset   lmmi_refresh.vhd  's/(ADDR_CFG    : std_logic_vector\(7 downto 0\) := )x"01"/\1x"02"/'
mutate m3_nodrain  reconfig_core.vhd 's/elsif tx_ready = .1. then/else/'
mutate m4_bootled  reconfig_core.vhd "s/boot_led <= '1' when/boot_led <= '0' when/"
echo "Fault-injection check prepared in $OUT"
