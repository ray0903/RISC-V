module DPU_RF(
    input                         clk_i,
    input                         rst_i,

    //****** DPU Interface ******//
    input                         dpu2rf_wr0_i,
    input  [`RF_ADDR_WIDTH-1:0]   dpu2rf_waddr0_i,
    input  [`XLEN-1:0]            dpu2rf_wdata0_i,

    input                         dpu2rf_wr1_i,
    input  [`RF_ADDR_WIDTH-1:0]   dpu2rf_waddr1_i,
    input  [`XLEN-1:0]            dpu2rf_wdata1_i,

    input                         dpu2rf_re1_i,
    input  [`RF_ADDR_WIDTH-1:0]   dpu2rf_raddr1_i,
    output reg [`XLEN-1:0]        rf2dpu_rs1_o,

    input                         dpu2rf_re2_i,
    input  [`RF_ADDR_WIDTH-1:0]   dpu2rf_raddr2_i,
    output reg [`XLEN-1:0]        rf2dpu_rs2_o
)

reg  [`XLEN-1:0]          rf_array [0:`RF_DEPTH-1];
wire [`RF_ADDR_WIDTH-1:0] rf_addr_const [0:`RF_DEPTH-1];

assign rf_addr_const[0]  = 5'd0;
assign rf_addr_const[1]  = 5'd1;
assign rf_addr_const[2]  = 5'd2;
assign rf_addr_const[3]  = 5'd3;
assign rf_addr_const[4]  = 5'd4;
assign rf_addr_const[5]  = 5'd5;
assign rf_addr_const[6]  = 5'd6;
assign rf_addr_const[7]  = 5'd7;
assign rf_addr_const[8]  = 5'd8;
assign rf_addr_const[9]  = 5'd9;
assign rf_addr_const[10] = 5'd10;
assign rf_addr_const[11] = 5'd11;
assign rf_addr_const[12] = 5'd12;
assign rf_addr_const[13] = 5'd13;
assign rf_addr_const[14] = 5'd14;
assign rf_addr_const[15] = 5'd15;
assign rf_addr_const[16] = 5'd16;
assign rf_addr_const[17] = 5'd17;
assign rf_addr_const[18] = 5'd18;
assign rf_addr_const[19] = 5'd19;
assign rf_addr_const[20] = 5'd20;
assign rf_addr_const[21] = 5'd21;
assign rf_addr_const[22] = 5'd22;
assign rf_addr_const[23] = 5'd23;
assign rf_addr_const[24] = 5'd24;
assign rf_addr_const[25] = 5'd25;
assign rf_addr_const[26] = 5'd26;
assign rf_addr_const[27] = 5'd27;
assign rf_addr_const[28] = 5'd28;
assign rf_addr_const[29] = 5'd29;
assign rf_addr_const[30] = 5'd30;
assign rf_addr_const[31] = 5'd31;

always@(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        rf_array_o[0] <= `XLEN'b0;
    end
    else begin
        rf_array_o[0] <= `XLEN'b0;
    end
end

genvar i;
generate
    for(i=1; i<`RF_DEPTH; i=i+1) begin: RF_ARRAY_INIT
        always@(posedge clk_i or posedge rst_i) begin
            if (rst_i) begin
                rf_array[i] <= `XLEN'b0;
            end
            else begin
                if (dpu2rf_wr0_i && (dpu2rf_waddr0_i == rf_addr_const[i])) begin
                    rf_array[i] <= dpu2rf_wdata0_i;
                end
                if (dpu2rf_wr1_i && (dpu2rf_waddr1_i == rf_addr_const[i])) begin
                    rf_array[i] <= dpu2rf_wdata1_i;
                end
            end
        end
    end
endgenerate

always@(*)begin
    if(dpu2rf_re1_i)begin
        case(dpu2rf_raddr1_i)
            rf_addr_const[0] : rf2dpu_rs1_o = rf_array[0];
            rf_addr_const[1] : rf2dpu_rs1_o = rf_array[1];
            rf_addr_const[2] : rf2dpu_rs1_o = rf_array[2];
            rf_addr_const[3] : rf2dpu_rs1_o = rf_array[3];
            rf_addr_const[4] : rf2dpu_rs1_o = rf_array[4];
            rf_addr_const[5] : rf2dpu_rs1_o = rf_array[5];
            rf_addr_const[6] : rf2dpu_rs1_o = rf_array[6];
            rf_addr_const[7] : rf2dpu_rs1_o = rf_array[7];
            rf_addr_const[8] : rf2dpu_rs1_o = rf_array[8];
            rf_addr_const[9] : rf2dpu_rs1_o = rf_array[9];
            rf_addr_const[10]: rf2dpu_rs1_o = rf_array[10];
            rf_addr_const[11]: rf2dpu_rs1_o = rf_array[11];
            rf_addr_const[12]: rf2dpu_rs1_o = rf_array[12];
            rf_addr_const[13]: rf2dpu_rs1_o = rf_array[13];
            rf_addr_const[14]: rf2dpu_rs1_o = rf_array[14];
            rf_addr_const[15]: rf2dpu_rs1_o = rf_array[15];
            rf_addr_const[16]: rf2dpu_rs1_o = rf_array[16];
            rf_addr_const[17]: rf2dpu_rs1_o = rf_array[17];
            rf_addr_const[18]: rf2dpu_rs1_o = rf_array[18];
            rf_addr_const[19]: rf2dpu_rs1_o = rf_array[19];
            rf_addr_const[20]: rf2dpu_rs1_o = rf_array[20];
            rf_addr_const[21]: rf2dpu_rs1_o = rf_array[21];
            rf_addr_const[22]: rf2dpu_rs1_o = rf_array[22];
            rf_addr_const[23]: rf2dpu_rs1_o = rf_array[23];
            rf_addr_const[24]: rf2dpu_rs1_o = rf_array[24];
            rf_addr_const[25]: rf2dpu_rs1_o = rf_array[25];
            rf_addr_const[26]: rf2dpu_rs1_o = rf_array[26];
            rf_addr_const[27]: rf2dpu_rs1_o = rf_array[27];
            rf_addr_const[28]: rf2dpu_rs1_o = rf_array[28];
            rf_addr_const[29]: rf2dpu_rs1_o = rf_array[29];
            rf_addr_const[30]: rf2dpu_rs1_o = rf_array[30];
            rf_addr_const[31]: rf2dpu_rs1_o = rf_array[31];
            default          : rf2dpu_rs1_o = `XLEN'b0;
        endcase
    end
    else begin
        rf2dpu_rs1_o = `XLEN'b0;
    end
end 


always@(*)begin
    if(dpu2rf_re2_i)begin
        case(dpu2rf_raddr2_i)
            rf_addr_const[0] : rf2dpu_rs2_o = rf_array[0];
            rf_addr_const[1] : rf2dpu_rs2_o = rf_array[1];
            rf_addr_const[2] : rf2dpu_rs2_o = rf_array[2];
            rf_addr_const[3] : rf2dpu_rs2_o = rf_array[3];
            rf_addr_const[4] : rf2dpu_rs2_o = rf_array[4];
            rf_addr_const[5] : rf2dpu_rs2_o = rf_array[5];
            rf_addr_const[6] : rf2dpu_rs2_o = rf_array[6];
            rf_addr_const[7] : rf2dpu_rs2_o = rf_array[7];
            rf_addr_const[8] : rf2dpu_rs2_o = rf_array[8];
            rf_addr_const[9] : rf2dpu_rs2_o = rf_array[9];
            rf_addr_const[10]: rf2dpu_rs2_o = rf_array[10];
            rf_addr_const[11]: rf2dpu_rs2_o = rf_array[11];
            rf_addr_const[12]: rf2dpu_rs2_o = rf_array[12];
            rf_addr_const[13]: rf2dpu_rs2_o = rf_array[13];
            rf_addr_const[14]: rf2dpu_rs2_o = rf_array[14];
            rf_addr_const[15]: rf2dpu_rs2_o = rf_array[15];
            rf_addr_const[16]: rf2dpu_rs2_o = rf_array[16];
            rf_addr_const[17]: rf2dpu_rs2_o = rf_array[17];
            rf_addr_const[18]: rf2dpu_rs2_o = rf_array[18];
            rf_addr_const[19]: rf2dpu_rs2_o = rf_array[19];
            rf_addr_const[20]: rf2dpu_rs2_o = rf_array[20];
            rf_addr_const[21]: rf2dpu_rs2_o = rf_array[21];
            rf_addr_const[22]: rf2dpu_rs2_o = rf_array[22];
            rf_addr_const[23]: rf2dpu_rs2_o = rf_array[23];
            rf_addr_const[24]: rf2dpu_rs2_o = rf_array[24];
            rf_addr_const[25]: rf2dpu_rs2_o = rf_array[25];
            rf_addr_const[26]: rf2dpu_rs2_o = rf_array[26];
            rf_addr_const[27]: rf2dpu_rs2_o = rf_array[27];
            rf_addr_const[28]: rf2dpu_rs2_o = rf_array[28];
            rf_addr_const[29]: rf2dpu_rs2_o = rf_array[29];
            rf_addr_const[30]: rf2dpu_rs2_o = rf_array[30];
            rf_addr_const[31]: rf2dpu_rs2_o = rf_array[31];
            default          : rf2dpu_rs2_o = `XLEN'b0;
        endcase
    end
    else begin
        rf2dpu_rs2_o = `XLEN'b0;
    end
end 





endmodule