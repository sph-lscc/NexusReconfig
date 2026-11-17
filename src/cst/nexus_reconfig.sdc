# NexusReconfig - pre-synthesis constraints (Synplify Pro)
create_clock -name {sys_clk} -period 40 [get_pins {osc0_inst/lscc_osc_inst/gen_osca.u_OSC_A/HFCLKOUT}]
