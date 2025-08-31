module LOGIC_ADDER #(
  parameter XLEN = 32
)(
  input  [XLEN-1:0] a_i,
  input  [XLEN-1:0] b_i,
  input             sub_i,     // 0: add (A+B), 1: sub (A-B = A+~B+1)
  input  [5:0]      sel_i,     // select output for logic_adder_result
                                 // 000001: EQ
                                 // 000001: NE
                                 // 000100: LTU
                                 // 001000: GEU
                                 // 010000: LT
                                 // 100000: GE
                                 // others: 0

  output [XLEN-1:0] sum_o,     // result
  output            cout_o,    // carry-out of MSB (valid for add path)
  output            borrow_o,  // ~cout for sub path (valid when sub_i=1)
  output            zero_o,    // sum_o == 0
  output            neg_o,     // sum_o[XLEN-1]
  output            ovf_o,     // signed overflow (auto-selected by op)

  // Compare results (valid when sub_i=1, i.e., on A-B path)
  output reg        logic_adder_result_o
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
  wire   eq    = zero_o;
  wire   ne    = ~zero_o;

  wire   ltu   = sub_i ? ~cout_o : 1'b0;     // unsigned A < B
  wire   geu   = sub_i ?  cout_o : 1'b1;     // unsigned A >= B

  wire   lts   = sub_i ? (sum_o[XLEN-1] ^ ovf_o) : 1'b0; // signed A < B
  wire   ges   = sub_i ? ~(sum_o[XLEN-1] ^ ovf_o) : 1'b1; // signed A >= B


//*** final output ***//
always @(*) begin
    case(sel_i)
        6'b00_0001: logic_adder_result_o = eq;   // EQ
        6'b00_0010: logic_adder_result_o = ne;   // NE
        6'b00_0100: logic_adder_result_o = ltu;  // LTU
        6'b00_1000: logic_adder_result_o = geu;  // GEU
        6'b01_0000: logic_adder_result_o = lts;  // LT
        6'b10_0000: logic_adder_result_o = ges;  // GE
        default   : logic_adder_result_o = 1'b0; // others
    endcase
end


endmodule
