# -----------------------------------------------------------------------------
# Build both implementations of the NexusReconfig project (lscc/):
#   impl_sv    -> lscc/impl_sv/nexus_reconfig_impl_sv.bit
#   impl_vhdl  -> lscc/impl_vhdl/nexus_reconfig_impl_vhdl.bit
# Run on the build host with Radiant 2026.1.1:
#   radiantc scripts/build_all.tcl
# or through the lattice-prompt MCP: radiant_build_detached(tcl_path=<this file>).
# The prj_run_* commands act on the active implementation only, so each one is
# activated in turn; impl_sv is left active (the project default).
# -----------------------------------------------------------------------------
set ROOT [file normalize [file join [file dirname [info script]] ..]]

prj_open [file join $ROOT lscc nexus_reconfig.rdf]
foreach impl {impl_sv impl_vhdl} {
    prj_activate_impl $impl
    prj_run_synthesis -forceOne
    prj_run_map
    prj_run_par
    prj_run_bitstream
}
prj_activate_impl impl_sv
prj_save
prj_close
