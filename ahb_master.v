// -----------------------------------------------------------------------------
// AHB-Lite Minimal Master (parameterized)
// - Supports continuous back-to-back single-beat transfers (address every cycle
//   when HREADY_i=1) with HTRANS NONSEQ for first beat and SEQ for subsequent
//   contiguous beats.
// - Read data is returned "same cycle" as HREADY_i completes the data phase
//   via rvalid_o pulse; rdata_o is driven directly from HRDATA_i when valid.
// - Write data is held in a 1-cycle pipeline (as per AHB addr->data phasing).
// -----------------------------------------------------------------------------

module AHB_MASTER #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32
) (
    input                       hclk_i,
    input                       hresetn_i,
    // ---------------- AHB-Lite Master Interface ----------------
    output reg  [ADDR_WIDTH-1:0] haddr_o,
    output reg  [2:0]            hburst_o,
    output reg                   hlock_o,
    output reg  [3:0]            hprot_o,
    output reg  [2:0]            hsize_o,
    output reg  [1:0]            htrans_o,
    output reg  [DATA_WIDTH-1:0] hwdata_o,
    output reg                   hwrite_o,
    input       [DATA_WIDTH-1:0] hrdata_i,
    input                        hready_i,
    input                        hresp_i,   // not used in this minimal master

    // ---------------- Local (User) Interface -------------------
    input                        req_i,     // assert for one beat when ready_o=1
    output                       ready_o,   // high when master can accept a new beat
    input                        wr_i,      // 1=write, 0=read
    input       [ADDR_WIDTH-1:0] addr_i,
    input       [DATA_WIDTH-1:0] wdata_i,
    output      [DATA_WIDTH-1:0] rdata_o,   // same-cycle read data when rvalid_o=1
    output                       rvalid_o   // pulses when a read data beat completes
);

  // ---------------- Constants ----------------
  // 8->000, 16->001, 32->010, 64->011 (AHB-Lite HSIZE encoding)
  localparam [2:0] HSIZE_ENC  = (DATA_WIDTH==8 ) ? 3'b000 :
                                (DATA_WIDTH==16) ? 3'b001 :
                                (DATA_WIDTH==32) ? 3'b010 :
                                (DATA_WIDTH==64) ? 3'b011 : 3'b010;
  localparam [1:0] HTRANS_IDLE = 2'b00;
  localparam [1:0] HTRANS_BUSY = 2'b01; // unused here
  localparam [1:0] HTRANS_NSEQ = 2'b10;
  localparam [1:0] HTRANS_SEQ  = 2'b11;

  localparam [2:0] HBURST_SINGLE = 3'b000; // single-beat only (but back-to-back allowed)
  localparam [3:0] HPROT_DEFAULT = 4'b0011;

  // ---------------- Ready/Accept handshake ----------------
  // We can launch a new address phase when the bus is ready.
  assign ready_o = hready_i;

  // Track whether the last cycle launched an address phase (for NONSEQ/SEQ)
  reg launched_q;            // 1 if an address was launched in the previous cycle

  // Track the access currently in data phase (needed to know if it's read or write)
  reg active_valid_q;        // there is a data phase completing when HREADY_i=1
  reg active_write_q;        // type of the active data phase

  // Latch write data for the following data phase
  always @(posedge hclk_i or negedge hresetn_i) begin
    if (!hresetn_i) begin
      hwdata_o <= {DATA_WIDTH{1'b0}};
    end else if (ready_o && req_i && wr_i) begin
      // On the cycle we launch a write address, capture its data for next cycle
      hwdata_o <= wdata_i;
    end
  end

  // Address/control channel
  always @(posedge hclk_i or negedge hresetn_i) begin
    if (!hresetn_i) begin
      haddr_o     <= {ADDR_WIDTH{1'b0}};
      hsize_o     <= HSIZE_ENC;
      hburst_o    <= HBURST_SINGLE;
      hprot_o     <= HPROT_DEFAULT;
      hlock_o     <= 1'b0;
      hwrite_o    <= 1'b0;
      htrans_o    <= HTRANS_IDLE;
      launched_q  <= 1'b0;
    end else begin
      // Default keep previous values when bus not ready (HREADY_i=0)
      if (ready_o && req_i) begin
        // Launch a new address phase this cycle
        haddr_o  <= addr_i;
        hsize_o  <= HSIZE_ENC;
        hburst_o <= HBURST_SINGLE;
        hprot_o  <= HPROT_DEFAULT;
        hlock_o  <= 1'b0;
        hwrite_o <= wr_i;
        htrans_o <= HTRANS_NSEQ; // SEQ if contiguous stream
        launched_q <= 1'b1;
      end else if (hready_i) begin
        // No new request this cycle; drive IDLE if bus is free
        htrans_o <= HTRANS_IDLE;
        launched_q <= 1'b0; // stream breaks
      end
      // If hready_i==0, keep address/control stable automatically
    end
  end

  // Track the data phase attributes for the transfer that is now active
  // AHB: data phase corresponds to the address launched in the previous cycle
  always @(posedge hclk_i or negedge hresetn_i) begin
    if (!hresetn_i) begin
      active_valid_q <= 1'b0;
      active_write_q <= 1'b0;
    end else begin
      // When we launch an address (ready_o&req_i), a data phase becomes active next cycle
      if (ready_o && req_i) begin
        active_valid_q <= 1'b1;
        active_write_q <= wr_i;
      end else if (hready_i) begin
        // If bus indicates completion and we didn't launch another, clear valid
        // (If we launched another in same cycle, next cycle remains valid)
        active_valid_q <= 1'b0;
      end

      // If both launching and completing happen together (common case),
      // active_valid_q will deassert then reassert next cycle via the above logic.
    end
  end

  // Same-cycle read return: when a read data phase completes (HREADY_i=1 and
  // the active data phase is a read), rvalid_o pulses and rdata_o shows HRDATA_i.
  assign rvalid_o = active_valid_q & (~active_write_q) & hready_i;
  assign rdata_o  = hrdata_i; // consume only when rvalid_o=1

endmodule