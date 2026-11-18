# NexusReconfig - verification results and development notes

Test results, issues found during development and open items for the NexusReconfig design.
What the design contains and how to rebuild it are in the [Readme](../Readme.md).

> **Note:** this document records how the design was developed and tested, and may contain
> references to the internal development environment: the build host `lb`, paths under
> `/mnt/lscc` and `/mnt/tools`, the `lattice-prompt` MCP server and its tool calls, and the
> serial number of the test board. These are not needed to use or rebuild the design.

## Design details

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
- Wait at least four LMMI clock cycles after `LMMIREADY` is high before issuing a command (D.3);
  the design waits for 16.
- `LMMICLK` is at most 50 MHz (Table D.1). `LMMICLK` and `LMMIRESETN` must come from the OSC IP's
  `lmmi_clk_o` / `lmmi_resetn_o` pass-through outputs, or the software stops with an error (D.2).
- `RSTSMCLK` and `SMCLK` are hardware inferred and left unconnected, as in FPGA-RD-02294.

The command sequence is the `LSC_REFRESH` step of the refresh controller in FPGA-RD-02294
(`/mnt/lscc/reference/designs/FPGA-RD-02294-Lattice-Nexus-Device-Multi-Boot-RD-Source-RevA-241006`,
`source/impl_1/refresh.v`), without its Multi-Boot steps (`ISC_ENABLE_X`, `LSC_PROG_CNTRL0`,
`ISC_DISABLE` and the `MULTIBOOT` primitive), which are only needed to select an alternate image.

The button input must be seen released before a press counts, so a stuck-low input cannot cause
a refresh loop.

### When `NOCLIP` is needed

Map removes every path that does not run from a valid input to a valid output (an output pad or a
net with `NOCLIP`). Without a device output that depends on the refresh logic, the path
oscillator, `reconfig_core`, `CONFIG_LMMI`, `LMMIREADY` back to `reconfig_core` is a closed loop
with no valid output, and map removes it. `LSC_REFRESH` has an effect on the device, but not one
the tools can see. Typical cases:

- the refresh logic has no status outputs at all (no UART, no LEDs driven by the sequencer),
  for example when the only output is an LED flasher with no connection to the refresh logic;
- the only outputs that depend on the refresh logic are removed later, for example a debug UART
  taken out of a production build;
- the `CONFIG_LMMI` read data (`LMMIRDATA`, `LMMIRDATAVALID`) is used only inside a loop that
  never reaches a pin.

### Pin source

The pins come from the CRUVI board design
`/mnt/lscc/devel/Boards/CertusNX/cruvi/CruviDemo/test_certus/test_certus.pdc` (which names B2
`rstn_i`).

## Development environment

### Build and simulation through the `lattice-prompt` MCP server

All Lattice tools ran on the build host `lb` with Radiant 2026.1.1. `<project>` is
`/mnt/lscc/devel/Claude/NexusReconfig`.

1. Oscillator IP: `radiant_ip_generate(name=osc0, ip_module_dir=/mnt/tools/lscc/radiant/2026.1.1/ip/lifcl/osc,
   device=LFD2NX-40, family=LFD2NX, package=CABGA196, performance=8_High-Performance_1.0V,
   operation=Commercial, output_dir=<project>/src/ip/osc0,
   cfg_values="HF_OSC_EN:ENABLED; HF_CLK_FREQ:25; LF_OUTPUT_EN:DISABLED; SEDCLK_EN:0; LMMI_CLK_EN:ENABLED")`.
2. Project: `radiant_build_detached(tcl_path=<project>/scripts/create_project.tcl)`. The tool
   reports `failed` because no build stage runs.
3. Build: `radiant_build_detached(tcl_path=<project>/scripts/build_all.tcl)`,
   `radiant_build_wait(project_dir=<project>/scripts)`, then `validate_timing` on
   `<project>/lscc/impl_sv` and `<project>/lscc/impl_vhdl`.
4. RTL simulation: `simulate_rtl_detached(work_dir=<project>/sim/mcp_sim/<run>,
   sim_dir=<project>/sim/mcp_sim/<run>/system_sim, device=LFD2NX-40-8BG196C,
   sim_filelist=<project>/sim/<list>, top=tb_reconfig_core, skip_validate=true, clean=true)`, then
   `simulate_rtl_wait`, for `<list>` / `<run>`: `sim_sv_filelist.f` / `sv`,
   `sim_vhdl_filelist.f` / `vhdl`, `sim_sv_vhdtb_filelist.f` / `sv_vhdtb`,
   `sim_vhdl_svtb_filelist.f` / `vhdl_svtb`. The MCP tool needs absolute paths in the file lists.
5. Equivalence: as step 4 with `sim_filelist=<project>/sim/equiv_filelist.f`, `top=tb_equiv`,
   `<run>=equiv` and
   `libdirs=[/mnt/tools/lscc/radiant/2026.1.1/cae_library/simulation/verilog/uaplatform]`.
6. Fault injection: for each `sim/mcp_sim/tb_check/<m>_vhdtb.f` and `<m>_svtb.f`, as step 4 with
   its own `work_dir`/`sim_dir` (for example `sim/mcp_sim/tb_check/run_<m>_<tb>`).
7. Top-level elaboration: as step 5 with `lint_top_sv_filelist.f` (`<run>=lint_sv`) and
   `lint_top_vhdl_filelist.f` (`<run>=lint_vhdl`), `top=nexus_reconfig_top` and
   `elaborate_only=true`.

### Board access

- The CRUVI board's FT2232H has USB serial `FT7BCWYB`; channel A (JTAG) was `FTUSB-0` with only
  this board attached, channel B is the UART. The JTAG cables are attached to `lb`.
- Programming used `radiant_program(..., force=True)` on `lb`; the verdict is
  `Operation: successful.` in `~/.config/LatticeSemi/DiamondNG/programmer.log` on `lb`. Flash
  programming takes about 10 s, and the FPGA does not restart by itself afterwards.
- SRAM loads with the boot banner captured used
  `/mnt/tools/lscc/radiant/2026.1.1/programmer/bin/lin64/pgrcmd -infile <chain file>`.
- UART capture on `lb`:
  `python3 /mnt/lscc/devel/Claude/Cruvi/scripts/uart_capture.py --serial FT7BCWYB --interface B --baud 115200 --seconds 45`.

## Verification results (2026-11-14, Radiant 2026.1.1)

| Check | SystemVerilog (`impl_sv`) | VHDL-2008 (`impl_vhdl`) |
| :-- | :-- | :-- |
| RTL simulation, own-language testbench | `TEST PASSED`, 12 checks, 0 errors, 0 warnings | `TEST PASSED`, 12 checks, 0 errors, 0 warnings |
| RTL simulation, other-language testbench | `TEST PASSED`, 0 errors, 0 warnings | `TEST PASSED`, 0 errors, 0 warnings |
| Elaborate-only, full top level with device library cells | 0 errors, 2 warnings (`vopt-2958 Implicit wire '<protected>'`, inside the encrypted Lattice library cells) | Same |
| Timing (`validate_timing`) | Met at all corners, 0 failing endpoints, constraint coverage 100 % | Same |
| Worst setup slack, `sys_clk` 25 MHz (85 °C) | +35.901 ns (logic Fmax about 244 MHz) | +36.072 ns (about 254 MHz) |
| Worst hold slack | +0.155 ns | +0.190 ns |
| Resources | 216 LUT4, 123 registers, 2 EBR, 1 OSC, 1 CONFIG_LMMI, 4 I/O | 211 LUT4, 123 registers, 1 EBR, 1 OSC, 1 CONFIG_LMMI, 4 I/O |
| Hardware, CRUVI board | **Passed** 2026-11-14 | **Passed** 2026-11-13 |

| Check across both implementations | Result |
| :-- | :-- |
| Lock-step equivalence (`tb_equiv`) | `TEST PASSED`: 4 parameter sets, about 300 000 cycles each, 0 output mismatches, 0 warnings |
| Fault injection, both testbenches on 4 mutants | Identical results on every mutant (see "Testbench coverage") |
| `NOCLIP` added to `CONFIG_LMMI` (2026-11-16) | No effect (see "`NOCLIP` in this design") |
| Bitstreams of the two-implementation project | Configuration data identical, byte for byte after the text header, to the board-tested builds: `impl_sv` to the `main` build (`41439d8`) tested on 2026-11-14, `impl_vhdl` to a rebuild of the board-tested VHDL sources (`f5504f3`) |
| `src/` folder layout (2026-11-17, `c4e0211`) | `create_project.tcl` regenerates the same `.rdf`; both implementations meet timing with 100 % constraint coverage and Config LMMI 1/1; the four RTL simulations and the equivalence test pass; top-level elaboration 0 errors |

The resource and slack differences come from synthesis packing the two message ROMs differently
(one EBR for VHDL, two for SystemVerilog), not from a change in function.

## Testbench coverage

What [`tb_reconfig_core`](../src/tb/tb_reconfig_core.sv) covers, with three DUT instances on a
scaled clock (1 MHz, 50 kbaud):

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

### VHDL testbench

[`tb_reconfig_core.vhd`](../src/tb/tb_reconfig_core.vhd) is a conversion of
[`tb_reconfig_core.sv`](../src/tb/tb_reconfig_core.sv): the same three DUT instances, stimulus,
LMMI target model, UART monitors, 12 final checks and checks during the run. Differences:

- The LMMI back-pressure uses `ieee.math_real.uniform` instead of `$urandom`, so the ready pattern,
  and with it the time of each LMMI byte, differs from the SystemVerilog run. The event log times
  of the UART messages differ by up to 2 us because the VHDL monitor reports through signals.
- The DUT is bound through a component declaration, so the same testbench runs against the VHDL
  entity and the SystemVerilog module.

### Equivalence testbench

[`tb_equiv`](../src/tb/tb_equiv.sv) runs the SystemVerilog modules (renamed `ref_*` by
[`make_sv_ref.sh`](../scripts/make_sv_ref.sh), because both implementations share one library) and
the VHDL entities side by side with identical stimulus. It compares `rst_no` from time 0 and all
outputs (`led_o`, `txd_o`, `lmmi_*`, `refresh_done_o`) on every clock from the release of the
power-on reset. Before that release the SystemVerilog registers are X and the VHDL enumerated
state registers start at their leftmost value; on the device every register is cleared at
configuration. Parameter sets:

- **P0:** auto-refresh timer, button released, random `LMMIREADY` back-pressure.
- **P1:** button only, active-low LEDs. The input is stuck low at start, then a bouncing release,
  a 1 ms glitch shorter than the debounce time, and a bouncing press.
- **P2:** button stuck low, timer disabled. No LMMI transfer is allowed, and none occurs.
- **P3:** 115200 baud at 1 MHz (divider 9), LMMI gap 4, random button noise, long `LMMIREADY`
  stretches.

The test also fails if the stimulus did not exercise the refresh, the four LMMI bytes, UART
output, and the boot, failure and heartbeat LED patterns.

### Fault injection

[`make_tb_check.sh`](../scripts/make_tb_check.sh) makes each mutant as a copy of
[`src/rtl/vhdl/*.vhd`](../src/rtl/vhdl/) with one fault. Both testbenches were run on every mutant
(2026-11-13, repeated with the same results on 2026-11-14):

| Mutant | Fault | VHDL testbench | SystemVerilog testbench |
| :-- | :-- | :-- | :-- |
| `m1_opcode` | Opcode `0x78` instead of `0x79` | FAILED, 2 errors (A, B: `LSC_REFRESH 79 00 00 00 written`) | Same 2 errors |
| `m2_offset` | LMMI offset `0x02` instead of `0x01` | FAILED, 8 errors (offset error on every byte) | Same 8 errors |
| `m3_nodrain` | Refresh starts without waiting for the last UART character | PASSED (not detected) | PASSED (not detected) |
| `m4_bootled` | Boot LED never on | FAILED, 1 error (A: `boot LED not on at 1 ms`) | Same 1 error |

`m3_nodrain` is a coverage gap of both testbenches: with about one cycle in three of `LMMIREADY`
low, `lmmi_refresh` needs about 2 ms to see 16 consecutive ready cycles, so the last character
(200 us at 50 kbaud) has always left the UART before the first LMMI request, and the check "LMMI
request before the UART message completed" cannot fire.

## `NOCLIP` in this design

`LMMIREADY` steers the sequencer, which drives `txd_o` and `led_o`, so map keeps the refresh logic
without `NOCLIP`. Checked on 2026-11-16: both implementations built with and without it give the
same map report (Config LMMI 1/1; 216/211 LUT4, 123 registers, 2/1 EBR), the same worst setup
slack (+35.901 / +36.072 ns), and bitstreams whose configuration data is identical byte for byte
(only the build date in the text header differs). Simulations were repeated (all `TEST PASSED`,
equivalence 0 mismatches, both top levels elaborate with 0 errors) and both builds with `NOCLIP`
passed the board test (see "Hardware results").

Without `NOCLIP`, in a variant where no device pin depends on the refresh logic, the failure is
silent: the build completes, timing is met, the bitstream loads, and the device never refreshes.
The map report's "Removed logic" section does not list the removal; the only signs are
`Number of Config LMMI: 0 out of 1` in `lscc/impl_<L>/nexus_reconfig_impl_<L>.mrp` and a lower
register count. Synplify writes the attribute into the netlist as
`(* NOCLIP=1 *) CONFIG_LMMI config_lmmi_inst` in `lscc/impl_<L>/nexus_reconfig_impl_<L>.vm`, which is
what map reads.

## Hardware results

VHDL-2008 build (2026-11-13, commit `358c619`, same design sources as `impl_vhdl`):

| Step | Result | Log |
| :-- | :-- | :-- |
| Verify ID | IDCODE `0x310F1043` (LFD2NX-40) on `FTUSB-0` | |
| UART before any load (flash image of an earlier design) | No output in 12 s | |
| SRAM load (`pgrcmd`, UART capture running) | Banner, then `issuing LSC_REFRESH` 10 s later, then nothing (the flash held another design) | [`uart_vhdl_sram_load_20261113.bin`](../logs/uart_vhdl_sram_load_20261113.bin) (70 bytes) |
| SPI flash Erase, Program, Verify | `Operation Done. No Error.` | [`programmer_vhdl_20261113.log`](../logs/programmer_vhdl_20261113.log) |
| JTAG Refresh, then 45 s UART capture | 4 complete cycles of banner and `issuing LSC_REFRESH`: every `LSC_REFRESH` written by the fabric reconfigured the device from the flash | [`uart_vhdl_spiflash_refresh_20261113.bin`](../logs/uart_vhdl_spiflash_refresh_20261113.bin) (280 bytes) |

SystemVerilog build (2026-11-14, `main` commit `41439d8`, configuration data identical to `impl_sv`):

| Step | Result | Log |
| :-- | :-- | :-- |
| Verify ID | Successful on `FTUSB-0` | |
| SRAM load (`pgrcmd`, UART capture running) | Banner, `issuing LSC_REFRESH`, then the VHDL build from the flash booted and kept cycling: the SystemVerilog `LSC_REFRESH` reconfigured the device | [`uart_sv_sram_load_20261114.bin`](../logs/uart_sv_sram_load_20261114.bin) (174 bytes) |
| SPI flash Erase, Program, Verify | `Operation Done. No Error.` | [`programmer_sv_sram_flash_20261114.log`](../logs/programmer_sv_sram_flash_20261114.log) |
| JTAG Refresh, then 60 s UART capture | 5 boots and 4 `LSC_REFRESH` cycles, all from the SystemVerilog build in the flash | [`uart_sv_spiflash_refresh_20261114.bin`](../logs/uart_sv_spiflash_refresh_20261114.bin) (314 bytes), [`programmer_sv_refresh_20261114.log`](../logs/programmer_sv_refresh_20261114.log) |

Two-implementation project (2026-11-14, [`nexus_reconfig_sram_vhdl_ftusb0.xcf`](../lscc/nexus_reconfig_sram_vhdl_ftusb0.xcf)):
`impl_vhdl` loaded into SRAM while the SystemVerilog build in the flash was running. The capture
shows the running SystemVerilog build refreshing, the VHDL banner after the load, its
`LSC_REFRESH` 10 s later and the SystemVerilog build booting from the flash again
([`uart_dual_vhdl_sram_over_sv_flash_20261114.bin`](../logs/uart_dual_vhdl_sram_over_sv_flash_20261114.bin), 174 bytes).

With `NOCLIP` on `CONFIG_LMMI` (2026-11-16, both implementations loaded into SRAM in turn, the
SystemVerilog build in the flash):

| Implementation | Banner after the load | Its `LSC_REFRESH` | Flash build boots | Capture |
| :-- | :-- | :-- | :-- | :-- |
| SystemVerilog | 13:01:52.8 | 13:02:02.5 | 13:02:04.3 | [`uart_noclip_sv_sram_20261116.bin`](../logs/uart_noclip_sv_sram_20261116.bin) (174 bytes) |
| VHDL-2008 | 13:02:25.9 | 13:02:35.6 | 13:02:37.4 | [`uart_noclip_vhdl_sram_20261116.bin`](../logs/uart_noclip_vhdl_sram_20261116.bin) (174 bytes) |

## Issues found during development

- **MCP builds ignore `impl`.** `radiant_build_detached(rdf_path=..., impl=impl_vhdl)` (MCP tool,
  2026-11-14) always builds the project's default implementation (`impl_sv`). The `prj_run_*`
  commands have no `-impl` option, so [`build_all.tcl`](../scripts/build_all.tcl) activates each
  implementation in turn with `prj_activate_impl` and leaves `impl_sv` active.
- **Stale `lscc/.recovery`.** After a branch switch, Radiant applied an untracked
  `lscc/.recovery` file on `prj_open`, and synthesis asked for a source file that was only on the
  other branch. Moving the file aside fixed it; it is now in `.gitignore`.
- **`radiant_program` status.** The MCP tool reports `failed` even on success; the verdict is
  `Operation: successful.` in `~/.config/LatticeSemi/DiamondNG/programmer.log` on `lb`. It needs
  `force=True` for these bitstreams: Radiant rewrites the `.rdf` at the end of the build, after
  writing the bitstream, so the freshness check sees the project as newer.
- **Boot banner capture.** `radiant_program` returns about 18 s after the load starts, after the
  10 s auto-refresh. To capture the banner of an SRAM load, start the UART capture first and load
  with `pgrcmd -infile <chain file>`. A capture started at the same time as the Programmer fails
  with `unable to claim usb device`.
- **`create_project.tcl` reports `failed`.** The script runs no build stage; the project is
  created correctly.
- **Mixed-language time resolution.** With a VHDL top level the default resolution is 1 ns, and
  the Lattice Verilog cells need 1 ps (`vsim-3693`), so the file lists with a VHDL top level pass
  `-t 1ps` to `vsim`.
- **numeric_std warnings at time 0.** Registers without a reset value are `'U'` until the
  power-on reset clears them (X in the SystemVerilog original); [`run_vhdl.do`](../sim/run_vhdl.do)
  suppresses numeric_std metavalue warnings for the time-0 delta cycles only.
- **`CONFIG_LMMI` in VHDL.** [`nexus_reconfig_top.vhd`](../src/rtl/vhdl/nexus_reconfig_top.vhd)
  declares the primitive as a local component, copied from
  `cae_library/synthesis/vhdl/lfd2nx.vhd`, because the precompiled Questa library `lfd2nx` holds
  only the Verilog cells, not a VHDL `components` package.
- **SPI flash chain file.** Derived from the GUI-saved Certus-NX file
  `/mnt/lscc/devel/Demo/CNX_FullBridge_260220/poc_design/impl_1/cnx40.xcf` with only the
  bitstream, its size, last sector (`0xC0000`) and the port changed. Its flash entry is
  `MT25QU128`; the Programmer checks only the capacity byte of the flash ID (`0x18`, 128 Mbit)
  with a generic algorithm, and the check passed on the CRUVI board.

### Known build warnings (reviewed, harmless)

- `The clock sys_clk has been defined multiple times` / `Cannot have multiple create_clock ...`:
  synthesis exports the [`.sdc`](../src/cst/nexus_reconfig.sdc) clock into the implementation
  constraints; the identical [`.pdc`](../src/cst/nexus_reconfig.pdc) definition is the one that is
  used (timing report section 1.1).
- `nexus_reconfig.sdc (2): Can't resolve object .../gen_osca.u_OSC_A/HFCLKOUT`: the RTL pin name is
  valid in synthesis (the Synplify report shows `sys_clk` declared at 25 MHz), but not in the
  post-synthesis netlist, where the `.pdc` uses `.../gen_osca.u_OSC_A.OSCA_inst/HFCLKOUT`.
- `Clock osc0_inst_hf_clk_out_o is overridden ... by clock sys_clk`: the OSC IP's own constraint is
  replaced by the project's `sys_clk`.
- A clock `osc0_inst/lscc_osc_inst/sed_sec_out_w` (225 MHz on `HFSDCOUT`) appears in the timing
  report. It is derived from the OSC IP and has no paths.
- `Unbound component CONFIG_LMMI of instance config_lmmi_inst` (Synplify Z198, `impl_vhdl` only):
  Synplify maps the component to the `CONFIG_LMMI` library cell, as the netlist
  (`LMMI_EN = "EN"`) and the map report (Config LMMI 1/1) show.
- `User-specified initial value defined for some sequential elements` (FX474): the power-on reset
  counter and `rst_n` start from their configuration-time value of 0, as intended.
- `Input rstsmclk/smclk of instance config_lmmi_inst is floating` (CL167) and
  `Input RSTSMCLK/SMCLK ... undriven`: hardware-inferred pins of `CONFIG_LMMI`, left unconnected
  as in FPGA-RD-02294 and in the FPGA-TN-02099 example.
- `Blackbox OSCA / CONFIG_CLKRST_CORE / CONFIG_LMMI is missing a user supplied timing model`
  (synthesis only); place and route and timing analysis use the device models.
- `Pruning register bit 9 of shreg`: the stop bit of the UART shift register is constant.

## Open items

- Testbench coverage gap: a missing UART drain before the refresh is not detected
  (`m3_nodrain`, see "Fault injection"). An instance with `LMMIREADY` always high would expose it.
- The SPI flash of the CRUVI board holds the SystemVerilog build (since 2026-11-14). The
  original flash content, an earlier design that printed nothing on the UART, was erased on
  2026-11-13.
- `led_o` and the button were not observed: the hardware test used the UART only, with the
  auto-refresh timer as the trigger.
- LED polarity on the CRUVI board is not confirmed (`LED_ACTIVE_LOW`, default 0).
- Whether B2 is connected to a push button on the CRUVI board is not confirmed (the CRUVI demo
  names it `rstn_i`). The auto-refresh timer works without it.
- The I/O standard is left at the tool default, as in the CRUVI board design; the bank voltages
  were not checked against the board schematic.
- The flash vendor on the board was not identified.
