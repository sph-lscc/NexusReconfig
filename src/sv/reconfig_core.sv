// -----------------------------------------------------------------------------
// reconfig_core.sv
//
// Reconfiguration logic of the NexusReconfig reference design (sv-led-blink
// variant: no UART, no LEDs), without device primitives, so it can be
// simulated with a behavioural LMMI target model.
//
// Behaviour:
//   1. After configuration, a power-on reset counter releases the logic.
//   2. A reconfiguration request comes from a falling edge on the debounced,
//      active-low button input, or from the auto-refresh timer AUTO_REFRESH_MS
//      after the reset release (0 disables the timer).
//   3. lmmi_refresh writes LSC_REFRESH to CONFIG_LMMI. The device reconfigures
//      from its boot source and the sequence starts again at step 1.
//   4. If the device is still running after the command (refresh not
//      executed), the sequencer stays in its final state with refresh_done_o
//      high.
// -----------------------------------------------------------------------------
module reconfig_core #(
    parameter int CLK_HZ          = 25_000_000,  // sys_clk frequency
    parameter int AUTO_REFRESH_MS = 10_000,      // 0 = button only
    parameter int DEBOUNCE_MS     = 20,
    parameter int POR_CYCLES      = 1_024,
    parameter int LMMI_GAP_CYCLES = 16
) (
    input  logic       clk_i,
    output logic       rst_no,          // released power-on reset (also drives the LMMI reset)

    input  logic       btn_ni,          // reconfiguration request, active low, asynchronous

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
    // Sequencer
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {M_RUN, M_REFRESH, M_WAIT} mstate_t;
    mstate_t mstate;

    localparam int AUTO_W = (AUTO_REFRESH_MS > 0) ? $clog2(AUTO_REFRESH_MS + 1) : 1;
    logic [AUTO_W-1:0] auto_cnt;
    logic              auto_event;
    logic              refresh_start, refresh_done;

    generate
        if (AUTO_REFRESH_MS > 0) begin : g_auto
            assign auto_event = ms_tick && (auto_cnt == AUTO_W'(AUTO_REFRESH_MS - 1));
        end else begin : g_no_auto
            assign auto_event = 1'b0;
        end
    endgenerate

    always_ff @(posedge clk_i) begin
        if (!rst_n) begin
            mstate        <= M_RUN;
            auto_cnt      <= '0;
            refresh_start <= 1'b0;
        end else begin
            refresh_start <= 1'b0;
            unique case (mstate)
                M_RUN: begin
                    if (ms_tick) auto_cnt <= auto_cnt + 1'b1;
                    if (btn_event || auto_event) begin
                        refresh_start <= 1'b1;
                        mstate        <= M_REFRESH;
                    end
                end
                M_REFRESH: begin
                    if (refresh_done) mstate <= M_WAIT;
                end
                M_WAIT: ;   // the device should be reconfiguring now
                default: mstate <= M_RUN;
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

endmodule
