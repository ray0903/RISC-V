module  NORMAL_LOGIC#(
    parameter integer WIDTH = 32
) (
    input             [WIDTH-1:0] op1_i,
    input             [WIDTH-1:0] op2_i,

    input             [7:0]       sel_i,

    output            [WIDTH-1:0] result_o
);

// AND operation
wire [31:0] and_result = op1_i & op2_i;
// OR operation
wire [31:0] or_result  = op1_i | op2_i;
// shift left operation
reg  [31:0] shift_left_result;
always @(*) begin
    case(op2_i[4:0])
        5'd0 : shift_left_result = op1_i;
        5'd1 : shift_left_result = op1_i << 5'd1;
        5'd2 : shift_left_result = op1_i << 5'd2;
        5'd3 : shift_left_result = op1_i << 5'd3;
        5'd4 : shift_left_result = op1_i << 5'd4;
        5'd5 : shift_left_result = op1_i << 5'd5;
        5'd6 : shift_left_result = op1_i << 5'd6;
        5'd7 : shift_left_result = op1_i << 5'd7;
        5'd8 : shift_left_result = op1_i << 5'd8;
        5'd9 : shift_left_result = op1_i << 5'd9;
        5'd10: shift_left_result = op1_i << 5'd10;
        5'd11: shift_left_result = op1_i << 5'd11;
        5'd12: shift_left_result = op1_i << 5'd12;
        5'd13: shift_left_result = op1_i << 5'd13;
        5'd14: shift_left_result = op1_i << 5'd14;
        5'd15: shift_left_result = op1_i << 5'd15;
        5'd16: shift_left_result = op1_i << 5'd16;
        5'd17: shift_left_result = op1_i << 5'd17;
        5'd18: shift_left_result = op1_i << 5'd18;
        5'd19: shift_left_result = op1_i << 5'd19;
        5'd20: shift_left_result = op1_i << 5'd20;
        5'd21: shift_left_result = op1_i << 5'd21;
        5'd22: shift_left_result = op1_i << 5'd22;
        5'd23: shift_left_result = op1_i << 5'd23;
        5'd24: shift_left_result = op1_i << 5'd24;
        5'd25: shift_left_result = op1_i << 5'd25;
        5'd26: shift_left_result = op1_i << 5'd26;
        5'd27: shift_left_result = op1_i << 5'd27;
        5'd28: shift_left_result = op1_i << 5'd28;
        5'd29: shift_left_result = op1_i << 5'd29;
        5'd30: shift_left_result = op1_i << 5'd30;
        5'd31: shift_left_result = op1_i << 5'd31;
        default: shift_left_result = op1_i;
    endcase 
end
// shift right operation
reg  [31:0] shift_right_result;
always@(*)begin
    case(op2_i[4:0])
        5'd0 : shift_right_result = op1_i;
        5'd1 : shift_right_result = op1_i >> 5'd1;
        5'd2 : shift_right_result = op1_i >> 5'd2;
        5'd3 : shift_right_result = op1_i >> 5'd3;
        5'd4 : shift_right_result = op1_i >> 5'd4;
        5'd5 : shift_right_result = op1_i >> 5'd5;
        5'd6 : shift_right_result = op1_i >> 5'd6;
        5'd7 : shift_right_result = op1_i >> 5'd7;
        5'd8 : shift_right_result = op1_i >> 5'd8;
        5'd9 : shift_right_result = op1_i >> 5'd9;
        5'd10: shift_right_result = op1_i >> 5'd10;
        5'd11: shift_right_result = op1_i >> 5'd11;
        5'd12: shift_right_result = op1_i >> 5'd12;
        5'd13: shift_right_result = op1_i >> 5'd13;
        5'd14: shift_right_result = op1_i >> 5'd14;
        5'd15: shift_right_result = op1_i >> 5'd15;
        5'd16: shift_right_result = op1_i >> 5'd16;
        5'd17: shift_right_result = op1_i >> 5'd17;
        5'd18: shift_right_result = op1_i >> 5'd18;
        5'd19: shift_right_result = op1_i >> 5'd19;
        5'd20: shift_right_result = op1_i >> 5'd20;
        5'd21: shift_right_result = op1_i >> 5'd21;
        5'd22: shift_right_result = op1_i >> 5'd22;
        5'd23: shift_right_result = op1_i >> 5'd23;
        5'd24: shift_right_result = op1_i >> 5'd24;
        5'd25: shift_right_result = op1_i >> 5'd25;
        5'd26: shift_right_result = op1_i >> 5'd26;
        5'd27: shift_right_result = op1_i >> 5'd27;     
        5'd28: shift_right_result = op1_i >> 5'd28;
        5'd29: shift_right_result = op1_i >> 5'd29;
        5'd30: shift_right_result = op1_i >> 5'd30;
        5'd31: shift_right_result = op1_i >> 5'd31;
        default: shift_right_result = op1_i;
    endcase
end
// alt shift right operation (arithmetic)
reg  [31:0] alt_shift_right_result;
always@(*)begin
    case(op2_i[4:0])
        5'd0 : alt_shift_right_result = op1_i;
        5'd1 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd1;
        5'd2 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd2;
        5'd3 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd3;
        5'd4 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd4;
        5'd5 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd5;
        5'd6 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd6;
        5'd7 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd7;
        5'd8 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd8;
        5'd9 : alt_shift_right_result = ($signed(op1_i)) >>> 5'd9;
        5'd10: alt_shift_right_result = ($signed(op1_i)) >>> 5'd10;
        5'd11: alt_shift_right_result = ($signed(op1_i)) >>> 5'd11;
        5'd12: alt_shift_right_result = ($signed(op1_i)) >>> 5'd12;
        5'd13: alt_shift_right_result = ($signed(op1_i)) >>> 5'd13;
        5'd14: alt_shift_right_result = ($signed(op1_i)) >>> 5'd14;
        5'd15: alt_shift_right_result = ($signed(op1_i)) >>> 5'd15;
        5'd16: alt_shift_right_result = ($signed(op1_i)) >>> 5'd16;
        5'd17: alt_shift_right_result = ($signed(op1_i)) >>> 5'd17;
        5'd18: alt_shift_right_result = ($signed(op1_i)) >>> 5'd18;
        5'd19: alt_shift_right_result = ($signed(op1_i)) >>> 5'd19;
        5'd20: alt_shift_right_result = ($signed(op1_i)) >>> 5'd20;
        5'd21: alt_shift_right_result = ($signed(op1_i)) >>> 5'd21;
        5'd22: alt_shift_right_result = ($signed(op1_i)) >>> 5'd22;
        5'd23: alt_shift_right_result = ($signed(op1_i)) >>> 5'd23;
        5'd24: alt_shift_right_result = ($signed(op1_i)) >>> 5'd24;
        5'd25: alt_shift_right_result = ($signed(op1_i)) >>> 5'd25;
        5'd26: alt_shift_right_result = ($signed(op1_i)) >>> 5'd26;
        5'd27: alt_shift_right_result = ($signed(op1_i)) >>> 5'd27;     
        5'd28: alt_shift_right_result = ($signed(op1_i)) >>> 5'd28;
        5'd29: alt_shift_right_result = ($signed(op1_i)) >>> 5'd29;
        5'd30: alt_shift_right_result = ($signed(op1_i)) >>> 5'd30;
        5'd31: alt_shift_right_result = ($signed(op1_i)) >>> 5'd31;
        default: alt_shift_right_result = op1_i;
    endcase
end

// XOR operation
wire [31:0] xor_result = op1_i ^ op2_i;

//**** CSR logic ****//
wire [31:0] csr_set_result   = op1_i | op2_i; // CSRRS/CSRRSI
wire [31:0] csr_clear_result = op1_i & (~op2_i); // CSRRC/CSRRCI


//*** output ***//
always @(*) begin
    case(sel_i)
        8'b0000_0001 : result_o = and_result;
        8'b0000_0010 : result_o = or_result;
        8'b0000_0100 : result_o = shift_left_result;
        8'b0000_1000 : result_o = shift_right_result;
        8'b0001_0000 : result_o = alt_shift_right_result;
        8'b0010_0000 : result_o = xor_result;
        8'b0100_0000 : result_o = csr_set_result;
        8'b1000_0000 : result_o = csr_clear_result;
        default      : result_o = 32'b0;
    endcase
end

endmodule


