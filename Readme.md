# NexusReconfig - Certus-NX reconfiguration from internal logic

| Info: | Details |
| :-- | :-- |
| Device | Certus-NX LFD2NX-40-8BG196C |
| Board | CRUVI Certus-NX board |
| Software | Radiant 2026.1.1 (Synplify Pro), Questa (bundled with Radiant) |
| HDL | Two equivalent implementations: SystemVerilog ([`src/rtl/sv/`](src/rtl/sv/)) and VHDL-2008 ([`src/rtl/vhdl/`](src/rtl/vhdl/)); testbenches in both languages; OSC IP Verilog |
| IP | osc 1.4.0 ([`src/ip/osc0/`](src/ip/osc0/)) |

## Notes

- This reference design shows how user logic inside a Certus-NX FPGA can force the device to
  reconfigure itself, with no external pin (PROGRAMN), JTAG cable or host involved. It writes
  the `LSC_REFRESH` command (opcode `0x79`) to the configuration block through the
  `CONFIG_LMMI` primitive; the device then reloads its bitstream from the external SPI flash.
- The refresh loads **whatever image is in the SPI flash**. To see this design restart itself,
  its bitstream must be in the flash (see "Running on the board").
- One Radiant project builds either language: implementation `impl_sv` (default) or
  `impl_vhdl`. Both share the device settings, strategy, oscillator IP and constraints.
- Verification results, hardware test results, issues found during development and open items
  are in [`docs/development_notes.md`](docs/development_notes.md).

## Releases (git tags)

Releases are signed tags on `main` named `r<Radiant version>`, with `-<n>` for later releases on
the same version; the tag message holds the details.

| Tag | Tool version | IP versions | Content | Verification |
| :-- | :-- | :-- | :-- | :-- |
| `r2026.1.1-3` | Radiant 2026.1.1 | osc 1.4.0 | Sources moved to the `src/` layout (`src/rtl`, `src/ip`, `src/tb`, `src/cst`); Readme reduced to contents and reproduction with the standard tools; results, development issues and open items moved to [`docs/development_notes.md`](docs/development_notes.md). Design logic unchanged from `r2026.1.1-2` (comment lines only) | Both implementations: timing met (setup +35.901 / +36.072 ns, hold +0.155 / +0.190 ns), RTL simulation PASS, lock-step equivalence PASS, top-level elaboration 0 errors (2026-11-17). Not retested on hardware |
| `r2026.1.1-2` | Radiant 2026.1.1 | osc 1.4.0 | `NOCLIP` added next to `syn_noprune` on `CONFIG_LMMI` in both top levels; `.gitignore` for the Radiant `.recovery` file and Programmer `source/` folder. Configuration data unchanged from `r2026.1.1` | Both implementations: timing met (setup +35.901 / +36.072 ns), RTL simulation PASS, lock-step equivalence 0 mismatches, SRAM hardware test passed on the CRUVI board (2026-11-16) |
| `r2026.1.1` | Radiant 2026.1.1 | osc 1.4.0 | First release: SystemVerilog (`impl_sv`) and VHDL-2008 (`impl_vhdl`) implementations in one project, testbenches in both languages | Both implementations: timing met, RTL simulation PASS, lock-step equivalence 0 mismatches, hardware test passed on the CRUVI board |

## How it works

![NexusReconfig block diagram](docs/block_diagram.svg)

1. After configuration a power-on counter releases the logic. The UART prints
   `NexusReconfig: FPGA configured`, `led_o[0]` lights for 2 s and `led_o[1]` blinks at 2 Hz.
2. A reconfiguration request comes from a press on `btn_ni` (debounced for 20 ms, and only after
   the input was seen released) or from the auto-refresh timer, 10 s after the banner.
3. The UART prints `NexusReconfig: issuing LSC_REFRESH`. When the last character has left the
   UART, `lmmi_refresh` waits for 16 consecutive cycles with `LMMIREADY` high, then writes
   `79 00 00 00` (opcode and three operands) to LMMI offset `0x01`.
4. The device reconfigures from the SPI flash and the sequence starts again.
5. If the device is still running after the command, `led_o[0]` flashes quickly (64 ms).

The LMMI protocol follows FPGA-TN-02099 Appendix D: fixed offset `ADDR_CFG = 0x01`, one byte per
clock with `LMMIREADY` high, `OPERAND1 = 0x00` (normal boot settings, Table 6.20), `LMMICLK` and
`LMMIRESETN` from the OSC IP pass-through outputs (`LMMI_CLK_EN = ENABLED`). The sequence is the
`LSC_REFRESH` step of the Multi-Boot reference design FPGA-RD-02294, without its Multi-Boot steps.

### Keeping CONFIG_LMMI: `syn_noprune` and `NOCLIP`

The `CONFIG_LMMI` instance in both top levels carries two attributes:

```systemverilog
// src/rtl/sv/nexus_reconfig_top.sv
CONFIG_LMMI #(.LMMI_EN ("EN")) config_lmmi_inst ( ... ) /* synthesis syn_noprune=1 NOCLIP=1 */;
```

```vhdl
-- src/rtl/vhdl/nexus_reconfig_top.vhd (architecture declarative part)
attribute syn_noprune : boolean;
attribute NOCLIP      : boolean;
attribute syn_noprune of config_lmmi_inst : label is true;
attribute NOCLIP      of config_lmmi_inst : label is true;
```

| Tool | What it removes | Attribute that prevents it |
| :-- | :-- | :-- |
| Synthesis (Synplify Pro) | A primitive whose outputs drive no device pin | `syn_noprune` on the instance |
| Map ("Removing unused logic") | Every path that does not reach an output pad or a net with `NOCLIP` (Radiant Constraints Reference Guide, "NOCLIP") | `NOCLIP` on the instance |

`NOCLIP` is needed only when no device output depends on the refresh logic (for example a variant
without the UART and status LEDs, or with them removed for production). Map then removes
`CONFIG_LMMI` and the refresh logic silently. In this design the sequencer drives `txd_o` and
`led_o`, so `NOCLIP` changes nothing; it is kept as a safeguard for derived designs. After every
build, check `Number of Config LMMI: 1 out of 1` in `lscc/impl_<L>/nexus_reconfig_impl_<L>.mrp`.

## Contents

| Type | Path | Content |
| :-- | :-- | :-- |
| RTL | [`src/rtl/sv/nexus_reconfig_top.sv`](src/rtl/sv/nexus_reconfig_top.sv), [`src/rtl/vhdl/nexus_reconfig_top.vhd`](src/rtl/vhdl/nexus_reconfig_top.vhd) | Top level: OSC IP, `CONFIG_LMMI` primitive (with `syn_noprune` and `NOCLIP`), `reconfig_core` |
| RTL | [`src/rtl/sv/reconfig_core.sv`](src/rtl/sv/reconfig_core.sv), [`src/rtl/vhdl/reconfig_core.vhd`](src/rtl/vhdl/reconfig_core.vhd) | Power-on reset, button debounce, auto timer, UART messages, LEDs, sequencer |
| RTL | [`src/rtl/sv/lmmi_refresh.sv`](src/rtl/sv/lmmi_refresh.sv), [`src/rtl/vhdl/lmmi_refresh.vhd`](src/rtl/vhdl/lmmi_refresh.vhd) | LMMI host that writes `LSC_REFRESH` |
| RTL | [`src/rtl/sv/uart_tx.sv`](src/rtl/sv/uart_tx.sv), [`src/rtl/vhdl/uart_tx.vhd`](src/rtl/vhdl/uart_tx.vhd) | UART transmitter, 8N1 |
| RTL | [`src/rtl/vhdl/nexus_reconfig_pkg.vhd`](src/rtl/vhdl/nexus_reconfig_pkg.vhd) | VHDL only: `clog2` and string-to-ROM helper functions |
| IP | [`src/ip/osc0/`](src/ip/osc0/) | Generated OSC IP (25 MHz HF clock, LMMI clock path enabled), used by both implementations |
| Constraint | [`src/cst/nexus_reconfig.pdc`](src/cst/nexus_reconfig.pdc) | Clock, pins, INITN release, false paths (post-synthesis) |
| Constraint | [`src/cst/nexus_reconfig.sdc`](src/cst/nexus_reconfig.sdc) | Clock for synthesis |
| Testbench | [`src/tb/tb_reconfig_core.sv`](src/tb/tb_reconfig_core.sv) | Self-checking SystemVerilog testbench with an LMMI target model and UART monitors (ports only: runs against either implementation) |
| Testbench | [`src/tb/tb_reconfig_core.vhd`](src/tb/tb_reconfig_core.vhd) | The same testbench in VHDL-2008 (ports only, component binding: runs against either implementation) |
| Testbench | [`src/tb/tb_equiv.sv`](src/tb/tb_equiv.sv) | Lock-step equivalence testbench: VHDL-2008 against SystemVerilog |
| Implementation | [`lscc/nexus_reconfig.rdf`](lscc/nexus_reconfig.rdf) | Radiant project with the implementations `impl_sv` (default) and `impl_vhdl` |
| Implementation | [`lscc/nexus_reconfig_*_{sv,vhdl}_ftusb0.xcf`](lscc/) | Programmer chain files per implementation (see "Running on the board") |
| Simulation | [`sim/sim_sv_filelist.f`](sim/sim_sv_filelist.f) | SystemVerilog design, SystemVerilog testbench |
| Simulation | [`sim/sim_vhdl_filelist.f`](sim/sim_vhdl_filelist.f) | VHDL design, VHDL testbench |
| Simulation | [`sim/sim_sv_vhdtb_filelist.f`](sim/sim_sv_vhdtb_filelist.f) | SystemVerilog design, VHDL testbench |
| Simulation | [`sim/sim_vhdl_svtb_filelist.f`](sim/sim_vhdl_svtb_filelist.f) | VHDL design, SystemVerilog testbench |
| Simulation | [`sim/equiv_filelist.f`](sim/equiv_filelist.f) | `tb_equiv` with both implementations |
| Simulation | [`sim/lint_top_sv_filelist.f`](sim/lint_top_sv_filelist.f), [`sim/lint_top_vhdl_filelist.f`](sim/lint_top_vhdl_filelist.f) | Elaborate-only check of the full top level, per implementation |
| Simulation | [`sim/run_vhdl.do`](sim/run_vhdl.do) | Questa run script for the simulations with VHDL design units |
| Script | [`scripts/create_project.tcl`](scripts/create_project.tcl) | Re-creates the Radiant project with both implementations (VHDL-2008 enabled for Synplify Pro and LSE) |
| Script | [`scripts/build_all.tcl`](scripts/build_all.tcl) | Builds both implementations |
| Script | [`scripts/make_sv_ref.sh`](scripts/make_sv_ref.sh) | Copies [`src/rtl/sv/`](src/rtl/sv/) with `ref_` module names into `sim/mcp_sim/sv_ref/` for `tb_equiv` |
| Script | [`scripts/make_tb_check.sh`](scripts/make_tb_check.sh) | Prepares the fault-injection check of both testbenches in `sim/mcp_sim/tb_check/` |
| Log | [`logs/`](logs/) | Programmer logs and raw UART captures of the hardware tests |
| Documentation | [`docs/development_notes.md`](docs/development_notes.md) | Verification and hardware results, development issues, known build warnings, open items |
| Documentation | [`docs/`](docs/) | FPGA-TN-02099 ([`sysCONFIG`](docs/FPGA-TN-02099-sysCONFIG-User-Guide-Nexus.pdf)) and FPGA-TN-02145 ([`Multi-Boot`](docs/FPGA-TN-02145-Multi-Boot-User-Guide-Nexus.pdf)) user guides, block diagram ([`block_diagram.svg`](docs/block_diagram.svg)) |

### Ports and pins

| Port | Pin | Direction | Function |
| :-- | :-- | :-- | :-- |
| `btn_ni` | B2 | in, pull-up | Reconfiguration request, active low |
| `led_o[0]` | A8 | out | On for 2 s after configuration; fast flash if the refresh did not execute |
| `led_o[1]` | B8 | out | 2 Hz heartbeat |
| `txd_o` | F11 | out | UART, 115200 baud, 8N1 |

Pins come from the CRUVI board's own demonstration design. B2 is the INITN sysCONFIG pin; the
[`.pdc`](src/cst/nexus_reconfig.pdc) releases it with `ldc_set_sysconfig {INITN_PORT=DISABLE}`.

### Parameters (`nexus_reconfig_top`)

| Parameter | Default | Meaning |
| :-- | :-- | :-- |
| `AUTO_REFRESH_MS` | 10000 | Auto-refresh delay after the banner; 0 = button only |
| `LED_ACTIVE_LOW` | `false` / `1'b0` | Set if the board LEDs light on a low level (VHDL `boolean`, SystemVerilog `bit`) |

## Reproducing the results

Tools: Lattice Radiant 2026.1.1 (with Synplify Pro and the bundled Questa) and Radiant
Programmer. `<radiant>` is the Radiant installation folder. Run the commands from the repository
root.

1. **Oscillator IP** (already in [`src/ip/osc0/`](src/ip/osc0/); only needed to regenerate it):
   in the Radiant IP Catalog, Module OSC 1.4.0 for LFD2NX-40-8BG196C, named `osc0`, output folder
   `src/ip/osc0`, with HF oscillator enabled at 25 MHz, LF output disabled, SED clock disabled and
   LMMI clock enabled (`HF_OSC_EN:ENABLED; HF_CLK_FREQ:25; LF_OUTPUT_EN:DISABLED; SEDCLK_EN:0;
   LMMI_CLK_EN:ENABLED`).
2. **Project** (already in [`lscc/nexus_reconfig.rdf`](lscc/nexus_reconfig.rdf); only needed to
   re-create it): `radiantc scripts/create_project.tcl`
   ([`create_project.tcl`](scripts/create_project.tcl); use `pnmainc` on a Linux host without a
   display).
3. **Build both implementations:** `radiantc scripts/build_all.tcl`
   ([`build_all.tcl`](scripts/build_all.tcl)). The `prj_run_*` commands act only on the active
   implementation, so the script activates `impl_sv` and `impl_vhdl` in turn. The bitstreams are
   `lscc/impl_<L>/nexus_reconfig_impl_<L>.bit` (`<L>` = `sv` or `vhdl`). Check that the timing
   reports (`lscc/impl_<L>/nexus_reconfig_impl_<L>.twr`) have no failing endpoints and that the map
   reports (`.mrp`) show `Number of Config LMMI: 1 out of 1`.
4. **RTL simulation** with Questa, one run per file list, top level `tb_reconfig_core`:
   [`sim_sv_filelist.f`](sim/sim_sv_filelist.f), [`sim_vhdl_filelist.f`](sim/sim_vhdl_filelist.f),
   [`sim_sv_vhdtb_filelist.f`](sim/sim_sv_vhdtb_filelist.f) and
   [`sim_vhdl_svtb_filelist.f`](sim/sim_vhdl_svtb_filelist.f). Pass: `TEST PASSED`. The file
   lists hold absolute paths and the Questa options each run needs (VHDL-2008, `-t 1ps` for a VHDL
   top level, [`run_vhdl.do`](sim/run_vhdl.do)); adjust the paths to the location of the
   repository.
5. **Equivalence:** run [`scripts/make_sv_ref.sh`](scripts/make_sv_ref.sh), then simulate
   [`equiv_filelist.f`](sim/equiv_filelist.f) with top level `tb_equiv` and the library folder
   `<radiant>/cae_library/simulation/verilog/uaplatform`. Pass:
   `TEST PASSED: VHDL-2008 and SystemVerilog implementations match cycle for cycle`.
6. **Fault injection (optional):** run [`scripts/make_tb_check.sh`](scripts/make_tb_check.sh), then
   simulate each `sim/mcp_sim/tb_check/<m>_vhdtb.f` and `<m>_svtb.f` as in step 4. Expected
   results are in [`docs/development_notes.md`](docs/development_notes.md).
7. **Full top-level elaboration:** elaborate [`lint_top_sv_filelist.f`](sim/lint_top_sv_filelist.f)
   and [`lint_top_vhdl_filelist.f`](sim/lint_top_vhdl_filelist.f) with top level
   `nexus_reconfig_top`, the precompiled Radiant device library `lfd2nx` and the `uaplatform`
   folder as in step 5. Pass: 0 errors.

## Running on the board

`LSC_REFRESH` reloads the configuration from the SPI flash, so the result depends on what the
flash holds. The board's FT2232H provides JTAG on channel A and the UART on channel B.

Chain files in [`lscc/`](lscc/), one set per implementation (`<L>` = `sv` or `vhdl`, using
`lscc/impl_<L>/nexus_reconfig_impl_<L>.bit`), for cable port `FTUSB-0`:

| File | Operation |
| :-- | :-- |
| `nexus_reconfig_verifyid_<L>_ftusb0.xcf`: [`sv`](lscc/nexus_reconfig_verifyid_sv_ftusb0.xcf), [`vhdl`](lscc/nexus_reconfig_verifyid_vhdl_ftusb0.xcf) | Verify ID (read-only board identification) |
| `nexus_reconfig_sram_<L>_ftusb0.xcf`: [`sv`](lscc/nexus_reconfig_sram_sv_ftusb0.xcf), [`vhdl`](lscc/nexus_reconfig_sram_vhdl_ftusb0.xcf) | Fast Configuration (SRAM, lost at power-off) |
| `nexus_reconfig_spiflash_<L>_ftusb0.xcf`: [`sv`](lscc/nexus_reconfig_spiflash_sv_ftusb0.xcf), [`vhdl`](lscc/nexus_reconfig_spiflash_vhdl_ftusb0.xcf) | External SPI flash: Erase, Program, Verify through the FPGA loader (JTAG2SPI) |
| `nexus_reconfig_refresh_<L>_ftusb0.xcf`: [`sv`](lscc/nexus_reconfig_refresh_sv_ftusb0.xcf), [`vhdl`](lscc/nexus_reconfig_refresh_vhdl_ftusb0.xcf) | JTAG Refresh: reload the configuration from the SPI flash |

The port number depends on the cables attached; change it in the chain file if the board is not
on `FTUSB-0`. The bitstream sizes are in the SPI flash chain files (`DataSize`); update them after
a rebuild that changes the size.

Procedure, with Radiant Programmer (GUI, or `pgrcmd -infile <chain file>`):

1. Verify ID with `nexus_reconfig_verifyid_<L>_ftusb0.xcf`.
2. Program the flash with `nexus_reconfig_spiflash_<L>_ftusb0.xcf` (Erase, Program, Verify).
3. Open a serial terminal on the board's channel B port at 115200 baud, 8N1.
4. Start the design from the flash: `nexus_reconfig_refresh_<L>_ftusb0.xcf` or a power cycle.
   Expected: the banner and `issuing LSC_REFRESH` repeating every 10 s.

To see the design refresh into a different image, load it into SRAM with
`nexus_reconfig_sram_<L>_ftusb0.xcf` while another design is in the flash: after the refresh,
the flash design starts.

## References

- sysCONFIG User Guide for Nexus Platform, FPGA-TN-02099-3.7, October 2026
  ([`docs/FPGA-TN-02099-sysCONFIG-User-Guide-Nexus.pdf`](docs/FPGA-TN-02099-sysCONFIG-User-Guide-Nexus.pdf)): Appendix D (CONFIG_LMMI), Table 6.18,
  Table 6.20, Table D.3.
- Multi-Boot User Guide for Nexus Platform, FPGA-TN-02145
  ([`docs/FPGA-TN-02145-Multi-Boot-User-Guide-Nexus.pdf`](docs/FPGA-TN-02145-Multi-Boot-User-Guide-Nexus.pdf)).
- Lattice Nexus Device Multi-Boot Reference Design, FPGA-RD-02294.
- Radiant 2026.1.1 help, FPGA Libraries Reference Guide, CONFIG_LMMI (architectures supported:
  LFD2NX).
