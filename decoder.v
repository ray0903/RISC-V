module decoder (
    input  [31:0] inst_i,
    output       is_branch_o,
    output       is_jal_o,
    output       is_jalr_o,
    output       is_auipc_o,
    output       is_lui_o,
    output       is_ecall_o,
    output       is_mret_o,
    output       rs1_used_o,
    output       rs2_used_o,
    output [4:0] rd_addr_o,
    output [4:0] rs1_addr_o,
    output [4:0] rs2_addr_o,
    output [2:0] funct3_o,
    output [6:0] funct7_o
);