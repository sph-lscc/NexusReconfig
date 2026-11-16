// -----------------------------------------------------------------------------
// led_blink.sv
//
// Free-running LED flasher, independent of the reconfiguration logic: it has
// no reset input and no connection to reconfig_core, the button, the
// auto-refresh timer or CONFIG_LMMI. Its registers start from their
// configuration-time value (0), so it starts flashing as soon as the device
// enters user mode and the clock runs.
//
// The only thing it shares with the rest of the design is the clock. A
// refresh reconfigures the whole device, so the flasher also restarts (LED off,
// counter at 0) after every LSC_REFRESH; that restart is a visible sign of the
// refresh.
// -----------------------------------------------------------------------------
module led_blink #(
    parameter int CLK_HZ     = 25_000_000,  // clk_i frequency
    parameter int HALF_MS    = 500,         // LED on time = off time (500 ms: 1 Hz)
    parameter bit ACTIVE_LOW = 1'b0         // 1 if the LED lights on a low level
) (
    input  logic clk_i,
    output logic led_o
);

    localparam int HALF_CYCLES = CLK_HZ / 1000 * HALF_MS;
    localparam int CNT_W       = $clog2(HALF_CYCLES);

    logic [CNT_W-1:0] cnt = '0;
    logic             led = 1'b0;

    always_ff @(posedge clk_i) begin
        if (cnt == CNT_W'(HALF_CYCLES - 1)) begin
            cnt <= '0;
            led <= ~led;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

    assign led_o = ACTIVE_LOW ? ~led : led;

endmodule
