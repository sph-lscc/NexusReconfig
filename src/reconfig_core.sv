// -----------------------------------------------------------------------------
// reconfig_core.sv
//
// All user logic of the NexusReconfig reference design, without device
// primitives, so it can be simulated with a behavioural LMMI target model.
//
// Behaviour:
//   1. After configuration, a power-on reset counter releases the logic.
//   2. The UART prints "NexusReconfig: FPGA configured", led_o[0] lights for
//      BOOT_LED_MS (a fresh-configuration indicator) and led_o[1] blinks as a
//      heartbeat.
//   3. A reconfiguration request comes from a falling edge on the debounced,
//      active-low button input, or from the auto-refresh timer after
//      AUTO_REFRESH_MS (0 disables the timer).
//   4. The UART prints "NexusReconfig: issuing LSC_REFRESH", then lmmi_refresh
//      writes LSC_REFRESH to CONFIG_LMMI. The device reconfigures from its boot
//      source and the sequence starts again at step 1.
//   5. If the device is still running after the command (refresh not
//      executed), led_o[0] flashes quickly to show the failure.
// -----------------------------------------------------------------------------
module reconfig_core #(
    parameter int CLK_HZ          = 25_000_000,  // sys_clk frequency
    parameter int BAUD            = 115_200,
    parameter int AUTO_REFRESH_MS = 10_000,      // 0 = button only
    parameter int BOOT_LED_MS     = 2_000,
    parameter int DEBOUNCE_MS     = 20,
    parameter int POR_CYCLES      = 1_024,
    parameter bit LED_ACTIVE_LOW  = 1'b0,
    parameter int LMMI_GAP_CYCLES = 16
) (
    input  logic       clk_i,
    output logic       rst_no,          // released power-on reset (also drives the LMMI reset)

    input  logic       btn_ni,          // reconfiguration request, active low, asynchronous
    output logic [1:0] led_o,
    output logic       txd_o,

    // LMMI host port, connect to CONFIG_LMMI
    output logic       lmmi_request_o,
    output logic       lmmi_wr_rdn_o,
    output logic [7:0] lmmi_offset_o,
    output logic [7:0] lmmi_wdata_o,
    input  logic       lmmi_ready_i,

    output logic       refresh_done_o   // LSC_REFRESH fully accepted
);

    // ------------------------------------------------------------------
    // Power-on reset. Registers are cleared when configuration completes,
    // so the counter starts at zero.
    // ------------------------------------------------------------------
    localparam int POR_W = $clog2(POR_CYCLES + 1);
    logic [POR_W-1:0] por_cnt = '0;
    logic             rst_n   = 1'b0;

    always_ff @(posedge clk_i) begin
        if (por_cnt != POR_W'(POR_CYCLES)) por_cnt <= por_cnt + 1'b1;
        rst_n <= (por_cnt == POR_W'(POR_CYCLES));
    end
    assign rst_no = rst_n;

    // ------------------------------------------------------------------
    // Millisecond tick
    // ------------------------------------------------------------------
    localparam int MS_DIV = CLK_HZ / 1000;
    localparam int MS_W   = $clog2(MS_DIV);
    logic [MS_W-1:0] ms_cnt;
    logic            ms_tick;

    always_ff @(posedge clk_i) begin
        if (!rst_n) begin
            ms_cnt  <= '0;
            ms_tick <= 1'b0;
        end else begin
            ms_tick <= (ms_cnt == MS_W'(MS_DIV - 1));
            ms_cnt  <= (ms_cnt == MS_W'(MS_DIV - 1)) ? '0 : ms_cnt + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Button: synchroniser, debounce, falling-edge event. The event is only
    // armed after the input has been seen released (high), so a stuck-low
    // input cannot cause a refresh loop.
    // ------------------------------------------------------------------
    localparam int DB_W = $clog2(DEBOUNCE_MS + 1);
    logic [1:0]      btn_sync;
    logic            btn_db;          // debounced level, 1 = released
    logic [DB_W-1:0] db_cnt;
    logic            btn_armed;
    logic            btn_event;

    always_ff @(posedge clk_i) begin
        if (!rst_n) begin
            btn_sync  <= 2'b00;
            btn_db    <= 1'b0;
            db_cnt    <= '0;
            btn_armed <= 1'b0;
            btn_event <= 1'b0;
        end else begin
            btn_sync  <= {btn_sync[0], btn_ni};
            btn_event <= 1'b0;
            if (btn_sync[1] == btn_db) begin
                db_cnt <= '0;
            end else if (ms_tick) begin
                if (db_cnt == DB_W'(DEBOUNCE_MS)) begin
                    btn_db <= btn_sync[1];
                    db_cnt <= '0;
                    if (btn_sync[1])     btn_armed <= 1'b1;   // released
                    else if (btn_armed)  btn_event <= 1'b1;   // pressed
                end else begin
                    db_cnt <= db_cnt + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // UART messages
    // ------------------------------------------------------------------
    localparam int                MSG0_LEN = 34;
    localparam logic [8*34-1:0]   MSG0     = "\015\012NexusReconfig: FPGA configured\015\012";
    localparam int                MSG1_LEN = 36;
    localparam logic [8*36-1:0]   MSG1     = "NexusReconfig: issuing LSC_REFRESH\015\012";

    logic       msg_sel;              // 0 = MSG0, 1 = MSG1
    logic [5:0] char_idx;
    logic [7:0] tx_data;
    logic       tx_valid, tx_ready;
    logic       msg_last;

    always_comb begin
        if (!msg_sel) tx_data = MSG0[8*(MSG0_LEN-1-int'(char_idx)) +: 8];
        else          tx_data = MSG1[8*(MSG1_LEN-1-int'(char_idx)) +: 8];
        msg_last = msg_sel ? (char_idx == 6'(MSG1_LEN - 1)) : (char_idx == 6'(MSG0_LEN - 1));
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart_tx (
        .clk_i   (clk_i),
        .rst_ni  (rst_n),
        .valid_i (tx_valid),
        .data_i  (tx_data),
        .ready_o (tx_ready),
        .txd_o   (txd_o)
    );

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {M_BANNER, M_RUN, M_MSG, M_DRAIN, M_REFRESH, M_WAIT} mstate_t;
    mstate_t mstate;

    localparam int AUTO_W = (AUTO_REFRESH_MS > 0) ? $clog2(AUTO_REFRESH_MS + 1) : 1;
    logic [AUTO_W-1:0] auto_cnt;
    logic              auto_event;
    logic              refresh_start, refresh_done;
    logic [1:0]        drain_cnt;

    generate
        if (AUTO_REFRESH_MS > 0) begin : g_auto
            assign auto_event = ms_tick && (auto_cnt == AUTO_W'(AUTO_REFRESH_MS - 1));
        end else begin : g_no_auto
            assign auto_event = 1'b0;
        end
    endgenerate

    assign tx_valid = (mstate == M_BANNER) || (mstate == M_MSG);

    always_ff @(posedge clk_i) begin
        if (!rst_n) begin
            mstate        <= M_BANNER;
            msg_sel       <= 1'b0;
            char_idx      <= '0;
            auto_cnt      <= '0;
            drain_cnt     <= '0;
            refresh_start <= 1'b0;
        end else begin
            refresh_start <= 1'b0;
            unique case (mstate)
                M_BANNER, M_MSG: begin
                    if (tx_ready) begin
                        if (msg_last) begin
                            char_idx  <= '0;
                            drain_cnt <= '0;
                            mstate    <= (mstate == M_BANNER) ? M_RUN : M_DRAIN;
                        end else begin
                            char_idx <= char_idx + 1'b1;
                        end
                    end
                end
                M_RUN: begin
                    if (ms_tick) auto_cnt <= auto_cnt + 1'b1;
                    if (btn_event || auto_event) begin
                        msg_sel <= 1'b1;
                        mstate  <= M_MSG;
                    end
                end
                // Let the last character leave the UART before the device resets.
                M_DRAIN: begin
                    if (drain_cnt != 2'd3) drain_cnt <= drain_cnt + 1'b1;
                    else if (tx_ready) begin
                        refresh_start <= 1'b1;
                        mstate        <= M_REFRESH;
                    end
                end
                M_REFRESH: begin
                    if (refresh_done) mstate <= M_WAIT;
                end
                M_WAIT: ;   // the device should be reconfiguring now
                default: mstate <= M_BANNER;
            endcase
        end
    end

    lmmi_refresh #(.GAP_CYCLES(LMMI_GAP_CYCLES)) u_lmmi_refresh (
        .clk_i          (clk_i),
        .rst_ni         (rst_n),
        .start_i        (refresh_start),
        .busy_o         (),
        .done_o         (refresh_done),
        .lmmi_request_o (lmmi_request_o),
        .lmmi_wr_rdn_o  (lmmi_wr_rdn_o),
        .lmmi_offset_o  (lmmi_offset_o),
        .lmmi_wdata_o   (lmmi_wdata_o),
        .lmmi_ready_i   (lmmi_ready_i)
    );
    assign refresh_done_o = refresh_done;

    // ------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------
    localparam int BL_W = $clog2(BOOT_LED_MS + 1);
    logic [BL_W-1:0] boot_cnt;
    logic [7:0]      blink_cnt;       // ms counter for the blink patterns
    logic            boot_led, heartbeat, fail_flash;

    always_ff @(posedge clk_i) begin
        if (!rst_n) begin
            boot_cnt  <= '0;
            blink_cnt <= '0;
            boot_led  <= 1'b0;
            heartbeat <= 1'b0;
            fail_flash <= 1'b0;
        end else begin
            boot_led <= (boot_cnt != BL_W'(BOOT_LED_MS));
            if (ms_tick) begin
                if (boot_cnt != BL_W'(BOOT_LED_MS)) boot_cnt <= boot_cnt + 1'b1;
                if (blink_cnt == 8'd249) begin              // 250 ms: 2 Hz heartbeat
                    blink_cnt <= '0;
                    heartbeat <= ~heartbeat;
                end else begin
                    blink_cnt <= blink_cnt + 1'b1;
                end
                if (blink_cnt[5:0] == 6'd0) fail_flash <= ~fail_flash;   // 64 ms: fast flash
            end
        end
    end

    logic [1:0] led;
    assign led[0] = (mstate == M_WAIT) ? fail_flash : boot_led;
    assign led[1] = heartbeat;
    assign led_o  = LED_ACTIVE_LOW ? ~led : led;

endmodule
