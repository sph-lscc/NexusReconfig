// -----------------------------------------------------------------------------
// uart_tx.sv
//
// Minimal UART transmitter, 8 data bits, no parity, 1 stop bit (8N1).
// -----------------------------------------------------------------------------
module uart_tx #(
    parameter int CLK_HZ = 25_000_000,
    parameter int BAUD   = 115_200
) (
    input  logic       clk_i,
    input  logic       rst_ni,     // active-low synchronous reset
    input  logic       valid_i,    // byte available
    input  logic [7:0] data_i,
    output logic       ready_o,    // byte taken on valid_i && ready_o
    output logic       txd_o
);

    localparam int DIV   = (CLK_HZ + BAUD / 2) / BAUD;   // clocks per bit, rounded
    localparam int DIV_W = $clog2(DIV);

    logic [DIV_W-1:0] baud_cnt;
    logic [3:0]       bit_cnt;     // 0 = idle, 1..10 = start, 8 data, stop
    logic [9:0]       shreg;       // {stop, data[7:0], start}

    assign ready_o = (bit_cnt == 4'd0);

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            baud_cnt <= '0;
            bit_cnt  <= '0;
            shreg    <= '1;
            txd_o    <= 1'b1;
        end else if (bit_cnt == 4'd0) begin
            txd_o <= 1'b1;
            if (valid_i) begin
                shreg    <= {1'b1, data_i, 1'b0};
                bit_cnt  <= 4'd10;
                baud_cnt <= '0;
            end
        end else begin
            txd_o <= shreg[0];
            if (baud_cnt == DIV_W'(DIV - 1)) begin
                baud_cnt <= '0;
                shreg    <= {1'b1, shreg[9:1]};
                bit_cnt  <= bit_cnt - 1'b1;
            end else begin
                baud_cnt <= baud_cnt + 1'b1;
            end
        end
    end

endmodule
