module DPU (
    input                                     clk_i,
    input                                     rst_i,

    //****** PFU Interface ******//
    input                                     pfu2dpu_valid_i,
    input      [`INST_WIDTH-1:0]              pfu2dpu_inst_i,
    input      [`PC_WIDHT-1:0]                pfu2dpu_pc_i,
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



endmodule