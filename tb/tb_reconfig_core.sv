// -----------------------------------------------------------------------------
// tb_reconfig_core.sv
//
// Self-checking testbench for reconfig_core / lmmi_refresh / uart_tx.
// It uses only the DUT ports, so it runs unchanged against both
// implementations: src/sv/*.sv (SystemVerilog) and src/vhdl/*.vhd (VHDL-2008).
//
// The CONFIG_LMMI primitive has no supported simulation model
// (FPGA-TN-02099-3.7, Table D.1 note 1), so lmmi_target_model below stands in
// for it. It implements the documented write protocol (Appendix D.3): a byte is
// accepted on a clock edge with lmmi_request && lmmi_ready, and lmmi_ready is
// randomly withheld to exercise back-pressure.
//
// Three DUT instances run in parallel, with scaled timing (1 MHz clock):
//   A  auto-refresh timer, button released:  banner, refresh message,
//      LSC_REFRESH 79 00 00 00, then the failure flash on led[0] because the
//      model does not reconfigure the device.
//   B  timer disabled, button pressed once:  same sequence, triggered by the
//      button.
//   C  timer disabled, button stuck low:     banner only, no LMMI transfer.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module lmmi_target_model #(
    parameter string NAME = "lmmi",
    parameter int    SEED = 1
) (
    input  logic       clk,
    input  logic       request,
    input  logic       wr_rdn,
    input  logic [7:0] offset,
    input  logic [7:0] wdata,
    output logic       ready
);
    logic [7:0] bytes [0:7];
    int         n_bytes   = 0;
    int         ready_run = 0;     // consecutive cycles with ready high
    int         errors    = 0;
    bit         prev_req  = 0;
    int         seed      = SEED;

    initial ready = 1'b1;

    always @(posedge clk) begin
        // Transfer accepted on this edge?
        if (request && ready) begin
            if (wr_rdn !== 1'b1) begin
                $display("[%s] ERROR: read transfer, LMMIWRRD_N=%b", NAME, wr_rdn); errors++;
            end
            if (offset !== 8'h01) begin
                $display("[%s] ERROR: LMMIOFFSET=%02h, expected 01", NAME, offset); errors++;
            end
            if (n_bytes < 8) bytes[n_bytes] = wdata;
            $display("[%s] %8.3f ms: byte %0d = %02h", NAME, $realtime / 1.0e6, n_bytes, wdata);
            n_bytes++;
        end
        // Start of a command: at least four ready cycles must precede it.
        if (request && !prev_req && ready_run < 4) begin
            $display("[%s] ERROR: request after only %0d ready cycles", NAME, ready_run); errors++;
        end
        prev_req  = request;
        ready_run = ready ? ready_run + 1 : 0;
        // Random back-pressure, about one cycle in three.
        ready <= (($urandom(seed) % 3) != 0);
        seed  = seed + 7;
    end

    function automatic bit refresh_seen();
        return n_bytes == 4 && bytes[0] == 8'h79 && bytes[1] == 8'h00 &&
               bytes[2] == 8'h00 && bytes[3] == 8'h00;
    endfunction
endmodule

module uart_monitor #(
    parameter string NAME = "uart",
    parameter int    BIT_NS = 20_000
) (
    input logic rxd
);
    string text = "";
    initial begin
        byte c;
        forever begin
            @(negedge rxd);
            #(BIT_NS / 2);
            if (rxd !== 1'b0) continue;            // glitch, not a start bit
            for (int i = 0; i < 8; i++) begin
                #(BIT_NS);
                c[i] = rxd;
            end
            #(BIT_NS);
            if (rxd !== 1'b1) $display("[%s] ERROR: framing error", NAME);
            text = {text, string'(c)};
        end
    end
endmodule

module tb_reconfig_core;

    localparam int CLK_HZ  = 1_000_000;
    localparam int BAUD    = 50_000;
    localparam int BIT_NS  = 1_000_000_000 / BAUD;
    localparam string MSG0 = "\015\012NexusReconfig: FPGA configured\015\012";
    localparam string MSG1 = "NexusReconfig: issuing LSC_REFRESH\015\012";

    logic clk = 1'b0;
    always #500 clk = ~clk;                         // 1 MHz

    int errors = 0;
    int past_a = 0, past_b = 0;
    bit b_btn_q = 1'b1;

    // ---------------- instance A: auto refresh ----------------
    logic       a_btn = 1'b1;
    logic [1:0] a_led;
    logic       a_txd, a_req, a_wr, a_rdy, a_done;
    logic [7:0] a_off, a_wd;

    reconfig_core #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .AUTO_REFRESH_MS(5), .BOOT_LED_MS(2),
                    .DEBOUNCE_MS(2), .POR_CYCLES(16)) dut_a (
        .clk_i(clk), .rst_no(), .btn_ni(a_btn), .led_o(a_led), .txd_o(a_txd),
        .lmmi_request_o(a_req), .lmmi_wr_rdn_o(a_wr), .lmmi_offset_o(a_off),
        .lmmi_wdata_o(a_wd), .lmmi_ready_i(a_rdy), .refresh_done_o(a_done));
    lmmi_target_model #(.NAME("A lmmi"), .SEED(11)) lmmi_a (
        .clk(clk), .request(a_req), .wr_rdn(a_wr), .offset(a_off), .wdata(a_wd), .ready(a_rdy));
    uart_monitor #(.NAME("A uart"), .BIT_NS(BIT_NS)) uart_a (.rxd(a_txd));

    // ---------------- instance B: button ----------------
    logic       b_btn = 1'b1;
    logic [1:0] b_led;
    logic       b_txd, b_req, b_wr, b_rdy, b_done;
    logic [7:0] b_off, b_wd;

    reconfig_core #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .AUTO_REFRESH_MS(0), .BOOT_LED_MS(2),
                    .DEBOUNCE_MS(2), .POR_CYCLES(16)) dut_b (
        .clk_i(clk), .rst_no(), .btn_ni(b_btn), .led_o(b_led), .txd_o(b_txd),
        .lmmi_request_o(b_req), .lmmi_wr_rdn_o(b_wr), .lmmi_offset_o(b_off),
        .lmmi_wdata_o(b_wd), .lmmi_ready_i(b_rdy), .refresh_done_o(b_done));
    lmmi_target_model #(.NAME("B lmmi"), .SEED(23)) lmmi_b (
        .clk(clk), .request(b_req), .wr_rdn(b_wr), .offset(b_off), .wdata(b_wd), .ready(b_rdy));
    uart_monitor #(.NAME("B uart"), .BIT_NS(BIT_NS)) uart_b (.rxd(b_txd));

    // ---------------- instance C: button stuck low ----------------
    logic       c_btn = 1'b0;
    logic [1:0] c_led;
    logic       c_txd, c_req, c_wr, c_rdy, c_done;
    logic [7:0] c_off, c_wd;

    reconfig_core #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .AUTO_REFRESH_MS(0), .BOOT_LED_MS(2),
                    .DEBOUNCE_MS(2), .POR_CYCLES(16)) dut_c (
        .clk_i(clk), .rst_no(), .btn_ni(c_btn), .led_o(c_led), .txd_o(c_txd),
        .lmmi_request_o(c_req), .lmmi_wr_rdn_o(c_wr), .lmmi_offset_o(c_off),
        .lmmi_wdata_o(c_wd), .lmmi_ready_i(c_rdy), .refresh_done_o(c_done));
    lmmi_target_model #(.NAME("C lmmi"), .SEED(37)) lmmi_c (
        .clk(clk), .request(c_req), .wr_rdn(c_wr), .offset(c_off), .wdata(c_wd), .ready(c_rdy));
    uart_monitor #(.NAME("C uart"), .BIT_NS(BIT_NS)) uart_c (.rxd(c_txd));

    // ---------------- checks during the run ----------------
    // The refresh must not start before the refresh message has fully left the UART.
    always @(posedge clk) begin
        if (a_req && uart_a.text != {MSG0, MSG1}) begin
            $display("ERROR: A: LMMI request before the UART message completed"); errors++;
        end
        if (b_req && uart_b.text != {MSG0, MSG1}) begin
            $display("ERROR: B: LMMI request before the UART message completed"); errors++;
        end
    end

    // Event log (time in ms). Uses only the DUT ports, so the same testbench
    // runs against the SystemVerilog and the VHDL implementation.
    always @(posedge clk) begin
        if (uart_a.text.len() != past_a) begin
            if (uart_a.text == MSG0)         $display("[A] %8.3f ms: banner received", $realtime / 1.0e6);
            if (uart_a.text == {MSG0, MSG1}) $display("[A] %8.3f ms: refresh message received", $realtime / 1.0e6);
        end
        if (uart_b.text.len() != past_b) begin
            if (uart_b.text == MSG0)         $display("[B] %8.3f ms: banner received", $realtime / 1.0e6);
            if (uart_b.text == {MSG0, MSG1}) $display("[B] %8.3f ms: refresh message received", $realtime / 1.0e6);
        end
        if (b_btn_q && !b_btn)               $display("[B] %8.3f ms: button pressed", $realtime / 1.0e6);
        past_a  = uart_a.text.len();
        past_b  = uart_b.text.len();
        b_btn_q = b_btn;
    end

    // led[0] must be on during the boot window.
    initial begin
        #(1_000_000);                               // 1 ms: inside BOOT_LED_MS = 2 ms
        if (a_led[0] !== 1'b1) begin $display("ERROR: A: boot LED not on at 1 ms"); errors++; end
        #(3_000_000);                               // 4 ms: after the boot window
        if (a_led[0] !== 1'b0) begin $display("ERROR: A: boot LED still on at 4 ms"); errors++; end
    end

    // Button press for instance B: after the banner (6.8 ms) and arming.
    initial begin
        #(12_000_000);
        b_btn = 1'b0;
        #(5_000_000);
        b_btn = 1'b1;
    end

    function automatic void check(string name, bit cond);
        if (!cond) begin $display("ERROR: %s", name); errors++; end
        else         $display("ok   : %s", name);
    endfunction

    task automatic count_toggles(input logic sig_is_a, output int n);
        logic prev;
        n = 0;
        prev = sig_is_a ? a_led[0] : b_led[0];
        repeat (150_000) begin               // 150 ms: fast flash toggles every 64 ms
            @(posedge clk);
            if ((sig_is_a ? a_led[0] : b_led[0]) !== prev) n++;
            prev = sig_is_a ? a_led[0] : b_led[0];
        end
    endtask

    initial begin
        int ta, tb;
        #(40_000_000);                              // 40 ms
        count_toggles(1'b1, ta);
        count_toggles(1'b0, tb);

        check("A: UART text = banner + refresh message", uart_a.text == {MSG0, MSG1});
        check("A: LSC_REFRESH 79 00 00 00 written, nothing else", lmmi_a.refresh_seen());
        check("A: refresh_done asserted", a_done === 1'b1);
        check("A: led[0] fast flash after unexecuted refresh", ta >= 2);
        check("B: UART text = banner + refresh message", uart_b.text == {MSG0, MSG1});
        check("B: LSC_REFRESH 79 00 00 00 written, nothing else", lmmi_b.refresh_seen());
        check("B: refresh_done asserted", b_done === 1'b1);
        check("B: led[0] fast flash after unexecuted refresh", tb >= 2);
        check("C: UART text = banner only", uart_c.text == MSG0);
        check("C: no LMMI transfer with button stuck low", lmmi_c.n_bytes == 0);
        check("C: refresh_done not asserted", c_done === 1'b0);
        check("A/B/C: heartbeat running", a_led[1] !== 1'bx && b_led[1] !== 1'bx);

        errors += lmmi_a.errors + lmmi_b.errors + lmmi_c.errors;
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #(400_000_000);
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

endmodule
