// -----------------------------------------------------------------------------
// lmmi_refresh.sv
//
// LMMI host that sends the LSC_REFRESH command (opcode 0x79) to the Nexus
// configuration block through the CONFIG_LMMI primitive. LSC_REFRESH is
// equivalent to toggling the PROGRAMN pin: the device clears its configuration
// SRAM and reloads its bitstream from the configured boot source (external SPI
// flash on Certus-NX). Once the command is accepted, this logic, and the rest
// of the user design, ceases to exist.
//
// Protocol (FPGA-TN-02099-3.7, Appendix D.3 and Table D.3):
//   - The configuration register has the fixed LMMI offset ADDR_CFG = 0x01.
//   - A command is one opcode byte followed by three operand bytes, written
//     back to back with lmmi_request and lmmi_wr_rdn held high. A byte is
//     accepted on a clock edge where lmmi_request and lmmi_ready are both high.
//   - LSC_REFRESH is the only Class D command and is executed as a Class C
//     command (no data bytes, no read-back).
//   - OPERAND1 = 0x00 keeps the Override ENABLE bit (bit 6) clear, so the
//     refresh uses the device's normal boot settings (Table 6.20).
//   - Wait at least four LMMI clock cycles after lmmi_ready is high before
//     issuing a command (GAP_CYCLES below, default 16).
//
// The command sequence follows the LSC_REFRESH step of the refresh controller
// in FPGA-RD-02294 (source/impl_1/refresh.v), without the Multi-Boot steps.
// -----------------------------------------------------------------------------
module lmmi_refresh #(
    parameter int GAP_CYCLES = 16   // LMMI idle cycles (with ready high) before the command
) (
    input  logic       clk_i,       // LMMI clock (same clock as CONFIG_LMMI LMMICLK)
    input  logic       rst_ni,      // active-low synchronous reset
    input  logic       start_i,     // one-cycle pulse: issue LSC_REFRESH
    output logic       busy_o,      // command in progress
    output logic       done_o,      // all four bytes accepted (device should now reconfigure)

    // LMMI host port, connect to CONFIG_LMMI
    output logic       lmmi_request_o,
    output logic       lmmi_wr_rdn_o,
    output logic [7:0] lmmi_offset_o,
    output logic [7:0] lmmi_wdata_o,
    input  logic       lmmi_ready_i
);

    localparam logic [7:0] ADDR_CFG    = 8'h01;   // CONFIG_LMMI configuration register offset
    localparam logic [7:0] LSC_REFRESH = 8'h79;   // opcode
    localparam logic [7:0] REFRESH_OP1 = 8'h00;   // OPERAND1: no boot-mode override
    localparam logic [7:0] REFRESH_OP2 = 8'h00;   // OPERAND2
    localparam logic [7:0] REFRESH_OP3 = 8'h00;   // OPERAND3

    localparam int GAP_W = $clog2(GAP_CYCLES + 1);

    typedef enum logic [1:0] {S_IDLE, S_GAP, S_SEND, S_DONE} state_t;

    state_t           state;
    logic [1:0]       byte_idx;
    logic [GAP_W-1:0] gap_cnt;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state    <= S_IDLE;
            byte_idx <= '0;
            gap_cnt  <= '0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    byte_idx <= '0;
                    gap_cnt  <= '0;
                    if (start_i) state <= S_GAP;
                end
                // Count GAP_CYCLES consecutive cycles with lmmi_ready high.
                S_GAP: begin
                    if (!lmmi_ready_i)                   gap_cnt <= '0;
                    else if (gap_cnt == GAP_W'(GAP_CYCLES)) state   <= S_SEND;
                    else                                 gap_cnt <= gap_cnt + 1'b1;
                end
                // Opcode and three operands, one byte per accepted transfer.
                S_SEND: begin
                    if (lmmi_ready_i) begin
                        if (byte_idx == 2'd3) state <= S_DONE;
                        byte_idx <= byte_idx + 1'b1;
                    end
                end
                // The device reconfigures; stay here if it does not.
                S_DONE: ;
                default: state <= S_IDLE;
            endcase
        end
    end

    always_comb begin
        unique case (byte_idx)
            2'd0:    lmmi_wdata_o = LSC_REFRESH;
            2'd1:    lmmi_wdata_o = REFRESH_OP1;
            2'd2:    lmmi_wdata_o = REFRESH_OP2;
            default: lmmi_wdata_o = REFRESH_OP3;
        endcase
    end

    assign lmmi_request_o = (state == S_SEND);
    assign lmmi_wr_rdn_o  = (state == S_SEND);
    assign lmmi_offset_o  = ADDR_CFG;
    assign busy_o         = (state == S_GAP) || (state == S_SEND);
    assign done_o         = (state == S_DONE);

endmodule
