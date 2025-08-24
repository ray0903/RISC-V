module PFU (
    input                                 clk_i,
    input                                 rst_i,

    //****** DPU Interface ******//
    input                                 dpu2pfu_ready_i,
    output  reg                           pfu2dpu_valid_o,
    output  reg  [`INST_WIDTH-1:0]        pfu2dpu_inst_o,
    output  reg  [`PC_WIDHT-1:0]          pfu2dpu_pc_o,

    //****** Central control Interface ******//
    input                                 ctrl2pfu_flush_i,
    input                                 ctrl2pfu_stall_i,
    input  [`PC_WIDHT-1:0]                ctrl2pfu_force_pc_i,
    input                                 ctrl2pfu_valid_i,
    output                                pfu2ctrl_ready_o
);

parameter IDLE          =  5'b0000_1,
          SEQ_FETCH     =  5'b0001_0,
          BRANCH_FETCH  =  5'b0010_0,
          BLOCK         =  5'b0100_0,
          FORCE         =  5'b1000_0;


reg  [4:0]                           cur_state;
reg  [4:0]                           nxt_state;

reg  [`PC_WIDHT-1:0]                 seq_pc;
reg  [`PC_WIDHT-1:0]                 branch_pc;       //ras pc
reg                                  branch_pc_valid; //ras pc valid

wire                                 pfu_ctrl_handshake;
wire                                 pfu_dpu_handshake;
wire                                 push_valid;
wire                                 ahb_req;


wire [`PC_WIDHT-1:0]                 force_pc;     //from ctrl


assign pfu_ctrl_handshake = ctrl2pfu_valid_i & pfu2ctrl_ready_o;
assign pfu_dpu_handshake  = pfu2dpu_valid_o & dpu2pfu_ready_i;

//****** FSM ******//
always @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        cur_state <= IDLE;
    end
    else begin
        cur_state <= nxt_state;
    end     
end

always @(*) begin
    case (cur_state)
        IDLE: begin
            if (pfu_ctrl_handshake & pfu_stall_i) begin
                nxt_state = BLOCK;
            end
            else if (pfu_ctrl_handshake & ctrl2pfu_flush_i) begin
                nxt_state = FORCE;
            end
            else if (!pfu_stall_i) begin   //first stall do not need handshake
                nxt_state = SEQ_FETCH;
            end
            else begin
                nxt_state = IDLE;
            end
        end

        SEQ_FETCH: begin
            if (pfu_ctrl_handshake & pfu_stall_i) begin
                nxt_state = BLOCK;
            end
            else if (pfu_ctrl_handshake & ctrl2pfu_flush_i) begin
                nxt_state = FORCE;
            end
            else if(push_valid) begin
                nxt_state = BRANCH_FETCH;
            end
            else begin
                nxt_state = SEQ_FETCH;
            end
        end

        BRANCH_FETCH: begin
            if (pfu_ctrl_handshake & pfu_stall_i) begin
                nxt_state = BLOCK;
            end
            else if (pfu_ctrl_handshake & ctrl2pfu_flush_i) begin
                nxt_state = FORCE;
            end
            else if(push_valid)begin
                nxt_state = BRANCH_FETCH;
            end
            else begin
                nxt_state = SEQ_FETCH;
            end
        end

        FORCE: begin
            if (pfu_ctrl_handshake & pfu_stall_i) begin
                nxt_state = BLOCK;
            end
            else if (pfu_ctrl_handshake & ctrl2pfu_flush_i) begin
                nxt_state = FORCE;
            end
            else if(push_valid)begin
                nxt_state = BRANCH_FETCH;
            end
            else begin
                nxt_state = SEQ_FETCH;
            end
        end

        BLOCK: begin
            if (pfu_ctrl_handshake & ~pfu_stall_i) begin
                nxt_state = SEQ_FETCH;
            end
            else if (pfu_ctrl_handshake & ctrl2pfu_flush_i) begin
                nxt_state = FORCE;
            end
            else begin
                nxt_state = BLOCK;
            end
        end

        default: begin
            nxt_state = IDLE;
        end
    endcase
end


//****** end of FSM ******//

//****** pc generator ******//
assign pc_gen = (nxt_state == IDLE)  ? `INIT_PC :
                (nxt_state == FORCE) ? ctrl2pfu_force_pc_i :
                (nxt_state == BLOCK) ? seq_pc :
                (nxt_state == SEQ)   ? branch_pc :
                                       seq_pc;

always@(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        seq_pc <= `INIT_PC;
    end
    else if (bus_ready & ~(pfu_ctrl_handshake & pfu_stall_i)) begin//when the bus is ready, update the pc
        seq_pc <= pc_gen + 4;
    end
    else begin
        seq_pc <= seq_pc;
    end 
end

always@(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        branch_pc <= `INIT_PC;
    end
    else if (push_valid & bus_ready) begin
        branch_pc <= pc_gen + 4;
        branch_pc_valid <= 1'b1;
    end
    else if(pop_valid & bus_ready) begin
        branch_pc <= `INIT_PC;
        branch_pc_valid <= 1'b0;
    end
    else begin
        branch_pc <= branch_pc;
        branch_pc_valid <= branch_pc_valid;
    end
end
//****** end of pc generator ******//
    
//****** ahb master ******//
assign ahb_req = nxt_state != BLOCK; //when not stall, request a new instruction
AHB_MASTER u_ahb_master (
    .hclk_i        (clk_i                                 ),
    .hresetn_i     (~rst_i                                ),

    .addr_i        (pc_gen                                ),
    .wr_i          (1'b0                                  ), //always read

    .req_i         (ahb_req                               ), //when not stall, request a new instruction
    .rdata_o       (pfu2dpu_inst_o                        ),
    .ready_o       (bus_ready                             ),

    .hready_i      (pfu_hready_i                          ),
    .hrdata_i      (pfu_hrdata_i                          ),

    .paddr_o       (pfu_ahb_haddr_o                       ),
    .htrans_o      (pfu_ahb_htrans_o                      ),
    .hwrite_o      (pfu_ahb_hwrite_o                      ),
    .hsize_o       (pfu_ahb_hsize_o                       ),
    .hburst_o      (pfu_ahb_hburst_o                      ),
    .hprot_o       (pfu_ahb_hprot_o                       ),
    .hlock_o       (pfu_ahb_hlock_o                       ),
    .hwdata_o      (pfu_ahb_hwdata_o                      )
);
//****** end of ahb master ******//






endmodule