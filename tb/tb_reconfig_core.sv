// -----------------------------------------------------------------------------
// tb_reconfig_core.sv
//
// Self-checking testbench for reconfig_core / lmmi_refresh and led_blink
// (sv-led-blink branch: no UART, no LEDs in reconfig_core).
//
// The CONFIG_LMMI primitive has no supported simulation model
// (FPGA-TN-02099-3.7, Table D.1 note 1), so lmmi_target_model below stands in
// for it. It implements the documented write protocol (Appendix D.3): a byte is
// accepted on a clock edge with lmmi_request && lmmi_ready, and lmmi_ready is
// randomly withheld to exercise back-pressure.
//
// Instances, with scaled timing (1 MHz clock):
//   A  auto-refresh timer (5 ms), button released: LSC_REFRESH 79 00 00 00,
//      not before the timer has expired.
//   B  timer disabled, button pressed once at 12 ms: the same command, not
//      before the press.
//   C  timer disabled, button stuck low: no LMMI transfer.
//   L  led_blink (2 ms half period) and an active-low copy: they flash from
//      time 0 with no reset, at the set rate, and are unaffected by the
//      refresh logic (they share only the clock).
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

module tb_reconfig_core;

    localparam int CLK_HZ   = 1_000_000;
    localparam int HALF_MS  = 2;

    logic clk = 1'b0;
    always #500 clk = ~clk;                         // 1 MHz

    int errors = 0;
    realtime a_first_req = -1, b_first_req = -1, b_press = -1;

    // ---------------- instance A: auto refresh ----------------
    logic       a_btn = 1'b1;
    logic       a_req, a_wr, a_rdy, a_done;
    logic [7:0] a_off, a_wd;

    reconfig_core #(.CLK_HZ(CLK_HZ), .AUTO_REFRESH_MS(5), .DEBOUNCE_MS(2),
                    .POR_CYCLES(16)) dut_a (
        .clk_i(clk), .rst_no(), .btn_ni(a_btn),
        .lmmi_request_o(a_req), .lmmi_wr_rdn_o(a_wr), .lmmi_offset_o(a_off),
        .lmmi_wdata_o(a_wd), .lmmi_ready_i(a_rdy), .refresh_done_o(a_done));
    lmmi_target_model #(.NAME("A lmmi"), .SEED(11)) lmmi_a (
        .clk(clk), .request(a_req), .wr_rdn(a_wr), .offset(a_off), .wdata(a_wd), .ready(a_rdy));

    // ---------------- instance B: button ----------------
    logic       b_btn = 1'b1;
    logic       b_req, b_wr, b_rdy, b_done;
    logic [7:0] b_off, b_wd;

    reconfig_core #(.CLK_HZ(CLK_HZ), .AUTO_REFRESH_MS(0), .DEBOUNCE_MS(2),
                    .POR_CYCLES(16)) dut_b (
        .clk_i(clk), .rst_no(), .btn_ni(b_btn),
        .lmmi_request_o(b_req), .lmmi_wr_rdn_o(b_wr), .lmmi_offset_o(b_off),
        .lmmi_wdata_o(b_wd), .lmmi_ready_i(b_rdy), .refresh_done_o(b_done));
    lmmi_target_model #(.NAME("B lmmi"), .SEED(23)) lmmi_b (
        .clk(clk), .request(b_req), .wr_rdn(b_wr), .offset(b_off), .wdata(b_wd), .ready(b_rdy));

    // ---------------- instance C: button stuck low ----------------
    logic       c_btn = 1'b0;
    logic       c_req, c_wr, c_rdy, c_done;
    logic [7:0] c_off, c_wd;

    reconfig_core #(.CLK_HZ(CLK_HZ), .AUTO_REFRESH_MS(0), .DEBOUNCE_MS(2),
                    .POR_CYCLES(16)) dut_c (
        .clk_i(clk), .rst_no(), .btn_ni(c_btn),
        .lmmi_request_o(c_req), .lmmi_wr_rdn_o(c_wr), .lmmi_offset_o(c_off),
        .lmmi_wdata_o(c_wd), .lmmi_ready_i(c_rdy), .refresh_done_o(c_done));
    lmmi_target_model #(.NAME("C lmmi"), .SEED(37)) lmmi_c (
        .clk(clk), .request(c_req), .wr_rdn(c_wr), .offset(c_off), .wdata(c_wd), .ready(c_rdy));

    // ---------------- instance L: LED flasher ----------------
    logic l_led, l_led_n;

    led_blink #(.CLK_HZ(CLK_HZ), .HALF_MS(HALF_MS), .ACTIVE_LOW(1'b0)) dut_l (
        .clk_i(clk), .led_o(l_led));
    led_blink #(.CLK_HZ(CLK_HZ), .HALF_MS(HALF_MS), .ACTIVE_LOW(1'b1)) dut_ln (
        .clk_i(clk), .led_o(l_led_n));

    // ---------------- event log ----------------
    always @(posedge clk) begin
        if (a_req && a_first_req < 0) begin
            a_first_req = $realtime;
            $display("[A] %8.3f ms: first LMMI request", $realtime / 1.0e6);
        end
        if (b_req && b_first_req < 0) begin
            b_first_req = $realtime;
            $display("[B] %8.3f ms: first LMMI request", $realtime / 1.0e6);
        end
    end

    // Button press for instance B, after the arming (released input seen).
    initial begin
        #(12_000_000);
        b_btn   = 1'b0;
        b_press = $realtime;
        $display("[B] %8.3f ms: button pressed", $realtime / 1.0e6);
        #(5_000_000);
        b_btn = 1'b1;
    end

    // LED: record every edge of l_led, check level and complement.
    realtime l_edges[$];
    always @(l_led) if ($realtime > 0) l_edges.push_back($realtime);
    always @(posedge clk) begin
        if (l_led_n !== ~l_led) begin
            $display("ERROR: L: active-low output is not the complement at %0t", $realtime); errors++;
        end
    end
    initial begin
        #(1);
        if (l_led !== 1'b0) begin $display("ERROR: L: LED not off at time 0"); errors++; end
    end

    function automatic void check(string name, bit cond);
        if (!cond) begin $display("ERROR: %s", name); errors++; end
        else         $display("ok   : %s", name);
    endfunction

    initial begin
        bit periods_ok;
        #(40_000_000);                              // 40 ms

        check("A: LSC_REFRESH 79 00 00 00 written, nothing else", lmmi_a.refresh_seen());
        check("A: refresh_done asserted", a_done === 1'b1);
        check("A: refresh not before the 5 ms timer (POR 16 us + 5 ms)",
              a_first_req >= 5_016_000.0);
        check("B: LSC_REFRESH 79 00 00 00 written, nothing else", lmmi_b.refresh_seen());
        check("B: refresh_done asserted", b_done === 1'b1);
        check("B: refresh only after the button press (+ 2 ms debounce)",
              b_press > 0 && b_first_req >= b_press + 2_000_000.0);
        check("C: no LMMI transfer with button stuck low", lmmi_c.n_bytes == 0);
        check("C: refresh_done not asserted", c_done === 1'b0);

        // 40 ms / 2 ms half period = 20 edges. The counter starts at 0 and the
        // LED toggles on the 2000th rising clock edge (1999.5 us), then every 2 ms.
        periods_ok = (l_edges.size() == 20);
        foreach (l_edges[i])
            if (l_edges[i] != (i + 1) * HALF_MS * 1_000_000.0 - 500.0) periods_ok = 0;
        check($sformatf("L: LED toggles every %0d ms from time 0 (%0d edges)", HALF_MS,
                        l_edges.size()), periods_ok);

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
