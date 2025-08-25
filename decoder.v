module decoder (
    input  [31:0]       inst_i,
    input  [31:0]       rs1_i,
    input  [31:0]       rs2_i,
    output              is_branch_o,
    output              is_jal_o,
    output              is_jalr_o,
    output              is_auipc_o,
    output              is_lui_o,
    output              is_ecall_o,
    output              is_mret_o,
    output              rs1_used_o,
    output              rs2_used_o,
    output              rd_used_o,
    output [4:0]        rd_addr_o,
    output [4:0]        rs1_addr_o,
    output [4:0]        rs2_addr_o,
    output [3:0]        alu_sel_o,
    output [4:0]        csr_zimm5_o,
    output              csr_used_o,
    output [11:0]       csr_addr_o,
    output [2:0]        csr_op_o,
    output [31:0]       imm_o
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

assign csr_zimm5  = inst_i[19:15];
assign csr_addr_o = inst_i[31:20];
assign csr_op_o   = (`FUNCT3(inst_i) == `F3_CSRRW || `FUNCT3(inst_i) == `F3_CSRRWI) ? CSR_OP_RW :
                    (`FUNCT3(inst_i) == `F3_CSRRS || `FUNCT3(inst_i) == `F3_CSRRSI) ? CSR_OP_RS :
                    (`FUNCT3(inst_i) == `F3_CSRRC || `FUNCT3(inst_i) == `F3_CSRRCI) ? CSR_OP_RC :
                    CSR_OP_NONE;


endmodule