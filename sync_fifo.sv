// ============================================================
// Parameterized Sync FIFO (single clock, same-cycle read)
//  - rdata_o always points to the head element (combinational)
//  - When re_i && ne_o, data can be read out in the same cycle
//  - ne_o = not empty flag
// ============================================================
module SYNC_FIFO #(
    parameter int WIDTH = 32,                  // Data width
    parameter int DEPTH = 16,                  // FIFO depth
    localparam int AW = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
    input  wire                 clk_i,         // Clock
    input  wire                 rstn_i,        // Asynchronous reset, active low

    // Write port
    input  wire                 we_i,          // Write enable
    input  wire [WIDTH-1:0]     wdata_i,       // Write data

    // Read port
    input  wire                 re_i,          // Read enable
    output wire [WIDTH-1:0]     rdata_o,       // Read data (combinational)
    output wire                 ne_o,          // Not empty

    // Optional status
    output wire                 empty_o,       // FIFO empty
    output wire                 full_o,        // FIFO full
    output logic [AW:0]         count_o        // FIFO element count
);

    // Internal memory
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    // Read/write pointers
    logic [AW-1:0] wptr_q, rptr_q;

    // Status flags
    assign empty_o = (count_o == 0);
    assign full_o  = (count_o == DEPTH);
    assign ne_o    = ~empty_o;

    // Combinational read: always output current head element
    assign rdata_o = mem[rptr_q];

    // Write/read handshake
    wire do_write = we_i && !full_o;
    wire do_read  = re_i && !empty_o;

    // Write logic
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            wptr_q <= '0;
        end else if (do_write) begin
            mem[wptr_q] <= wdata_i;
            if (wptr_q == DEPTH-1)
                wptr_q <= '0;
            else
                wptr_q <= wptr_q + 1'b1;
        end
    end

    // Read pointer update (data already available combinationally)
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            rptr_q <= '0;
        end else if (do_read) begin
            if (rptr_q == DEPTH-1)
                rptr_q <= '0;
            else
                rptr_q <= rptr_q + 1'b1;
        end
    end

    // Count update (supports simultaneous read & write)
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            count_o <= '0;
        end else begin
            unique case ({do_write, do_read})
                2'b10: count_o <= count_o + 1'b1; // write only
                2'b01: count_o <= count_o - 1'b1; // read only
                default: count_o <= count_o;      // idle or read+write
            endcase
        end
    end

endmodule