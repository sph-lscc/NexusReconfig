# NexusReconfig - Certus-NX reconfiguration from internal logic

| Info: | Details |
| :-- | :-- |
| Device | Certus-NX LFD2NX-40-8BG196C |
| Board | CRUVI Certus-NX board |
| Software | Radiant 2026.1.1 (Synplify Pro), Questa (bundled with Radiant) |
| HDL | VHDL-2008 (branch `vhdl-2008`), including the main testbench; `tb_equiv` SystemVerilog; OSC IP Verilog |
| IP | osc 1.4.0 (`lscc/osc0`) |

## Notes

- This reference design shows how user logic inside a Certus-NX FPGA can force the device to
  reconfigure itself, with no external pin (PROGRAMN), JTAG cable or host involved.
- The design writes the `LSC_REFRESH` command (opcode `0x79`) to the device's configuration block
  through the `CONFIG_LMMI` primitive. `LSC_REFRESH` is equivalent to toggling PROGRAMN: the
  configuration SRAM is cleared and the bitstream is reloaded from the boot source, which on
  Certus-NX is the external SPI flash.
- The reconfiguration therefore loads **whatever image is in the SPI flash**. To see this design
  restart itself, its bitstream must be in the flash (see "Running on the board").

- This branch (`vhdl-2008`) holds the design converted to VHDL-2008. The SystemVerilog original
  is on `main` (last SystemVerilog commit `41439d8`). The conversion is checked against the
  original cycle by cycle in simulation (see "VHDL-2008 conversion").

## How it works

![NexusReconfig block diagram](docs/block_diagram.svg)

1. After configuration a power-on counter releases the logic. The UART prints
   `NexusReconfig: FPGA configured`, `led_o[0]` lights for 2 s (a fresh-configuration indicator)
   and `led_o[1]` blinks at 2 Hz.
2. A reconfiguration request comes from either:
   - a press on the active-low input `btn_ni` (pin B2), debounced for 20 ms. The input must be
     seen released before a press counts, so a stuck-low input cannot cause a refresh loop; or
   - the auto-refresh timer, 10 s after the banner (`AUTO_REFRESH_MS`, 0 disables it).
3. The UART prints `NexusReconfig: issuing LSC_REFRESH`. When the last character has left the
   UART, `lmmi_refresh` waits for 16 consecutive cycles with `LMMIREADY` high, then writes the
   four bytes `79 00 00 00` (opcode and three operands) to LMMI offset `0x01`.
4. The device reconfigures and the sequence starts again at step 1.
5. If the device is still running after the command, the refresh was not executed and
   `led_o[0]` flashes quickly (64 ms) as a failure indicator.

### LMMI protocol

From the sysCONFIG User Guide for Nexus Platform, FPGA-TN-02099-3.7, Appendix D:

- The configuration register has the fixed LMMI offset `ADDR_CFG = 0x01` (D.3).
- A command is an opcode byte and three operand bytes, written back to back with
  `LMMIREQUEST` and `LMMIWRRD_N` high; a byte is taken on each clock edge where `LMMIREADY` is
  high (Figures D.4 to D.6).
- `LSC_REFRESH` is the only Class D command and is executed as a Class C command (no data, no
  read-back). Once it executes, the LMMI host in the fabric no longer exists (D.3).
- `OPERAND1 = 0x00` leaves the Override ENABLE bit (bit 6) clear, so the refresh uses the
  device's normal boot settings (Table 6.20).
- Wait at least four LMMI clock cycles after `LMMIREADY` is high before issuing a command (D.3).
- `LMMICLK` is at most 50 MHz (Table D.1). `LMMICLK` and `LMMIRESETN` must come from the OSC IP's
  `lmmi_clk_o` / `lmmi_resetn_o` pass-through outputs, or the software stops with an error (D.2).
  The OSC IP is generated with `LMMI_CLK_EN = ENABLED`.
- `RSTSMCLK` and `SMCLK` are hardware inferred and left unconnected, as in FPGA-RD-02294.

The command sequence is the `LSC_REFRESH` step of the refresh controller in the Lattice Nexus
Multi-Boot reference design FPGA-RD-02294 (`source/impl_1/refresh.v`), without its Multi-Boot steps
(`ISC_ENABLE_X`, `LSC_PROG_CNTRL0`, `ISC_DISABLE` and the `MULTIBOOT` primitive), which are only
needed to select an alternate image.

## Contents

| Path | Content |
| :-- | :-- |
| `src/nexus_reconfig_top.vhd` | Top level: OSC IP, `CONFIG_LMMI` primitive, `reconfig_core` |
| `src/reconfig_core.vhd` | Power-on reset, button debounce, auto timer, UART messages, LEDs, sequencer |
| `src/lmmi_refresh.vhd` | LMMI host that writes `LSC_REFRESH` |
| `src/uart_tx.vhd` | UART transmitter, 8N1 |
| `src/nexus_reconfig_pkg.vhd` | `clog2` and string-to-ROM helper functions |
| `lscc/osc0/` | Generated OSC IP (25 MHz HF clock, LMMI clock path enabled) |
| `lscc/nexus_reconfig.rdf` | Radiant project, implementation `impl_1` |
| `constraints/nexus_reconfig.pdc` | Clock, pins, INITN release, false paths (post-synthesis) |
| `constraints/nexus_reconfig.sdc` | Clock for synthesis |
| `tb/tb_reconfig_core.vhd` | Self-checking VHDL-2008 testbench with an LMMI target model and UART monitors (ports only, component binding: runs against the VHDL design or the SystemVerilog original) |
| `tb/tb_equiv.sv` | Lock-step equivalence testbench: VHDL against the SystemVerilog original |
| `sim/sim_filelist.f` | Simulation file list, VHDL design with `tb_reconfig_core` |
| `sim/sim_svref_filelist.f` | `tb_reconfig_core` with the SystemVerilog original |
| `sim/equiv_filelist.f` | `tb_equiv` with both implementations |
| `sim/lint_top_filelist.f` | File list for the elaborate-only check of the full top level |
| `sim/run_vhdl.do` | Questa run script for the VHDL simulations |
| `scripts/create_project.tcl` | Re-creates the Radiant project (VHDL-2008 enabled for Synplify Pro and LSE) |
| `scripts/make_sv_ref.sh` | Extracts the SystemVerilog original from git into `sim/mcp_sim/sv_ref/` |
| `scripts/make_tb_check.sh` | Prepares the fault-injection check of the testbench conversion in `sim/mcp_sim/tb_check/` |
| `docs/` | FPGA-TN-02099 (sysCONFIG) and FPGA-TN-02145 (Multi-Boot) user guides, block diagram (`block_diagram.svg`) |

### Ports and pins

| Port | Pin | Direction | Function |
| :-- | :-- | :-- | :-- |
| `btn_ni` | B2 | in, pull-up | Reconfiguration request, active low |
| `led_o[0]` | A8 | out | On for 2 s after configuration; fast flash if the refresh did not execute |
| `led_o[1]` | B8 | out | 2 Hz heartbeat |
| `txd_o` | F11 | out | UART, 115200 baud, 8N1 |

Pins come from the CRUVI board design
(`/mnt/lscc/devel/Boards/CertusNX/cruvi/CruviDemo/test_certus/test_certus.pdc`). B2 is the INITN
sysCONFIG pin; like the CRUVI design, the `.pdc` releases it with
`ldc_set_sysconfig {INITN_PORT=DISABLE}`.

### Parameters (`nexus_reconfig_top`)

| Parameter | Default | Meaning |
| :-- | :-- | :-- |
| `AUTO_REFRESH_MS` | 10000 | Auto-refresh delay after the banner; 0 = button only |
| `LED_ACTIVE_LOW` | `false` | Set to `true` if the board LEDs light on a low level (VHDL `boolean`) |

## Reproducing the results

All Lattice tools run on the build host `lb` with Radiant 2026.1.1, through the `lattice-prompt`
MCP server.

1. **Oscillator IP** (already in `lscc/osc0`; only needed to regenerate it):
   `radiant_ip_generate(name=osc0, ip_module_dir=/mnt/tools/lscc/radiant/2026.1.1/ip/lifcl/osc,
   device=LFD2NX-40, family=LFD2NX, package=CABGA196, performance=8_High-Performance_1.0V,
   operation=Commercial, output_dir=<project>/lscc/osc0,
   cfg_values="HF_OSC_EN:ENABLED; HF_CLK_FREQ:25; LF_OUTPUT_EN:DISABLED; SEDCLK_EN:0; LMMI_CLK_EN:ENABLED")`.
2. **Project** (already in `lscc/nexus_reconfig.rdf`; only needed to re-create it):
   `radiant_build_detached(tcl_path=<project>/scripts/create_project.tcl)`. The tool reports
   `failed` because no build stage runs; check that `lscc/nexus_reconfig.rdf` exists.
3. **Build:** `radiant_build_detached(rdf_path=<project>/lscc/nexus_reconfig.rdf, impl=impl_1)`,
   `radiant_build_wait`, then `validate_timing(project_path=<project>/lscc)`. The bitstream is
   `lscc/impl_1/nexus_reconfig_impl_1.bit`.
4. **SystemVerilog reference** (needed for steps 6 and 7): run `scripts/make_sv_ref.sh` in WSL
   or on `lb`. It writes the original sources of commit `41439d8` to `sim/mcp_sim/sv_ref/`.
5. **RTL simulation of the VHDL design:**
   `simulate_rtl_detached(work_dir=<project>/sim/mcp_sim/vhdl, sim_dir=<project>/sim/mcp_sim/vhdl/system_sim,
   device=LFD2NX-40-8BG196C, sim_filelist=<project>/sim/sim_filelist.f, top=tb_reconfig_core,
   libdirs=[/mnt/tools/lscc/radiant/2026.1.1/cae_library/simulation/verilog/uaplatform],
   skip_validate=true, clean=true)`, then `simulate_rtl_wait`. Pass criterion: `TEST PASSED` in
   `sim.log`.
6. **Equivalence with the SystemVerilog original:** as step 5 with
   `sim_filelist=<project>/sim/equiv_filelist.f`, `top=tb_equiv` and its own `work_dir`/`sim_dir`
   (`sim/mcp_sim/equiv`). Pass criterion: `TEST PASSED: VHDL-2008 conversion matches ...`.
7. **Same testbench on the SystemVerilog original:** as step 5 with
   `sim_filelist=<project>/sim/sim_svref_filelist.f` (`sim/mcp_sim/svref`). The file list passes
   `-t 1ps` to `vsim` because the VHDL top level instantiates Verilog modules.
8. **Fault-injection check of the testbench conversion:** run `scripts/make_tb_check.sh`, then
   for each `sim/mcp_sim/tb_check/<m>_vhdtb.f` and `<m>_svtb.f` run as step 5 with that file list
   and its own `work_dir`/`sim_dir` (for example `sim/mcp_sim/tb_check/run_<m>_<tb>`, no
   `libdirs`). See "Testbench conversion" for the expected results.
9. **Full top-level elaboration** (with the OSCA, CONFIG_CLKRST_CORE and CONFIG_LMMI library
   cells): as step 5 with `sim_filelist=<project>/sim/lint_top_filelist.f`,
   `top=nexus_reconfig_top`, `sim_dir=<project>/sim/mcp_sim/lint/system_sim` and
   `elaborate_only=true`. The file list passes `-t 1ps` to `vsim`: with a VHDL top level the
   default resolution is 1 ns, and the Lattice Verilog cells need 1 ps (`vsim-3693`).

The VHDL file lists compile with `-vcom.options -2008 -end` and run `sim/run_vhdl.do`. That
script suppresses numeric_std metavalue warnings for the time-0 delta cycles only: registers
without a reset value are `'U'` until the power-on reset clears them (X in the SystemVerilog
original), and numeric_std reports this once when the concurrent statements are first evaluated.
Warnings after time 0 are still reported.

## Verification results (2026-11-12, Radiant 2026.1.1, VHDL-2008)

| Check | Result |
| :-- | :-- |
| RTL simulation, VHDL design, VHDL testbench (`tb_reconfig_core`) | `TEST PASSED`, 12 checks, 0 errors, 0 warnings |
| Equivalence with the SystemVerilog original (`tb_equiv`) | `TEST PASSED`: 4 parameter sets, about 300 000 cycles each, 0 output mismatches, 0 warnings |
| Same VHDL testbench on the SystemVerilog original | `TEST PASSED`, 0 errors, 0 warnings |
| Fault injection: VHDL and SystemVerilog testbench on 4 mutants | Identical results on every mutant (see "Testbench conversion") |
| Elaborate-only, full top level with device library cells | 0 errors, 2 warnings, both `vopt-2958 Implicit wire '<protected>'` from inside the encrypted Lattice library cells |
| Timing (`validate_timing`) | Met at all corners: 0 failing endpoints, constraint coverage 100 % |
| Worst setup slack, `sys_clk` 25 MHz | +36.072 ns (85 °C), so the logic Fmax is about 254 MHz |
| Worst hold slack | +0.190 ns |
| Resources | 211 LUT4, 123 registers, 1 EBR (message ROM), 1 OSC, 1 CONFIG_LMMI, 4 I/O |
| `CONFIG_LMMI` in the synthesised netlist | Same connections as the SystemVerilog build (`RSTSMCLK`, `SMCLK` tied to GND by synthesis in both) |
| Hardware | **Not yet tested on the board** |

The SystemVerilog original (`main`, commit `41439d8`) gave 216 LUT4, 123 registers, 2 EBR,
setup slack +35.901 ns and hold slack +0.155 ns. The differences come from synthesis packing the
two message ROMs differently, not from a change in function.

### Testbench conversion

`tb/tb_reconfig_core.vhd` replaces the SystemVerilog `tb_reconfig_core.sv` (last version in commit
`358c619`). It has the same three DUT instances, stimulus, LMMI target model, UART monitors, the
same 12 final checks and the same checks during the run. Differences:

- The LMMI back-pressure uses `ieee.math_real.uniform` instead of `$urandom`, so the ready pattern,
  and with it the time of each LMMI byte, differs from the SystemVerilog run. The event log times
  of the UART messages differ by up to 2 us because the VHDL monitor reports through signals.
- The DUT is bound through a component declaration, so the same testbench runs against the VHDL
  entity and the SystemVerilog module.

Fault injection (`scripts/make_tb_check.sh`): each mutant is a copy of `src/*.vhd` with one fault.
Both testbenches were run on every mutant (2026-11-13):

| Mutant | Fault | VHDL testbench | SystemVerilog testbench |
| :-- | :-- | :-- | :-- |
| `m1_opcode` | Opcode `0x78` instead of `0x79` | FAILED, 2 errors (A, B: `LSC_REFRESH 79 00 00 00 written`) | Same 2 errors |
| `m2_offset` | LMMI offset `0x02` instead of `0x01` | FAILED, 8 errors (offset error on every byte) | Same 8 errors |
| `m3_nodrain` | Refresh starts without waiting for the last UART character | PASSED (not detected) | PASSED (not detected) |
| `m4_bootled` | Boot LED never on | FAILED, 1 error (A: `boot LED not on at 1 ms`) | Same 1 error |

`m3_nodrain` is a coverage gap of the original testbench, not of the conversion: with about one
cycle in three of `LMMIREADY` low, `lmmi_refresh` needs about 2 ms to see 16 consecutive ready
cycles, so the last character (200 us at 50 kbaud) has always left the UART before the first LMMI
request, and the check "LMMI request before the UART message completed" cannot fire.

### VHDL-2008 conversion

- One VHDL entity per SystemVerilog module, with the same names, generics and ports. The
  generics are `positive`/`natural`, apart from `LED_ACTIVE_LOW` (`boolean`). The ports are
  `std_logic` / `std_logic_vector`. The SystemVerilog `$clog2` and the packed message strings are
  replaced by `clog2` and `to_rom` in `nexus_reconfig_pkg`.
- `nexus_reconfig_top.vhd` declares the OSC IP (Verilog, mixed-language) and `CONFIG_LMMI` as
  components. The `CONFIG_LMMI` declaration is copied from the Radiant library
  (`cae_library/synthesis/vhdl/lfd2nx.vhd`). A local declaration is used because the
  precompiled Questa library `lfd2nx` holds only the Verilog cells, not a VHDL `components`
  package.
- `tb_equiv` runs the original SystemVerilog modules (renamed `ref_*`) and the VHDL entities
  side by side with identical stimulus. It compares `rst_no` from time 0 and all outputs
  (`led_o`, `txd_o`, `lmmi_*`, `refresh_done_o`) on every clock from the release of the
  power-on reset. Before that release the SystemVerilog registers are X and the VHDL
  enumerated state registers start at their leftmost value; on the device every register is
  cleared at configuration. The parameter sets are:
  - **P0:** auto-refresh timer, button released, random `LMMIREADY` back-pressure.
  - **P1:** button only, active-low LEDs. The input is stuck low at start, then:
    - bouncing release;
    - a 1 ms glitch shorter than the debounce time;
    - bouncing press.
  - **P2:** button stuck low, timer disabled. No `LMMI` transfer is allowed, and none occurs.
  - **P3:** 115200 baud at 1 MHz (divider 9), LMMI gap 4, random button noise, long
    `LMMIREADY` stretches.

  The test also fails if the stimulus did not exercise all of the following:
  - the refresh;
  - the four LMMI bytes;
  - UART output;
  - the boot, failure and heartbeat LED patterns.

What the testbench covers, with three DUT instances on a scaled clock (1 MHz, 50 kbaud):

- auto-refresh trigger: banner, refresh message, exactly `79 00 00 00` to offset `0x01`, no
  transfer before the UART message has completed, at least four `LMMIREADY` cycles before the
  command, random `LMMIREADY` back-pressure, failure flash when the model does not reconfigure;
- button trigger with the timer disabled: the same sequence;
- button stuck low with the timer disabled: banner only, no LMMI transfer.

What it does not cover:

- `CONFIG_LMMI` itself. Lattice supplies no supported simulation model (FPGA-TN-02099 Table D.1,
  note 1), so the testbench uses a behavioural model of the documented write protocol. Whether
  the silicon executes the refresh can only be shown on hardware.
- The thin top level (`nexus_reconfig_top`, OSC IP wiring). It is checked by elaboration with the
  library cells, by synthesis, and by place and route, but not simulated.

### Known build warnings (reviewed, harmless)

- `The clock sys_clk has been defined multiple times` / `Cannot have multiple create_clock ...`:
  synthesis exports the `.sdc` clock into the implementation constraints; the identical `.pdc`
  definition is the one that is used (timing report section 1.1).
- `nexus_reconfig.sdc (2): Can't resolve object .../gen_osca.u_OSC_A/HFCLKOUT`: the RTL pin name is
  valid in synthesis (the Synplify report shows `sys_clk` declared at 25 MHz), but not in the
  post-synthesis netlist, where the `.pdc` uses `.../gen_osca.u_OSC_A.OSCA_inst/HFCLKOUT`.
- `Clock osc0_inst_hf_clk_out_o is overridden ... by clock sys_clk`: the OSC IP's own constraint is
  replaced by the project's `sys_clk`.
- A clock `osc0_inst/lscc_osc_inst/sed_sec_out_w` (225 MHz on `HFSDCOUT`) appears in the timing
  report. It is derived from the OSC IP and has no paths.
- `Unbound component CONFIG_LMMI of instance config_lmmi_inst` (Synplify Z198): the VHDL top level
  declares the primitive as a component; Synplify maps it to the `CONFIG_LMMI` library cell,
  as the netlist (`LMMI_EN = "EN"`) and the map report (Config LMMI 1/1) show.
- `User-specified initial value defined for some sequential elements` (FX474): the power-on reset
  counter and `rst_n` start from their configuration-time value of 0, as intended.
- `Input rstsmclk/smclk of instance config_lmmi_inst is floating` (CL167) and
  `Input RSTSMCLK/SMCLK ... undriven`: hardware-inferred pins of `CONFIG_LMMI`, left unconnected
  as in FPGA-RD-02294 and in the FPGA-TN-02099 example.
- `Blackbox OSCA / CONFIG_CLKRST_CORE / CONFIG_LMMI is missing a user supplied timing model`
  (synthesis only); place and route and timing analysis use the device models.
- `Pruning register bit 9 of shreg`: the stop bit of the UART shift register is constant.

## Running on the board

`LSC_REFRESH` reloads the configuration from the SPI flash, so the result depends on what the
flash holds:

- **Bitstream in the SPI flash (full demonstration):** program
  `lscc/impl_1/nexus_reconfig_impl_1.bit` into the external SPI flash (Radiant Programmer, target
  "External SPI Flash Memory", port JTAG2SPI, Erase, Program, Verify), then power-cycle the board.
  Open a UART terminal on the FTDI channel B at 115200 8N1. Every 10 s (or on a press of the
  button on B2) the terminal shows the refresh message followed by a new
  `NexusReconfig: FPGA configured` banner, and `led_o[0]` lights again for 2 s.
- **SRAM load over JTAG only:** after the refresh the device loads the SPI flash image instead of
  this design (or fails to configure if the flash is empty). This still shows that the refresh
  executed, but the design does not come back.

## Open items

- Testbench coverage gap: a missing UART drain before the refresh is not detected
  (`m3_nodrain`, see "Testbench conversion"). An instance with `LMMIREADY` always high would
  expose it.
- Hardware test not yet done.
- LED polarity on the CRUVI board is not confirmed (`LED_ACTIVE_LOW`, default 0).
- Whether B2 is connected to a push button on the CRUVI board is not confirmed (the CRUVI demo
  names it `rstn_i`). The auto-refresh timer works without it.
- The I/O standard is left at the tool default, as in the CRUVI board design; the bank voltages
  were not checked against the board schematic.

## References

- sysCONFIG User Guide for Nexus Platform, FPGA-TN-02099-3.7, October 2026
  (`docs/FPGA-TN-02099-sysCONFIG-User-Guide-Nexus.pdf`): Appendix D (CONFIG_LMMI), Table 6.18,
  Table 6.20, Table D.3.
- Multi-Boot User Guide for Nexus Platform, FPGA-TN-02145
  (`docs/FPGA-TN-02145-Multi-Boot-User-Guide-Nexus.pdf`).
- Lattice Nexus Device Multi-Boot Reference Design, FPGA-RD-02294
  (`/mnt/lscc/reference/designs/FPGA-RD-02294-Lattice-Nexus-Device-Multi-Boot-RD-Source-RevA-241006`).
- Radiant 2026.1.1 help, FPGA Libraries Reference Guide, CONFIG_LMMI (architectures supported:
  LFD2NX).
