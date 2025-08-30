//****** ADD logic ******//
// Parametric adder with carry-in, carry-out, and signed overflow flag
// - Unsigned carry-out (cout_o) is the MSB carry.
// - Signed overflow (ovf_o): (MSB_A == MSB_B) && (MSB_SUM != MSB_A)
module  ADDER_WITH_CARRY#(
    parameter integer WIDTH = 32
) (
    input              [WIDTH-1:0] a_i,     // operand A
    input              [WIDTH-1:0] b_i,     // operand B
    input                           cin_i,  // carry-in (0 or 1)
    output             [WIDTH-1:0] sum_o,   // sum result
    output                          cout_o, // carry-out (unsigned)
    output                          ovf_o   // signed overflow flag
);

// raw add result with carry bit
wire [WIDTH:0] add_raw = {1'b0, a_i} + {1'b0, b_i} + cin_i;

//**** outputs ****//
assign sum_o  = add_raw[WIDTH-1:0];
assign cout_o = add_raw[WIDTH];
assign ovf_o  = (~(a_i[WIDTH-1] ^ b_i[WIDTH-1])) & (a_i[WIDTH-1] ^ sum_o[WIDTH-1]);

endmodule
