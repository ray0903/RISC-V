// -----------------------------------------------------------------------------
// Parametric adder with carry-in, carry-out, and signed overflow flag
// - Unsigned carry-out (cout_o) is the MSB carry.
// - Signed overflow (ovf_o) triggers when A and B have same sign but SUM differs.
// -----------------------------------------------------------------------------
module ADDER_WITH_CARRY #(
    parameter integer WIDTH = 32
) (
    input  wire [WIDTH-1:0] a_i,     // operand A
    input  wire [WIDTH-1:0] b_i,     // operand B
    input  wire             cin_i,   // carry-in (0 or 1)
    output wire [WIDTH-1:0] sum_o,   // sum result
    output wire             cout_o,  // carry-out (unsigned)
    output wire             ovf_o    // signed overflow flag
);

    // Perform addition with carry-in. The concatenation naturally yields cout.
    assign {cout_o, sum_o} = a_i + b_i + cin_i;

    // Signed overflow: (MSB_A == MSB_B) && (MSB_SUM != MSB_A)
    assign ovf_o = (~(a_i[WIDTH-1] ^ b_i[WIDTH-1])) & (a_i[WIDTH-1] ^ sum_o[WIDTH-1]);

endmodule
