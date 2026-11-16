// -----------------------------------------------------------------------------
// tb_equiv.sv
//
// Lock-step equivalence check of the two implementations of the design
// (sv-led-blink branch):
//
//   ref_reconfig_core, ref_led_blink   SystemVerilog sources in src/sv/, with the
//                                      module names prefixed by ref_
//                                      (scripts/make_sv_ref.sh)
//   reconfig_core, led_blink           VHDL-2008 sources in src/vhdl/
//
// Each equiv_pair instance drives both reconfig_core implementations with the
// same button and LMMI-ready stimulus and compares every output on every clock
// cycle from the release of the power-on reset (rst_no itself from time zero).
// Before the release the SystemVerilog registers are X and the VHDL enumerated
// state register starts at its leftmost value; on the device every register is
// cleared at the end of configuration. led_blink has no reset and initialised
// registers, so its outputs are compared from time zero, in both polarities.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module equiv_pair #(
    parameter string NAME            = "P",
    parameter int    SCENARIO        = 0,
    parameter int    SEED            = 1,
    parameter int    CLK_HZ          = 1_000_000,
    parameter int    AUTO_REFRESH_MS = 5,
    parameter int    DEBOUNCE_MS     = 2,
    parameter int    POR_CYCLES      = 16,
    parameter int    LMMI_GAP_CYCLES = 16
) (
    input logic clk
);
    // ---------------- shared stimulus ----------------
    logic btn   = (SCENARIO == 1 || SCENARIO == 2) ? 1'b0 : 1'b1;
    logic ready = 1'b1;

    // ---------------- reference (SystemVerilog) ----------------
    logic       r_rst_n, r_req, r_wr, r_done;
    logic [7:0] r_off, r_wd;

    ref_reconfig_core #(
        .CLK_HZ(CLK_HZ), .AUTO_REFRESH_MS(AUTO_REFRESH_MS), .DEBOUNCE_MS(DEBOUNCE_MS),
        .POR_CYCLES(POR_CYCLES), .LMMI_GAP_CYCLES(LMMI_GAP_CYCLES)
    ) u_ref (
        .clk_i(clk), .rst_no(r_rst_n), .btn_ni(btn),
        .lmmi_request_o(r_req), .lmmi_wr_rdn_o(r_wr), .lmmi_offset_o(r_off),
        .lmmi_wdata_o(r_wd), .lmmi_ready_i(ready), .refresh_done_o(r_done));

    // ---------------- conversion (VHDL-2008) ----------------
    logic       v_rst_n, v_req, v_wr, v_done;
    logic [7:0] v_off, v_wd;

    reconfig_core #(
        .CLK_HZ(CLK_HZ), .AUTO_REFRESH_MS(AUTO_REFRESH_MS), .DEBOUNCE_MS(DEBOUNCE_MS),
        .POR_CYCLES(POR_CYCLES), .LMMI_GAP_CYCLES(LMMI_GAP_CYCLES)
    ) u_vhd (
        .clk_i(clk), .rst_no(v_rst_n), .btn_ni(btn),
        .lmmi_request_o(v_req), .lmmi_wr_rdn_o(v_wr), .lmmi_offset_o(v_off),
        .lmmi_wdata_o(v_wd), .lmmi_ready_i(ready), .refresh_done_o(v_done));

    // ---------------- comparison ----------------
    localparam int W = 1 + 1 + 1 + 8 + 8 + 1;
    wire [W-1:0] r_vec = {r_rst_n, r_req, r_wr, r_off, r_wd, r_done};
    wire [W-1:0] v_vec = {v_rst_n, v_req, v_wr, v_off, v_wd, v_done};

    int  errors     = 0;
    int  compared   = 0;      // cycles with the full output vector compared
    int  lmmi_bytes = 0;
    bit  done_seen  = 0;

    function automatic void mismatch(string what);
        errors++;
        if (errors <= 10)
            $display("[%s] ERROR %8.3f ms: %s  ref=%h vhdl=%h", NAME, $realtime / 1.0e6, what, r_vec, v_vec);
    endfunction

    // Compare on the falling edge (all outputs settled), then drive the next
    // stimulus, so both implementations see identical inputs at the rising edge.
    always @(negedge clk) begin
        if (r_rst_n !== v_rst_n) mismatch("rst_no differs");
        if (r_rst_n === 1'b1) begin
            compared++;
            if (r_vec !== v_vec) mismatch("outputs differ");
            if (r_req && ready)  lmmi_bytes++;
            if (r_done)          done_seen = 1;
        end
        drive_stimulus();
    end

    // ---------------- stimulus ----------------
    int seed = SEED;
    int cyc  = 0;
    int ready_hold = 0;

    // Deterministic per-instance pseudo-random numbers (linear congruential).
    function automatic int rnd(int n);
        seed = seed * 1103515245 + 12345;
        return ((seed >>> 16) & 32'h7fff) % n;
    endfunction

    // Button level for a bouncing transition: random toggles for ~1 ms
    // around the edge, then the final level.
    function automatic logic bounce(int t, int edge_t, logic after);
        if (t < edge_t)        return ~after;
        if (t < edge_t + 1000) return (rnd(4) == 0) ? ~btn : btn;
        return after;
    endfunction

    task automatic drive_stimulus();
        cyc++;
        // LMMI ready
        case (SCENARIO)
            2:       ready = 1'b1;
            3: begin                                     // long random stretches
                if (ready_hold > 0) ready_hold--;
                else begin ready = ~ready; ready_hold = rnd(40); end
            end
            default: ready = (rnd(3) != 0);              // about one cycle in three low
        endcase
        // Button (1 MHz clock: cyc = microseconds)
        case (SCENARIO)
            0: btn = 1'b1;
            1: begin
                if      (cyc <  6_000) btn = 1'b0;                         // stuck low at start
                else if (cyc <  8_000) btn = bounce(cyc,  6_000, 1'b1);    // bouncing release
                else if (cyc < 12_000) btn = 1'b1;
                else if (cyc < 13_000) btn = 1'b0;                         // 1 ms glitch (< debounce)
                else if (cyc < 20_000) btn = 1'b1;
                else if (cyc < 26_000) btn = bounce(cyc, 20_000, 1'b0);    // bouncing press
                else                   btn = bounce(cyc, 26_000, 1'b1);    // bouncing release
            end
            2: btn = 1'b0;
            3: if (rnd(300) == 0) btn = ~btn;                              // random noise
            default: btn = 1'b1;
        endcase
    endtask

    function automatic void report();
        $display("[%s] cycles compared %0d, mismatches %0d | LMMI bytes %0d, refresh_done %0d",
                 NAME, compared, errors, lmmi_bytes, done_seen);
    endfunction
endmodule

// led_blink: SystemVerilog and VHDL side by side, compared from time zero.
module blink_pair #(
    parameter string NAME       = "L",
    parameter int    HALF_MS    = 2,
    parameter bit    ACTIVE_LOW = 1'b0
) (
    input logic clk
);
    logic r_led, v_led;
    int   errors = 0, compared = 0, edges = 0;
    logic prev;

    ref_led_blink #(.CLK_HZ(1_000_000), .HALF_MS(HALF_MS), .ACTIVE_LOW(ACTIVE_LOW)) u_ref (
        .clk_i(clk), .led_o(r_led));
    led_blink     #(.CLK_HZ(1_000_000), .HALF_MS(HALF_MS), .ACTIVE_LOW(ACTIVE_LOW)) u_vhd (
        .clk_i(clk), .led_o(v_led));

    always @(negedge clk) begin
        compared++;
        if (r_led !== v_led || $isunknown(r_led)) begin
            errors++;
            if (errors <= 10) $display("[%s] ERROR %8.3f ms: ref=%b vhdl=%b", NAME, $realtime / 1.0e6, r_led, v_led);
        end
        if (compared > 1 && r_led !== prev) edges++;
        prev = r_led;
    end

    function automatic void report();
        $display("[%s] cycles compared %0d, mismatches %0d | LED edges %0d", NAME, compared, errors, edges);
    endfunction
endmodule

module tb_equiv;
    logic clk = 1'b0;
    always #500 clk = ~clk;                          // 1 MHz

    localparam int RUN_MS = 60;

    // P0: auto-refresh timer, button released, random back-pressure.
    equiv_pair #(.NAME("P0 auto"), .SCENARIO(0), .SEED(11), .AUTO_REFRESH_MS(5)) p0 (.clk(clk));
    // P1: button only, stuck low at start, bounce, short glitch, real press.
    equiv_pair #(.NAME("P1 button"), .SCENARIO(1), .SEED(23), .AUTO_REFRESH_MS(0)) p1 (.clk(clk));
    // P2: button stuck low, timer disabled: no refresh may start.
    equiv_pair #(.NAME("P2 stuck"), .SCENARIO(2), .SEED(37), .AUTO_REFRESH_MS(0)) p2 (.clk(clk));
    // P3: LMMI gap 4, button noise, long ready stretches, other timing.
    equiv_pair #(.NAME("P3 noise"), .SCENARIO(3), .SEED(41), .AUTO_REFRESH_MS(4),
                 .LMMI_GAP_CYCLES(4), .DEBOUNCE_MS(1), .POR_CYCLES(100)) p3 (.clk(clk));
    // L0/L1: LED flasher, active high and active low.
    blink_pair #(.NAME("L0 led"), .HALF_MS(2), .ACTIVE_LOW(1'b0)) l0 (.clk(clk));
    blink_pair #(.NAME("L1 led_n"), .HALF_MS(3), .ACTIVE_LOW(1'b1)) l1 (.clk(clk));

    initial begin
        int errors;
        bit covered;
        #(RUN_MS * 1_000_000);
        p0.report(); p1.report(); p2.report(); p3.report(); l0.report(); l1.report();
        errors = p0.errors + p1.errors + p2.errors + p3.errors + l0.errors + l1.errors;
        // The stimulus must actually have exercised the design.
        covered = p0.done_seen && p1.done_seen && !p2.done_seen && p3.done_seen &&
                  p0.lmmi_bytes == 4 && p1.lmmi_bytes == 4 && p2.lmmi_bytes == 0 &&
                  p3.lmmi_bytes == 4 && l0.edges >= 29 && l1.edges >= 19;
        if (!covered) begin
            $display("ERROR: stimulus coverage incomplete"); errors++;
        end
        if (errors == 0) $display("TEST PASSED: VHDL-2008 and SystemVerilog implementations match cycle for cycle");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end
endmodule
