`ifndef RV32I_DECODE_DEFS_VH
`define RV32I_DECODE_DEFS_VH
// ============================================================
// RV32I decode defines (opcodes / functs / field & imm helpers)
// Author: <Ray>
// Note: RV32I only (no M/A/F/D/C extensions)
// ============================================================

// ------------------------ OPCODE ----------------------------
`define OPCODE_LUI        7'b0110111
`define OPCODE_AUIPC      7'b0010111
`define OPCODE_JAL        7'b1101111
`define OPCODE_JALR       7'b1100111
`define OPCODE_BRANCH     7'b1100011
`define OPCODE_LOAD       7'b0000011
`define OPCODE_STORE      7'b0100011
`define OPCODE_OP_IMM     7'b0010011   // I-type ALU immediate
`define OPCODE_OP         7'b0110011   // R-type ALU register
`define OPCODE_MISC_MEM   7'b0001111   // FENCE/FENCE.I
`define OPCODE_SYSTEM     7'b1110011   // ECALL/EBREAK/CSR

// ------------------------ FUNCT3 ----------------------------
// BRANCH
`define F3_BEQ            3'b000
`define F3_BNE            3'b001
`define F3_BLT            3'b100
`define F3_BGE            3'b101
`define F3_BLTU           3'b110
`define F3_BGEU           3'b111
// LOAD
`define F3_LB             3'b000
`define F3_LH             3'b001
`define F3_LW             3'b010
`define F3_LBU            3'b100
`define F3_LHU            3'b101
// STORE
`define F3_SB             3'b000
`define F3_SH             3'b001
`define F3_SW             3'b010
// OP-IMM / OP
`define F3_ADD_SUB_SLT    3'b000 // ADDI/ADD/SUB (R-type requires funct7)
`define F3_SLL            3'b001 // SLLI/SLL
`define F3_SLT            3'b010 // SLTI/SLT
`define F3_SLTU           3'b011 // SLTIU/SLTU
`define F3_XOR            3'b100 // XORI/XOR
`define F3_SRX            3'b101 // SRLI/SRAI & SRL/SRA (check funct7)
`define F3_OR             3'b110 // ORI/OR
`define F3_AND            3'b111 // ANDI/AND
// JALR
`define F3_JALR           3'b000
// MISC-MEM
`define F3_FENCE          3'b000
`define F3_FENCEI         3'b001
// SYSTEM (CSR/ECALL/EBREAK)
`define F3_PRIV           3'b000 // ECALL/EBREAK (imm12 distinguishes)
`define F3_CSRRW          3'b001
`define F3_CSRRS          3'b010
`define F3_CSRRC          3'b011
`define F3_CSRRWI         3'b101
`define F3_CSRRSI         3'b110
`define F3_CSRRCI         3'b111

// ------------------------ FUNCT7 ----------------------------
`define F7_ADD_SRL        7'b0000000
`define F7_SUB_SRA        7'b0100000

// ------------------------ Register numbers (ABI) ------------
`define X_ZERO            5'd0   // x0
`define X_RA              5'd1   // x1 (return address)
`define X_SP              5'd2   // x2
// ... continue if needed for x3..x31

// ------------------------ Field extraction macros -----------
// i: 32-bit instruction
`define OPCODE(i)         ( (i)[6:0] )
`define RD(i)             ( (i)[11:7] )
`define FUNCT3(i)         ( (i)[14:12] )
`define RS1(i)            ( (i)[19:15] )
`define RS2(i)            ( (i)[24:20] )
`define FUNCT7(i)         ( (i)[31:25] )

// ------------------------ Immediate generation --------------
// I-type: imm[31:20]
`define I_IMM(i)          ( {{20{(i)[31]}}, (i)[31:20]} )
// S-type: imm[31:25]‖imm[11:7]
`define S_IMM(i)          ( {{20{(i)[31]}}, (i)[31:25], (i)[11:7]} )
// B-type: imm[31]‖imm[7]‖imm[30:25]‖imm[11:8]‖0
`define B_IMM(i)          ( {{19{(i)[31]}}, (i)[31], (i)[7], (i)[30:25], (i)[11:8], 1'b0} )
// U-type: imm[31:12] << 12
`define U_IMM(i)          ( { (i)[31:12], 12'b0 } )
// J-type: imm[31]‖imm[19:12]‖imm[20]‖imm[30:21]‖0
`define J_IMM(i)          ( {{11{(i)[31]}}, (i)[31], (i)[19:12], (i)[20], (i)[30:21], 1'b0} )

// ------------------------ Top-level categories --------------
`define IS_LUI(i)         ( `OPCODE(i) == `OPCODE_LUI )
`define IS_AUIPC(i)       ( `OPCODE(i) == `OPCODE_AUIPC )
`define IS_JAL(i)         ( `OPCODE(i) == `OPCODE_JAL )
`define IS_JALR(i)        ( `OPCODE(i) == `OPCODE_JALR && `FUNCT3(i) == `F3_JALR )
`define IS_BRANCH(i)      ( `OPCODE(i) == `OPCODE_BRANCH )
`define IS_LOAD(i)        ( `OPCODE(i) == `OPCODE_LOAD )
`define IS_STORE(i)       ( `OPCODE(i) == `OPCODE_STORE )
`define IS_OP_IMM(i)      ( `OPCODE(i) == `OPCODE_OP_IMM )
`define IS_OP(i)          ( `OPCODE(i) == `OPCODE_OP )
`define IS_MISC_MEM(i)    ( `OPCODE(i) == `OPCODE_MISC_MEM )
`define IS_SYSTEM(i)      ( `OPCODE(i) == `OPCODE_SYSTEM )

// ------------------------ Specific instructions: BRANCH -----
`define IS_BEQ(i)         ( `IS_BRANCH(i) && `FUNCT3(i)==`F3_BEQ )
`define IS_BNE(i)         ( `IS_BRANCH(i) && `FUNCT3(i)==`F3_BNE )
`define IS_BLT(i)         ( `IS_BRANCH(i) && `FUNCT3(i)==`F3_BLT )
`define IS_BGE(i)         ( `IS_BRANCH(i) && `FUNCT3(i)==`F3_BGE )
`define IS_BLTU(i)        ( `IS_BRANCH(i) && `FUNCT3(i)==`F3_BLTU )
`define IS_BGEU(i)        ( `IS_BRANCH(i) && `FUNCT3(i)==`F3_BGEU )

// ------------------------ Specific instructions: LOAD -------
`define IS_LB(i)          ( `IS_LOAD(i) && `FUNCT3(i)==`F3_LB  )
`define IS_LH(i)          ( `IS_LOAD(i) && `FUNCT3(i)==`F3_LH  )
`define IS_LW(i)          ( `IS_LOAD(i) && `FUNCT3(i)==`F3_LW  )
`define IS_LBU(i)         ( `IS_LOAD(i) && `FUNCT3(i)==`F3_LBU )
`define IS_LHU(i)         ( `IS_LOAD(i) && `FUNCT3(i)==`F3_LHU )

// ------------------------ Specific instructions: STORE ------
`define IS_SB(i)          ( `IS_STORE(i) && `FUNCT3(i)==`F3_SB )
`define IS_SH(i)          ( `IS_STORE(i) && `FUNCT3(i)==`F3_SH )
`define IS_SW(i)          ( `IS_STORE(i) && `FUNCT3(i)==`F3_SW )

// ------------------------ Specific instructions: OP-IMM -----
`define IS_ADDI(i)        ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b000 )
`define IS_SLTI(i)        ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b010 )
`define IS_SLTIU(i)       ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b011 )
`define IS_XORI(i)        ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b100 )
`define IS_ORI(i)         ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b110 )
`define IS_ANDI(i)        ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b111 )
`define IS_SLLI(i)        ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b001 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_SRLI(i)        ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b101 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_SRAI(i)        ( `IS_OP_IMM(i) && `FUNCT3(i)==3'b101 && `FUNCT7(i)==`F7_SUB_SRA )

// ------------------------ Specific instructions: OP ---------
`define IS_ADD(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b000 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_SUB(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b000 && `FUNCT7(i)==`F7_SUB_SRA )
`define IS_SLL(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b001 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_SLT(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b010 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_SLTU(i)        ( `IS_OP(i) && `FUNCT3(i)==3'b011 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_XOR(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b100 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_SRL(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b101 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_SRA(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b101 && `FUNCT7(i)==`F7_SUB_SRA )
`define IS_OR(i)          ( `IS_OP(i) && `FUNCT3(i)==3'b110 && `FUNCT7(i)==`F7_ADD_SRL )
`define IS_AND(i)         ( `IS_OP(i) && `FUNCT3(i)==3'b111 && `FUNCT7(i)==`F7_ADD_SRL )

// ------------------------ Jumps ------------------------------
`define IS_LUI_INSTR(i)   ( `IS_LUI(i) )
`define IS_AUIPC_INSTR(i) ( `IS_AUIPC(i) )
`define IS_JAL_INSTR(i)   ( `IS_JAL(i) )
`define IS_JALR_INSTR(i)  ( `IS_JALR(i) )

// ------------------------ MISC-MEM --------------------------
`define IS_FENCE(i)       ( `IS_MISC_MEM(i) && `FUNCT3(i)==`F3_FENCE  )
`define IS_FENCE_I(i)     ( `IS_MISC_MEM(i) && `FUNCT3(i)==`F3_FENCEI )

// ------------------------ SYSTEM / PRIV / CSR ---------------
`define IS_ECALL(i)       ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_PRIV && `I_IMM(i)==12'd0 )
`define IS_EBREAK(i)      ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_PRIV && `I_IMM(i)==12'd1 )

`define IS_CSRRW(i)       ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_CSRRW )
`define IS_CSRRS(i)       ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_CSRRS )
`define IS_CSRRC(i)       ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_CSRRC )
`define IS_CSRRWI(i)      ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_CSRRWI )
`define IS_CSRRSI(i)      ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_CSRRSI )
`define IS_CSRRCI(i)      ( `IS_SYSTEM(i) && `FUNCT3(i)==`F3_CSRRCI )

// ------------------------ Convenience macros: call/ret ------
// call: jal/jalr with rd=ra
`define IS_CALL(i)        ( ( `IS_JAL(i) || `IS_JALR(i) ) && (`RD(i)==`X_RA) )
// ret: jalr x0, 0(ra)
`define IS_RET(i)         ( `IS_JALR(i) && (`RD(i)==`X_ZERO) && (`RS1(i)==`X_RA) && (`I_IMM(i)==12'd0) )

// ------------------------ Other -----------------------------
// NOP (semantically): addi x0, x0, 0
`define IS_NOP(i)         ( `IS_ADDI(i) && (`RD(i)==`X_ZERO) && (`RS1(i)==`X_ZERO) && (`I_IMM(i)==12'd0) )

// ------------------------ Registers needed by instructions ---
// Macro to determine if instruction needs rs1 register
`define NEED_RS1(i)       ( `IS_OP(i) || `IS_OP_IMM(i) || `IS_LOAD(i) || `IS_STORE(i) || `IS_BRANCH(i) || `IS_JALR(i) || `IS_CSRRW(i) || `IS_CSRRS(i) || `IS_CSRRC(i) || `IS_CSRRWI(i) || `IS_CSRRSI(i) || `IS_CSRRCI(i) )

// Macro to determine if instruction needs rs2 register
`define NEED_RS2(i)       ( `IS_OP(i) || `IS_STORE(i) || `IS_BRANCH(i) )

// Macro to determine if instruction writes to rd
`define NEED_RD(i) ( \
    `IS_OP(i)       || `IS_OP_IMM(i)   || \
    `IS_LOAD(i)     || \
    `IS_JAL(i)      || `IS_JALR(i)     || \
    `IS_LUI(i)      || `IS_AUIPC(i)    || \
    `IS_CSRRW(i)    || `IS_CSRRS(i)    || `IS_CSRRC(i) || \
    `IS_CSRRWI(i)   || `IS_CSRRSI(i)   || `IS_CSRRCI(i) \
)

// Macro to determine if instruction uses an immediate field
// Includes all RV32I formats that carry an immediate: I/S/B/U/J and SYSTEM
`define NEED_IMM(i) ( \
    `IS_OP_IMM(i)   || `IS_LOAD(i)   || `IS_STORE(i) || \
    `IS_BRANCH(i)   || `IS_JAL(i)    || `IS_JALR(i)  || \
    `IS_LUI(i)      || `IS_AUIPC(i)  || \
    `IS_SYSTEM(i) \
)

// Macro to determine if instruction needs the PC as an operand
// Used for PC-relative forms (targets or results based on PC): AUIPC, JAL, BRANCH
// Note: JALR target is rs1+imm, so PC is not an operand (though rd gets PC+4).
`define NEED_PC(i)  ( `IS_AUIPC(i) || `IS_JAL(i) || `IS_BRANCH(i) )

// Macro to determine if instruction needs constant zero as an operand
// RV32I: LUI result can be formed as 0 + U_IMM
`define NEED_ZERO(i) ( `IS_LUI(i) )

// Macro to determine if instruction accesses CSR
// True for all CSR read/modify/write forms, excluding ECALL/EBREAK
`define NEED_CSR(i) ( \
    `IS_CSRRW(i)  || `IS_CSRRS(i)  || `IS_CSRRC(i) || \
    `IS_CSRRWI(i) || `IS_CSRRSI(i) || `IS_CSRRCI(i) \
)

`define NEED_ZIMM(i) ( \
    `IS_CSRRWI(i) || `IS_CSRRSI(i) || `IS_CSRRCI(i) \
)

`define NEED_CONST_4(i) ( \
    `IS_JAL(i) || `IS_JALR(i) \
)

`define NEED_SHAMT(i) ( \
    `IS_SLLI(i) || `IS_SRLI(i) || `IS_SRAI(i) \
)

`endif // RV32I_DECODE_DEFS_VH
