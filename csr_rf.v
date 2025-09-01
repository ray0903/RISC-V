module CSR_RF(
    input                         clk_i,
    input                         rst_i,
    //read port
    input      [11:0]             csr_addr_i,
    input                         csr_re_i,
    output reg [`XLEN-1:0]        csr_data_o,
    //write port
    input                         csr_we_i,
    input      [11:0]             csr_waddr_i,
    input      [31:0]             csr_wdata_i
);


