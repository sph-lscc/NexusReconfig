# NexusReconfig - Certus-NX reconfiguration from internal logic

| Info: | Details |
| :-- | :-- |
| Device | Certus-NX LFD2NX-40-8BG196C |
| Board | CRUVI Certus-NX board |
| Software | Radiant 2026.1.1 (Synplify Pro), Questa (bundled with Radiant) |
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

## How it works

```
             +-------------------- nexus_reconfig_top ----------------------+
             |                                                              |
             |  osc0 (OSC IP)          reconfig_core               CONFIG_LMMI
             |  hf_clk_out_o --+--> sys_clk ------------+          (LMMI_EN="EN")
             |  lmmi_clk_i  <--+                        |                   |
             |  lmmi_clk_o  ------------------------------------> LMMICLK   |
             |  lmmi_resetn_o ----------------------------------> LMMIRESETN|
             |  lmmi_resetn_i <-- rst_n (power-on reset)|                   |
             |                         lmmi_refresh --- LMMI write port --> |
  btn_ni ----+-> sync/debounce --+                      |                   |
             |   auto timer -----+--> sequencer --> uart_tx ---------------------> txd_o
             |                        LED logic ---------------------------------> led_o[1:0]
             +--------------------------------------------------------------+
```

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
| `src/nexus_reconfig_top.sv` | Top level: OSC IP, `CONFIG_LMMI` primitive, `reconfig_core` |
| `src/reconfig_core.sv` | Power-on reset, button debounce, auto timer, UART messages, LEDs, sequencer |
| `src/lmmi_refresh.sv` | LMMI host that writes `LSC_REFRESH` |
| `src/uart_tx.sv` | UART transmitter, 8N1 |
| `lscc/osc0/` | Generated OSC IP (25 MHz HF clock, LMMI clock path enabled) |
| `lscc/nexus_reconfig.rdf` | Radiant project, implementation `impl_1` |
| `constraints/nexus_reconfig.pdc` | Clock, pins, INITN release, false paths (post-synthesis) |
| `constraints/nexus_reconfig.sdc` | Clock for synthesis |
| `tb/tb_reconfig_core.sv` | Self-checking testbench with an LMMI target model and UART monitors |
| `sim/sim_filelist.f` | Simulation file list |
| `sim/lint_top_filelist.f` | File list for the elaborate-only check of the full top level |
| `scripts/create_project.tcl` | Re-creates the Radiant project |
| `docs/` | FPGA-TN-02099 (sysCONFIG) and FPGA-TN-02145 (Multi-Boot) user guides |

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
| `LED_ACTIVE_LOW` | 0 | Set to 1 if the board LEDs light on a low level |

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
4. **RTL simulation:**
   `simulate_rtl_detached(work_dir=<project>/sim/mcp_sim, sim_dir=<project>/sim/mcp_sim/system_sim,
   device=LFD2NX-40-8BG196C, sim_filelist=<project>/sim/sim_filelist.f, top=tb_reconfig_core,
   libdirs=[/mnt/tools/lscc/radiant/2026.1.1/cae_library/simulation/verilog/uaplatform],
   skip_validate=true, clean=true)`, then `simulate_rtl_wait`. Pass criterion: `TEST PASSED` in
   `sim/mcp_sim/system_sim/sim.log`.
5. **Full top-level elaboration** (with the OSCA, CONFIG_CLKRST_CORE and CONFIG_LMMI library
   cells): as step 4 with `sim_filelist=<project>/sim/lint_top_filelist.f`,
   `top=nexus_reconfig_top`, `sim_dir=<project>/sim/mcp_sim/lint_top` and `elaborate_only=true`.

## Verification results (2026-11-12, Radiant 2026.1.1)

| Check | Result |
| :-- | :-- |
| RTL simulation (`tb_reconfig_core`) | `TEST PASSED`, 12 checks, 0 errors, 0 warnings |
| Elaborate-only, full top level with device library cells | 0 errors, 2 warnings, both `vopt-2958 Implicit wire '<protected>'` from inside the encrypted Lattice library cells |
| Timing (`validate_timing`) | Met at all corners: 0 failing endpoints, constraint coverage 100 % |
| Worst setup slack, `sys_clk` 25 MHz | +35.901 ns (85 °C), so the logic Fmax is about 244 MHz |
| Worst hold slack | +0.155 ns |
| Resources | 216 LUT4, 123 registers, 2 EBR (message ROM), 1 OSC, 1 CONFIG_LMMI, 4 I/O |
| Hardware | **Not yet tested on the board** |

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
- `Input RSTSMCLK/SMCLK ... undriven`: hardware-inferred pins of `CONFIG_LMMI`, left unconnected
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
