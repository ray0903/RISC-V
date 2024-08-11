module dcu (
    input                                  fclk_i,
    input                                  rst_i,
    
    //************ PFU ************//
    input         [INST_WIDTH-1:0]         pfu_inst_i,
    input         [GHSR_WIDTH-1:0]         pfu_ghsr_i,
    input         [PFU_PC_WIDTH-1:0]       pfu_pc_i,
    input                                  pfu_vld_i,
    input                                  pfu_j_b_en_i,
    output reg                             dcu_rdy_o,

    //*********** DPU *************//
    output reg                             dcu_vld_o,
    input                                  dpu_rdy_i,
    output reg    [GHSR_WIDTH-1:0]         dcu_ghsr_o,
    output reg    [INST_WIDTH-1:0]         dcu_inst_o,
    output reg    [DCU_PC_WIDTH-1:0]       dcu_pc_o,
    output reg    [XLEN-1:0]               dcu_rd_reg_o,

    //*********** STAGE CTRL **********//
    input                                  stc_stall_i,
    input                                  stc_redirect_i,
    input          [STC_PC_WIDTH-1:0]      stc_pc_i,

    //*********** REGISTER FILE *************//
    output reg       [XLEN-1:0]            dcu_rs1_o,
    output reg       [XLEN-1:0]            dcu_rs2_o,
    output reg                             dcu_wr_o             

);

//opration code decode
parameter      OP_INT_I     =   7'b001_0011,  //ADDI...
               OP_INT_R     =   7'b011_0011,  //ADD...
               OP_STORE     =   7'b010_0011,  //SB
               OP_LOAD      =   7'b000_0011,  //LB
               OP_IMM       =   7'b011_0111,  //LUI AUIPC
               OP_FENCE     =   7'b000_1111,  //FENCE
               OP_SYSE      =   7'b111_0011;  //ECALL...

//funct3 decode  INT_I
parameter      ADDI         =   3'b000,
               SLTI         =   3'b010,
               SLTIU        =   3'b011,
               XORI         =   3'b100,
               ORI          =   3'b110,
               ANDI         =   3'b111,
               SLLI         =   3'b001,
               SRI          =   3'b101;   //SRLI SRAI               








endmodule