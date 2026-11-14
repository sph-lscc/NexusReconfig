# -----------------------------------------------------------------------------
# Create the NexusReconfig Radiant project in lscc/ with two implementations of
# the same design, sharing the device, strategy, oscillator IP and constraints:
#   impl_sv    SystemVerilog sources in src/sv/   (default implementation)
#   impl_vhdl  VHDL-2008 sources in src/vhdl/     (the OSC IP stays Verilog)
# Run on the build host with Radiant 2026.1.1:
#   radiantc scripts/create_project.tcl        (or pnmainc without a display)
# Deletes and re-creates lscc/nexus_reconfig.rdf and the implementation
# folders; the generated oscillator IP in lscc/osc0 is kept.
# -----------------------------------------------------------------------------
set ROOT [file normalize [file join [file dirname [info script]] ..]]
set PRJ  [file join $ROOT lscc]

file delete -force [file join $PRJ nexus_reconfig.rdf] \
    [file join $PRJ impl_1] [file join $PRJ impl_sv] [file join $PRJ impl_vhdl]

prj_create -name nexus_reconfig -dir $PRJ -impl impl_sv \
    -dev LFD2NX-40-8BG196C -performance "8_High-Performance_1.0V" -synthesis synplify
prj_create_impl impl_vhdl -dir impl_vhdl -strategy Strategy1 -synthesis synplify

# One strategy for both implementations. The VHDL-2008 switches do not affect
# the SystemVerilog synthesis.
prj_set_strategy_value -strategy Strategy1 syn_vhdl2008=True lse_vhdl2008=True

set SOURCES(impl_sv)   {src/sv/uart_tx.sv src/sv/lmmi_refresh.sv src/sv/reconfig_core.sv
                        src/sv/nexus_reconfig_top.sv}
set SOURCES(impl_vhdl) {src/vhdl/nexus_reconfig_pkg.vhd src/vhdl/uart_tx.vhd
                        src/vhdl/lmmi_refresh.vhd src/vhdl/reconfig_core.vhd
                        src/vhdl/nexus_reconfig_top.vhd}

foreach impl {impl_sv impl_vhdl} {
    # Design sources in compile order, then the shared IP and constraints.
    foreach f $SOURCES($impl) {
        prj_add_source -impl $impl [file join $ROOT $f]
    }
    prj_add_source -impl $impl [file join $PRJ osc0 osc0.ipx]
    prj_add_source -impl $impl [file join $ROOT constraints nexus_reconfig.sdc]
    prj_add_source -impl $impl [file join $ROOT constraints nexus_reconfig.pdc]
    prj_set_impl_opt -impl $impl top nexus_reconfig_top
    prj_set_impl_opt -impl $impl VerilogStandard "System Verilog"
}

prj_activate_impl impl_sv
prj_save
prj_close
