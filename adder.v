module LOGIC_ADDER #(
  parameter XLEN = 32
)(
  input  [XLEN-1:0] a_i,
  input  [XLEN-1:0] b_i,
  input             sub_i,     // 0: add (A+B), 1: sub (A-B = A+~B+1)

  output [XLEN-1:0] sum_o,     // result
  output            cout_o,    // carry-out of MSB (valid for add path)


);

  // B mux: ~B for subtraction, B for addition
  wire [XLEN-1:0] b_mux = sub_i ? ~b_i : b_i;

  // Single adder does both add/sub via Cin=sub_i
  wire [XLEN:0]   sum_ext = {1'b0, a_i} + {1'b0, b_mux} + sub_i;

  assign sum_o    = sum_ext[XLEN-1:0];
  assign cout_o   = sum_ext[XLEN];           // carry-out of MSB






endmodule
