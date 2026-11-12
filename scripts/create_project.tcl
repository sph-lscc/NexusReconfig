# -----------------------------------------------------------------------------
# Create the NexusReconfig Radiant project in lscc/.
# Run on the build host with Radiant 2026.1.1:
#   radiantc scripts/create_project.tcl        (or pnmainc without a display)
# Deletes and re-creates lscc/nexus_reconfig.rdf and lscc/impl_1; the generated
# oscillator IP in lscc/osc0 is kept.
# -----------------------------------------------------------------------------
set ROOT [file normalize [file join [file dirname [info script]] ..]]
set PRJ  [file join $ROOT lscc]

file delete -force [file join $PRJ nexus_reconfig.rdf] [file join $PRJ impl_1]

prj_create -name nexus_reconfig -dir $PRJ -impl impl_1 \
    -dev LFD2NX-40-8BG196C -performance "8_High-Performance_1.0V" -synthesis synplify

prj_set_impl_opt -impl impl_1 top nexus_reconfig_top
prj_set_impl_opt -impl impl_1 VerilogStandard "System Verilog"

# VHDL-2008 sources, in compile order. The OSC IP stays Verilog (mixed language).
prj_set_strategy_value -strategy Strategy1 syn_vhdl2008=True lse_vhdl2008=True
foreach f {src/nexus_reconfig_pkg.vhd src/uart_tx.vhd src/lmmi_refresh.vhd src/reconfig_core.vhd src/nexus_reconfig_top.vhd} {
    prj_add_source [file join $ROOT $f]
}
prj_add_source [file join $PRJ osc0 osc0.ipx]
prj_add_source [file join $ROOT constraints nexus_reconfig.sdc]
prj_add_source [file join $ROOT constraints nexus_reconfig.pdc]

prj_set_impl_opt -impl impl_1 top nexus_reconfig_top
prj_save
prj_close
