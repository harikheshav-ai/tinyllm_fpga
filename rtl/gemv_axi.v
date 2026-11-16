// AXI wrapper for gemv_int8, meant to sit behind a Xilinx AXI DMA:
//   MM2S (256-bit) -> s_axis   : [x beats if load_x] + W beats
//   m_axis (32-bit) -> S2MM    : m int32 results, tlast on the last one
// AXI4-Lite registers:
//   0x00 CTRL    W: bit0 start (self-clearing), bit1 load_x
//   0x04 STATUS  R: bit0 busy, bit1 done (sticky; write 1 to bit1 to clear)
//   0x08 M       rows
//   0x0C NB      beats per row
//   0x10 CYCLES  cycles from start to done of the last job
//   0x14 INFO    R: {16'(XDEPTH), 16'(P)}
`default_nettype none
module gemv_axi #(
    parameter P = 32, LOG2P = 5, XDEPTH = 32, XAW = 5
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire              aclk,
    input  wire              aresetn,
    // AXI4-Lite slave
    input  wire [5:0]        s_axi_awaddr,
    input  wire              s_axi_awvalid,
    output reg               s_axi_awready,
    input  wire [31:0]       s_axi_wdata,
    input  wire [3:0]        s_axi_wstrb,
    input  wire              s_axi_wvalid,
    output reg               s_axi_wready,
    output wire [1:0]        s_axi_bresp,
    output reg               s_axi_bvalid,
    input  wire              s_axi_bready,
    input  wire [5:0]        s_axi_araddr,
    input  wire              s_axi_arvalid,
    output reg               s_axi_arready,
    output reg  [31:0]       s_axi_rdata,
    output wire [1:0]        s_axi_rresp,
    output reg               s_axi_rvalid,
    input  wire              s_axi_rready,
    // AXI-Stream in
    input  wire [P*8-1:0]    s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire              s_axis_tlast,
    // AXI-Stream out
    output wire [31:0]       m_axis_tdata,
    output wire [3:0]        m_axis_tkeep,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready,
    output wire              m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire              irq           // level: done
);
    reg        start, load_x, done_sticky;
    reg [31:0] m_reg, cycles, cyc_cnt;
    reg [15:0] nb_reg;
    wire       busy, done;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;
    assign m_axis_tkeep = 4'hF;
    assign irq = done_sticky;

    // write channel: accept address and data together
    wire wr = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0;
            start <= 0; load_x <= 0; done_sticky <= 0; m_reg <= 0; nb_reg <= 0;
        end else begin
            start <= 0;
            s_axi_awready <= wr && !s_axi_awready;
            s_axi_wready  <= wr && !s_axi_wready;
            if (wr && !s_axi_awready) begin
                s_axi_bvalid <= 1;
                case (s_axi_awaddr[5:2])
                4'h0: begin start <= s_axi_wdata[0] && !busy; load_x <= s_axi_wdata[1];
                            if (s_axi_wdata[0]) done_sticky <= 0; end
                4'h1: if (s_axi_wdata[1]) done_sticky <= 0;
                4'h2: m_reg  <= s_axi_wdata;
                4'h3: nb_reg <= s_axi_wdata[15:0];
                default: ;
                endcase
            end else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (done) done_sticky <= 1;
        end
    end

    // read channel
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0; s_axi_rdata <= 0;
        end else begin
            s_axi_arready <= s_axi_arvalid && !s_axi_arready && !s_axi_rvalid;
            if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
                s_axi_rvalid <= 1;
                case (s_axi_araddr[5:2])
                4'h0: s_axi_rdata <= {30'd0, load_x, 1'b0};
                4'h1: s_axi_rdata <= {30'd0, done_sticky, busy};
                4'h2: s_axi_rdata <= m_reg;
                4'h3: s_axi_rdata <= {16'd0, nb_reg};
                4'h4: s_axi_rdata <= cycles;
                4'h5: s_axi_rdata <= {XDEPTH[15:0], P[15:0]};
                default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
        end
    end

    // performance counter
    always @(posedge aclk) begin
        if (!aresetn) begin cyc_cnt <= 0; cycles <= 0; end
        else if (start) cyc_cnt <= 0;
        else if (busy) cyc_cnt <= cyc_cnt + 1;
        if (aresetn && done) cycles <= cyc_cnt + 1;
    end

    gemv_int8 #(.P(P), .LOG2P(LOG2P), .XDEPTH(XDEPTH), .XAW(XAW)) core (
        .clk(aclk), .rst_n(aresetn),
        .start(start), .cfg_load_x(load_x), .cfg_m(m_reg), .cfg_nb(nb_reg),
        .busy(busy), .done(done),
        .s_tdata(s_axis_tdata), .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
        .m_tdata(m_axis_tdata), .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready),
        .m_tlast(m_axis_tlast));
endmodule
`default_nettype wire
