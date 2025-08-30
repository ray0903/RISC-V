module rv_addsub_cmp #(
  parameter XLEN = 32
)(
  input  [XLEN-1:0] a_i,
  input  [XLEN-1:0] b_i,
  input             sub_i,     // 0: add (A+B), 1: sub (A-B = A+~B+1)

  output [XLEN-1:0] sum_o,     // result
  output            cout_o,    // carry-out of MSB (valid for add path)
  output            borrow_o,  // ~cout for sub path (valid when sub_i=1)
  output            zero_o,    // sum_o == 0
  output            neg_o,     // sum_o[XLEN-1]
  output            ovf_o,     // signed overflow (auto-selected by op)

  // Compare results (valid when sub_i=1, i.e., on A-B path)
  output            eq_o,      // A == B
  output            ne_o,      // A != B
  output            ltu_o,     // A <  B (unsigned)
  output            geu_o,     // A >= B (unsigned)
  output            lts_o,     // A <  B (signed)
  output            ges_o      // A >= B (signed)
);

  // B mux: ~B for subtraction, B for addition
  wire [XLEN-1:0] b_mux = sub_i ? ~b_i : b_i;

  // Single adder does both add/sub via Cin=sub_i
  wire [XLEN:0]   sum_ext = {1'b0, a_i} + {1'b0, b_mux} + sub_i;

  assign sum_o    = sum_ext[XLEN-1:0];
  assign cout_o   = sum_ext[XLEN];           // carry-out of MSB
  assign borrow_o = sub_i ? ~cout_o : 1'b0;  // only meaningful for subtraction

  // Basic flags
  assign zero_o = (sum_o == {XLEN{1'b0}});
  assign neg_o  = sum_o[XLEN-1];

  // Signed overflow
  wire ovf_add = (~(a_i[XLEN-1] ^ b_i[XLEN-1])) & (a_i[XLEN-1] ^ sum_o[XLEN-1]);
  wire ovf_sub =  (a_i[XLEN-1] ^ b_i[XLEN-1])  & (a_i[XLEN-1] ^ sum_o[XLEN-1]);
  assign ovf_o  = sub_i ? ovf_sub : ovf_add;

  // Compare (valid when sub_i=1; we computed A-B)
  assign eq_o  = zero_o;
  assign ne_o  = ~zero_o;

  assign ltu_o = sub_i ? ~cout_o : 1'b0;     // unsigned A < B
  assign geu_o = sub_i ?  cout_o : 1'b1;     // unsigned A >= B

  assign lts_o = sub_i ? (sum_o[XLEN-1] ^ ovf_o) : 1'b0; // signed A < B
  assign ges_o = sub_i ? ~(sum_o[XLEN-1] ^ ovf_o) : 1'b1; // signed A >= B

endmodule
