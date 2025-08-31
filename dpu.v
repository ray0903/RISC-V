module DPU (
    input                                     clk_i,
    input                                     rst_i,

    //****** PFU Interface ******//
    input                                     pfu2dpu_valid_i,
    input      [`INST_WIDTH-1:0]              pfu2dpu_inst_i,
    input      [`PC_WIDTH-1:0]                pfu2dpu_pc_i,
    output                                    dpu2pfu_ready_o,


    //****** Central control Interface ******//
    input                                     ctrl2dpu_flush_i,
    input                                     ctrl2dpu_stall_i,
    input                                     ctrl2dpu_valid_i,
    output reg [`PC_WIDHT-1:0]                dpu2ctrl_branch_pc_o,
    output reg                                dpu2ctrl_valid_o,        
    output                                    dpu2ctrl_ready_o
);
//****** input phase ******//
reg [`INST_WIDTH-1:0]              pfu2dpu_inst_reg;
reg [`PC_WIDHT-1:0]                pfu2dpu_pc_reg;


always @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        pfu2dpu_inst_reg <= `ZERO_INST;
        pfu2dpu_pc_reg   <= `ZERO_PC;
    end
    else if (pfu2dpu_valid_i && dpu2pfu_ready_o) begin
        pfu2dpu_inst_reg <= pfu2dpu_inst_i;
        pfu2dpu_pc_reg   <= pfu2dpu_pc_i;
    end
end
//****** end input phase ******//

//****** decode phase ******//
wire       [`XLEN-1:0]                     rs1_data_dec;
wire       [`XLEN-1:0]                     rs2_data_dec;

wire       [`RF_ADDR_WIDTH-1:0]            rd_addr_dec;
wire       [`RF_ADDR_WIDTH-1:0]            rs1_addr_dec;
wire       [`RF_ADDR_WIDTH-1:0]            rs2_addr_dec;
wire                                       is_jalr_dec;
wire                                       is_jal_dec;
wire                                       is_branch_dec;
wire                                       is_ld_st_dec;
wire                                       is_auipc_dec;
wire                                       is_lui_dec;
wire       [`XLEN-1:0]                     alu_op1_dec;
wire       [`XLEN-1:0]                     alu_op2_dec;
wire                                       csr_used_dec;
wire       [11:0]                          csr_addr_dec;
wire       [`XLEN-1:0]                     imm_dec;
wire       [7:0]                           normal_logic_used_dec;
wire                                       adder_used_dec;

DECODER u_DECODER (
    .inst_i                (pfu2dpu_inst_reg         ),
    .rs1_i                 (rs1_data_dec             ),
    .rs2_i                 (rs2_data_dec             ),

    .rd_addr_o             (rd_addr_dec              ),
    .rs1_addr_o            (rs1_addr_dec             ),
    .rs2_addr_o            (rs2_addr_dec             ),

    .is_jalr_o             (is_jalr_dec              ),
    .is_jal_o              (is_jal_dec               ),
    .is_branch_o           (is_branch_dec            ),
    .is_ld_st_o            (is_ld_st_dec             ),
   // .is_auipc_o            (is_auipc_dec             ),
    .is_lui_o              (is_lui_dec               ),

    .alu_op1_o             (alu_op1_dec              ),
    .alu_op2_o             (alu_op2_dec              ),

    .csr_used_o            (csr_used_dec             ),
    .csr_addr_o            (csr_addr_dec             ),
    .imm_o                 (imm_dec                  ),
    .normal_logic_used_o   (normal_logic_used_dec    ),
    .adder_used_o          (adder_used_dec           )
);



endmodule