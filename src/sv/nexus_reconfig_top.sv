// -----------------------------------------------------------------------------
// nexus_reconfig_top.sv
//
// NexusReconfig reference design: force a reconfiguration of a Certus-NX FPGA
// from internal logic by writing the LSC_REFRESH command to the configuration
// block through the CONFIG_LMMI primitive.
//
// Target: LFD2NX-40-8BG196C on the CRUVI Certus-NX board.
//
// Clocking follows FPGA-TN-02099-3.7 Appendix D.2 (Figure D.2): the OSC IP's
// hf_clk_out_o is the system clock and the LMMI clock source; the CONFIG_LMMI
// LMMICLK and LMMIRESETN pins must be driven from the OSC IP's lmmi_clk_o and
// lmmi_resetn_o pass-through outputs. RSTSMCLK and SMCLK are hardware inferred
// and left unconnected, as in FPGA-RD-02294.
// -----------------------------------------------------------------------------
module nexus_reconfig_top #(
    parameter int AUTO_REFRESH_MS = 10_000,   // 0 = button only
    parameter bit LED_ACTIVE_LOW  = 1'b0
) (
    input  logic       btn_ni,     // reconfiguration request button, active low
    output logic [1:0] led_o,      // [0] fresh-configuration indicator, [1] heartbeat
    output logic       txd_o       // UART 115200 8N1
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
        .BAUD            (115_200),
        .AUTO_REFRESH_MS (AUTO_REFRESH_MS),
        .LED_ACTIVE_LOW  (LED_ACTIVE_LOW)
    ) u_core (
        .clk_i          (sys_clk),
        .rst_no         (rst_n),
        .btn_ni         (btn_ni),
        .led_o          (led_o),
        .txd_o          (txd_o),
        .lmmi_request_o (lmmi_request),
        .lmmi_wr_rdn_o  (lmmi_wr_rdn),
        .lmmi_offset_o  (lmmi_offset),
        .lmmi_wdata_o   (lmmi_wdata),
        .lmmi_ready_i   (lmmi_ready),
        .refresh_done_o ()
    );

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
    ) /* synthesis syn_noprune=1 */;

endmodule
