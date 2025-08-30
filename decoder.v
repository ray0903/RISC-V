module decoder (
    input         [31:0]       inst_i,
    input         [31:0]       rs1_i,
    input         [31:0]       rs2_i,
    input         [31:0]       csr_reg_i,
    input         [31:0]       pc_i,
    output                     is_sub_o,    //for adder
    output                     is_branch_o, //for force pc
    output                     is_ld_st_o,  //for lsu
    output                     is_jal_o,    //for force pc
    output                     is_jalr_o,   //for force pc
    //output                   is_auipc_o,
    //output                   is_lui_o,
    output                     is_ecall_o,
    output                     is_ebreak_o
    output                     is_mret_o,    //for force pc
    output                     rs1_used_o,
    output                     rs2_used_o,
    output        [3:0]        rd_used_o, // 4'b0001: alu, 4'b0010: pc+4, 4'b0100: mem, 4'b1000: csr
    output                     pc_used_o, // whether the instruction needs the current PC value (for AUIPC, JAL, JALR, branches)
    output        [4:0]        rd_addr_o,
    output        [4:0]        rs1_addr_o,
    output        [4:0]        rs2_addr_o,
    output        [5:0]        alu_sel_o, 
    output        [31:0]       alu_op1_o,
    output        [31:0]       alu_op2_o,
    output                     csr_used_o,
    output        [11:0]       csr_addr_o,
    output        [2:0]        csr_op_o,
    output        [31:0]       imm_o,
    output reg    [7:0]        normal_logic_used_o,
    output                     adder_used_o,
    output reg    [6:0]        adder_result_sel_o, 
    output reg                 rd_result_sel_o,
    output reg                 csr_result_sel_o,
    output reg                 pc_result_sel_o
);
`include "inst_define.v"
localparam [2:0] CSR_OP_NONE = 3'b000;
localparam [2:0] CSR_OP_RW   = 3'b001;
localparam [2:0] CSR_OP_RS   = 3'b010;
localparam [2:0] CSR_OP_RC   = 3'b100;
    // Common field helpers
wire [6:0] opcode  = `OPCODE(inst_i);

// ---- Immediate rules in RV32I ----
// Most immediates are sign-extended (I/S/B/J).
// Exceptions:
//  - U-type (LUI/AUIPC): high 20 bits placed in [31:12], low 12 bits are zeros (no sign-extension).
//  - Shift-immediates (SLLI/SRLI/SRAI): use shamt = inst[24:20] as an unsigned 5-bit value.
//  - CSR immediate forms (CSRRWI/CSRRSI/CSRRCI): zimm = inst[19:15] (unsigned 5-bit); CSR address is still imm[31:20].

// Unsigned shift amount for I-type shifts
wire [4:0]  shamt_i   = inst_i[24:20];
// CSR immediate operand (zimm), zero-extended to 32 bits

// Immediate decodes (sign-extended to 32 bits except U-type, which fills low 12 bits with zeros)
wire [31:0] imm_i = {{20{inst_i[31]}}, inst_i[31:20]};                                   // I-type
wire [31:0] imm_s = {{20{inst_i[31]}}, inst_i[31:25], inst_i[11:7]};                      // S-type
wire [31:0] imm_b = {{19{inst_i[31]}}, inst_i[31], inst_i[7], inst_i[30:25], inst_i[11:8], 1'b0}; // B-type
wire [31:0] imm_u = {inst_i[31:12], 12'b0};                                               // U-type
wire [31:0] imm_j = {{11{inst_i[31]}}, inst_i[31], inst_i[19:12], inst_i[20], inst_i[30:21], 1'b0}; // J-type

// imm_o carries the instruction's primary immediate (e.g., CSR address for SYSTEM).
// Note: shift shamt and CSR zimm are exposed via shamt_i and csr_zimm respectively, not imm_o.
assign imm_o = (opcode == `OPCODE_OP_IMM)   ? imm_i :
               (opcode == `OPCODE_LOAD)     ? imm_i :
               (opcode == `OPCODE_JALR)     ? imm_i :
               (opcode == `OPCODE_SYSTEM)   ? imm_i :  // CSR* immediate forms still use I-type encoding
               (opcode == `OPCODE_STORE)    ? imm_s :
               (opcode == `OPCODE_BRANCH)   ? imm_b :
               (opcode == `OPCODE_LUI)      ? imm_u :
               (opcode == `OPCODE_AUIPC)    ? imm_u :
               (opcode == `OPCODE_JAL)      ? imm_j :
                                             32'b0;


assign rs1_used_o = `NEED_RS1(inst_i);
assign rs2_used_o = `NEED_RS2(inst_i);
assign rd_used_o  = `NEED_RD(inst_i);

assign rs1_addr_o = inst_i[19:15];
assign rs2_addr_o = inst_i[24:20];
assign rd_addr_o  = inst_i[11:7];

assign csr_used_o =   IS_CSRRW(inst_i)  
                    | IS_CSRRS(inst_i) 
                    | IS_CSRRC(inst_i) 
                    | IS_CSRRWI(inst_i)
                    | IS_CSRRSI(inst_i)
                    | IS_CSRRCI(inst_i);

assign csr_zimm5  = {27'd0,inst_i[19:15]};
assign csr_addr_o = inst_i[31:20];
assign csr_op_o   = (`FUNCT3(inst_i) == `F3_CSRRW || `FUNCT3(inst_i) == `F3_CSRRWI) ? CSR_OP_RW :
                    (`FUNCT3(inst_i) == `F3_CSRRS || `FUNCT3(inst_i) == `F3_CSRRSI) ? CSR_OP_RS :
                    (`FUNCT3(inst_i) == `F3_CSRRC || `FUNCT3(inst_i) == `F3_CSRRCI) ? CSR_OP_RC :
                    CSR_OP_NONE;

assign is_branch_o = (opcode == `OPCODE_BRANCH);
assign is_ld_st_o  = (opcode == `OPCODE_LOAD) | (opcode == `OPCODE_STORE);
assign is_jal_o    = (opcode == `OPCODE_JAL);
assign is_jalr_o   = (opcode == `OPCODE_JALR);
assign is_auipc_o  = (opcode == `OPCODE_AUIPC);
assign is_ecall_o  = (inst_i == `INST_ECALL);
assign is_ebreak_o = (inst_i == `INST_EBREAK);
assign is_mret_o   = (inst_i == `INST_MRET);
//assign is_lui_o    = (opcode == `OPCODE_LUI);   
assign is_sub_o    = `IS_SUB(inst_i);    

always@(*)begin
    case(1)
        `NEED_RS1(inst_i) : alu_op1_o = rs1_i;
        `NEED_PC(inst_i)  : alu_op1_o = pc_i;
        `NEED_ZERO(inst_i): alu_op1_o = 32'b0;
        `NEED_ZIMM(inst_i): alu_op1_o = csr_zimm5; // zero-extended 5-bit immediate for CSR immediate forms
        default           : alu_op1_o = 32'b0;
    endcase
end

always@(*)begin
    case(1)
        `NEED_RS2(inst_i)    : alu_op2_o = rs2_i;
        `NEED_IMM(inst_i)    : alu_op2_o = imm_o;
        `NEED_CSR(inst_i)    : alu_op2_o = csr_reg_i; // shift amount is zero-extended
        `NEED_SHAMT(inst_i)  : alu_op2_o = {27'd0, shamt_i}; // zero-extended shift amount
        default           : alu_op2_o = 32'b0;
    endcase
end

wire adder_used_o =  `IS_ADD(inst_i) | `IS_ADDI(inst_i) 
                   | `IS_SUB(inst_i) | `IS_SLT(inst_i) | `IS_SLTU(inst_i) | `IS_SLTI(inst_i) | `IS_SLTIU(inst_i)
                   | `IS_BEQ(inst_i) | `IS_BNE(inst_i) | `IS_BLT(inst_i) | `IS_BGE(inst_i) | `IS_BLTU(inst_i) | `IS_BGEU(inst_i)
                   | `IS_LB(inst_i)  | `IS_LH(inst_i)  | `IS_LW(inst_i)  | `IS_LBU(inst_i)  | `IS_LHU(inst_i)
                   | `IS_SB(inst_i)  | `IS_SH(inst_i)  | `IS_SW(inst_i)
                   | `IS_JAL(inst_i) | `IS_JALR(inst_i)
                   | `IS_AUIPC(inst_i);   

always@(*)begin
    case(1)
        `IS_AND(inst_i) | `IS_ANDI(inst_i)        : normal_logic_used_o = 8'b0000_0001;
        `IS_OR(inst_i)  | `IS_ORI(inst_i)         : normal_logic_used_o = 8'b0000_0010;
        `IS_SLL(inst_i) | `IS_SLLI(inst_i)        : normal_logic_used_o = 8'b0000_0100;
        `IS_SRL(inst_i) | `IS_SRLI(inst_i)        : normal_logic_used_o = 8'b0000_1000;
        `IS_SRA(inst_i) | `IS_SRAI(inst_i)        : normal_logic_used_o = 8'b0001_0000;
        `IS_XOR(inst_i) | `IS_XORI(inst_i)        : normal_logic_used_o = 8'b0010_0000;
        `IS_CSRRSI(inst_i) | `IS_CSRRS(inst_i)    : normal_logic_used_o = 8'b0100_0000;
        `IS_CSRRCI(inst_i) | `IS_CSRRC(inst_i)    : normal_logic_used_o = 8'b1000_0000;
        default                                   : normal_logic_used_o = 8'b0000_0000;
    endcase
end

always@(*)begin
    case(1)
        `IS_BEQ(inst_i)                                        : adder_result_sel_o = 7'b000_0001;  //use adder eq flag
        `IS_BNE(inst_i)                                        : adder_result_sel_o = 7'b000_0010;  //use adder ne flag
        `IS_BLT(inst_i)  | `IS_SLTU(inst_i) | `IS_SLTIU(inst_i): adder_result_sel_o = 7'b000_0100;  //use adder less than flag(unsigned) 
        `IS_BGE(inst_i)                                        : adder_result_sel_o = 7'b000_1000;  //use adder greater equal flag(unsigned)
        `IS_BLTU(inst_i) | `IS_SLT(inst_i) | `IS_SLTI(inst_i)  : adder_result_sel_o = 7'b001_0000;  //use adder less than flag(signed)
        `IS_BGEU(inst_i)                                       : adder_result_sel_o = 7'b010_0000;  //use adder greater equal flag(signed)
        default                                                : adder_result_sel_o = {adder_used_o,6'b00_0000};  //default adder
    endcase 
end

        
                          

endmodule