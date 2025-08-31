module ALU
(
    input  [31:0]                 op1_i,
    input  [31:0]                 op2_i,
    
    input                         is_branch_i,  //just include branch
    input                         is_jal_i,
    input                         is_jalr_i,
    input                         is_sub_i,

    input                         adder_used_i,
    input  [5:0]                  logic_adder_result_sel_i,
    input  [7:0]                  normal_logic_used_i,

    output reg [31:0]             alu_result_o,
    output                        branch_taken_o,
    output reg [`PC_WIDHT-1:0]    branch_pc_o,

    output                        alu_ready_o
);

wire      [31:0]    adder_result;
wire                logic_adder_result;
wire                branch_condition;

assign alu_ready_o      = 1'b1; //combinational logic, always ready

assign branch_condition = is_jal_i | is_jalr_i | is_branch_i;

//***** branch pc *****//
assign branch_pc_o    =  {`PC_WIDTH{is_jal_i}} & adder_result
                       | {`PC_WIDTH{is_jalr_i}} & (adder_result & ~1)  //jalr pc[0] must be zero
                       | {`PC_WIDTH{is_branch_i & logic_adder_result}} & adder_result; //branch pc

assign branch_taken_o = is_jal_i | is_jalr_i | (is_branch_i & logic_adder_result); 

assign alu_result_o   =  {32{adder_used_i}} & adder_result
                       | {32{~adder_used_i}} & normal_logic_result
                       | {32{(~branch_condition & (|logic_adder_result_sel_i))}} & logic_adder_result; //normal logic result

//***** logic adder *****//
LOGIC_ADDER #(
    .XLEN(32)
) u_LOGIC_ADDER (
    .a_i                  (op1_i                   ),
    .b_i                  (op2_i                   ),
    .sub_i                (1'b1                    ), //always add
    .sel_i                (logic_adder_result_sel_i),
    .sum_o                (                        ),
    .cout_o               (                        ),
    .logic_adder_result_o (logic_adder_result      )
);
//***** end logic adder *****//

//***** adder *****//
ADDER #(
    .XLEN(32)
) u_ADDER (
    .a_i    (op1_i       ),
    .b_i    (op2_i       ),
    .sub_i  (is_sub_i    ), //always add
    .sum_o  (adder_result),
    .cout_o (            )
);
//***** end adder *****//

//***** normal logic *****//
NORMAL_LOGIC #(
    .WIDTH(32)
) u_NORMAL_LOGIC (
    .op1_i     (op1_i                ),
    .op2_i     (op2_i                ),
    .sel_i     (normal_logic_used_i  ),
    .result_o  (normal_logic_result  )
);
//***** end normal logic *****//






endmodule