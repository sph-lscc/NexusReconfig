// -----------------------------------------------------------------------------
// nexus_reconfig_top.sv
//
// NexusReconfig reference design: force a reconfiguration of a Certus-NX FPGA
// from internal logic by writing the LSC_REFRESH command to the configuration
// block through the CONFIG_LMMI primitive.
//
// Target: LFD2NX-40-8BG196C on the CRUVI Certus-NX board.
//
// sv-led-blink variant: no UART and no status LEDs from the reconfiguration
// logic. A separate free-running flasher (led_blink) drives one LED; it shares
// only the clock with the reconfiguration logic.
//
// Clocking follows FPGA-TN-02099-3.7 Appendix D.2 (Figure D.2): the OSC IP's
// hf_clk_out_o is the system clock and the LMMI clock source; the CONFIG_LMMI
// LMMICLK and LMMIRESETN pins must be driven from the OSC IP's lmmi_clk_o and
// lmmi_resetn_o pass-through outputs. RSTSMCLK and SMCLK are hardware inferred
// and left unconnected, as in FPGA-RD-02294.
// -----------------------------------------------------------------------------
module nexus_reconfig_top #(
    parameter int AUTO_REFRESH_MS = 10_000,   // 0 = button only
    parameter int LED_HALF_MS     = 500,      // LED flash: on and off time (1 Hz)
    parameter bit LED_ACTIVE_LOW  = 1'b0
) (
    input  logic btn_ni,           // reconfiguration request button, active low
    output logic led_o             // free-running flasher, independent of the refresh logic
);

    localparam int SYS_CLK_HZ = 25_000_000;   // osc0: 450 MHz / 18

    logic       sys_clk;
    logic       rst_n;
    logic       lmmi_clk;
    logic       lmmi_resetn;
    logic       lmmi_request, lmmi_wr_rdn, lmmi_ready, lmmi_rdata_valid;
    logic [7:0] lmmi_offset, lmmi_wdata, lmmi_rdata;

    osc0 osc0_inst (
        .hf_out_en_i   (1'b1),
        .lmmi_clk_i    (sys_clk),
        .lmmi_resetn_i (rst_n),
        .hf_clk_out_o  (sys_clk),
        .smclk_rst_o   (),
        .lmmi_clk_o    (lmmi_clk),
        .lmmi_resetn_o (lmmi_resetn)
    );

    reconfig_core #(
        .CLK_HZ          (SYS_CLK_HZ),
        .AUTO_REFRESH_MS (AUTO_REFRESH_MS)
    ) u_core (
        .clk_i          (sys_clk),
        .rst_no         (rst_n),
        .btn_ni         (btn_ni),
        .lmmi_request_o (lmmi_request),
        .lmmi_wr_rdn_o  (lmmi_wr_rdn),
        .lmmi_offset_o  (lmmi_offset),
        .lmmi_wdata_o   (lmmi_wdata),
        .lmmi_ready_i   (lmmi_ready),
        .refresh_done_o ()
    );

    led_blink #(
        .CLK_HZ     (SYS_CLK_HZ),
        .HALF_MS    (LED_HALF_MS),
        .ACTIVE_LOW (LED_ACTIVE_LOW)
    ) u_led_blink (
        .clk_i (sys_clk),
        .led_o (led_o)
    );

    // Without the UART and LEDs, no device pin depends on reconfig_core: the
    // loop reconfig_core -> CONFIG_LMMI -> LMMIREADY -> reconfig_core has no
    // valid output. Two attributes on the instance keep it:
    //   syn_noprune  Synplify keeps the primitive although its outputs drive
    //                no pin (without it, CONFIG_LMMI is not in the netlist);
    //   NOCLIP       map keeps the primitive and the logic connected to it
    //                (without it, map removes the loop as unused logic).
    // Synplify passes NOCLIP to map as (* NOCLIP=1 *) on the instance in the
    // .vm netlist. See Readme, "Keeping the refresh logic: NOCLIP".
    CONFIG_LMMI #(
        .LMMI_EN ("EN")
    ) config_lmmi_inst (
        .LMMICLK        (lmmi_clk),
        .LMMIREQUEST    (lmmi_request),
        .LMMIWRRD_N     (lmmi_wr_rdn),
        .LMMIOFFSET     (lmmi_offset),
        .LMMIWDATA      (lmmi_wdata),
        .LMMIRESETN     (lmmi_resetn),
        .RSTSMCLK       (),                 // hardware inferred
        .SMCLK          (),                 // hardware inferred
        .LMMIRDATA      (lmmi_rdata),
        .LMMIREADY      (lmmi_ready),
        .LMMIRDATAVALID (lmmi_rdata_valid)
    ) /* synthesis syn_noprune=1 NOCLIP=1 */;

endmodule
