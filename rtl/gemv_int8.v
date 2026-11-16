// int8 GEMV engine: y[i] = sum_j W[i][j] * x[j], int8 x int8 -> int32.
//
// One job = optional x load followed by m weight rows, all on a single input stream
// of P int8 lanes per beat (lane 0 in the low byte):
//   if load_x: nb beats of x      (kept in xbuf, so later jobs may reuse it)
//   then     : m*nb beats of W   (row-major, rows zero-padded to nb*P elements)
// Produces m int32 results on the output stream, tlast on the final row.
//
// Datapath: xbuf read -> P multipliers -> registered log2(P)-level adder tree ->
// accumulator. Throughput is one beat (P MACs) per cycle; input backpressure is only
// applied when the output FIFO could overflow.
`default_nettype none
module gemv_int8 #(
    parameter P      = 32,    // lanes (int8 per beat); power of two
    parameter LOG2P  = 5,
    parameter XDEPTH = 32,    // max beats in x (max vector length = P*XDEPTH)
    parameter XAW    = 5,     // log2(XDEPTH)
    parameter FDEPTH = 32,    // output FIFO depth; must exceed pipeline depth + 2
    parameter FAW    = 5
) (
    input  wire             clk,
    input  wire             rst_n,
    // job control
    input  wire             start,     // pulse; cfg_* sampled here
    input  wire             cfg_load_x,
    input  wire [31:0]      cfg_m,     // rows, >= 1
    input  wire [15:0]      cfg_nb,    // beats per row, 1..XDEPTH
    output wire             busy,
    output reg              done,      // one-cycle pulse after the last result is taken
    // input stream (x then W)
    input  wire [P*8-1:0]   s_tdata,
    input  wire             s_tvalid,
    output wire             s_tready,
    // output stream (int32 per row)
    output wire [31:0]      m_tdata,
    output wire             m_tvalid,
    input  wire             m_tready,
    output wire             m_tlast
);
    localparam PIPE = LOG2P + 3; // xbuf read, multiply, LOG2P tree levels, accumulate

    localparam S_IDLE = 2'd0, S_LOADX = 2'd1, S_W = 2'd2, S_DRAIN = 2'd3;
    reg [1:0]  state;
    reg [31:0] m_r;
    reg [15:0] nb_r;
    reg [15:0] col;
    reg [31:0] row;
    reg [31:0] out_cnt;

    // ---------------- output FIFO ----------------
    reg  [31:0]  fifo [0:FDEPTH-1];
    reg  [FAW:0] f_cnt;
    reg  [FAW-1:0] f_wp, f_rp;
    wire         f_push;
    wire [31:0]  f_din;
    wire         f_pop = m_tvalid && m_tready;
    assign m_tvalid = f_cnt != 0;
    assign m_tdata  = fifo[f_rp];
    assign m_tlast  = out_cnt == m_r - 1;

    always @(posedge clk) begin
        if (!rst_n) begin
            f_cnt <= 0; f_wp <= 0; f_rp <= 0;
        end else begin
            if (f_push) begin fifo[f_wp] <= f_din; f_wp <= f_wp + 1'b1; end
            if (f_pop) f_rp <= f_rp + 1'b1;
            f_cnt <= f_cnt + f_push - f_pop;
        end
    end

    // ---------------- control ----------------
    wire room = f_cnt <= FDEPTH - PIPE - 2;
    assign s_tready = (state == S_LOADX) || (state == S_W && room);
    assign busy     = state != S_IDLE;
    wire   fire     = s_tvalid && s_tready;
    wire   last_col = col == nb_r - 1;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; col <= 0; row <= 0; out_cnt <= 0;
            m_r <= 0; nb_r <= 0;
        end else begin
            done <= 1'b0;
            if (f_pop) out_cnt <= out_cnt + 1;
            case (state)
            S_IDLE: if (start) begin
                m_r <= cfg_m; nb_r <= cfg_nb; col <= 0; row <= 0; out_cnt <= 0;
                state <= cfg_load_x ? S_LOADX : S_W;
            end
            S_LOADX: if (fire) begin
                col <= last_col ? 16'd0 : col + 1'b1;
                if (last_col) state <= S_W;
            end
            S_W: if (fire) begin
                col <= last_col ? 16'd0 : col + 1'b1;
                if (last_col) begin
                    row <= row + 1;
                    if (row == m_r - 1) state <= S_DRAIN;
                end
            end
            S_DRAIN: if (f_pop && m_tlast) begin
                state <= S_IDLE; done <= 1'b1;
            end
            endcase
        end
    end

    // ---------------- x buffer ----------------
    reg [P*8-1:0] xbuf [0:XDEPTH-1];
    always @(posedge clk)
        if (state == S_LOADX && fire) xbuf[col[XAW-1:0]] <= s_tdata;

    // ---------------- datapath ----------------
    // stage 1: weight beat + synchronously read x beat
    reg [P*8-1:0] w1, x1;
    reg v1, first1, last1;
    wire wfire = state == S_W && fire;
    always @(posedge clk) begin
        w1 <= s_tdata;
        x1 <= xbuf[col[XAW-1:0]];
        v1 <= rst_n && wfire;
        first1 <= col == 0;
        last1  <= last_col;
    end

    // stage 2: P signed products
    reg [P*16-1:0] prod;
    reg v2, first2, last2;
    integer k;
    always @(posedge clk) begin
        for (k = 0; k < P; k = k + 1)
            prod[k*16 +: 16] <= $signed(w1[k*8 +: 8]) * $signed(x1[k*8 +: 8]);
        v2 <= rst_n && v1; first2 <= first1; last2 <= last1;
    end

    // stages 3..LOG2P+2: registered adder tree. Level l holds P>>l sums, each stored in
    // a 32-bit slot (int8*int8 sums over <= 2^16 terms cannot overflow 32 bits).
    wire [P*32-1:0] lvl_in [0:LOG2P];
    reg  [LOG2P:0]  tv, tfirst, tlast;
    genvar g, l;
    generate
        for (g = 0; g < P; g = g + 1) begin : sext
            assign lvl_in[0][g*32 +: 32] = {{16{prod[g*16+15]}}, prod[g*16 +: 16]};
        end
        for (l = 1; l <= LOG2P; l = l + 1) begin : tree
            reg [(P>>l)*32-1:0] s;
            for (g = 0; g < (P >> l); g = g + 1) begin : add
                always @(posedge clk)
                    s[g*32 +: 32] <= lvl_in[l-1][(2*g)*32 +: 32] + lvl_in[l-1][(2*g+1)*32 +: 32];
            end
            assign lvl_in[l] = {{(P - (P>>l))*32{1'b0}}, s};
        end
    endgenerate
    always @(posedge clk) begin
        tv     <= rst_n ? {tv[LOG2P-1:0], v2} : {(LOG2P+1){1'b0}};
        tfirst <= {tfirst[LOG2P-1:0], first2};
        tlast  <= {tlast[LOG2P-1:0],  last2};
    end
    wire [31:0] beat_sum = lvl_in[LOG2P][31:0];
    wire        bv = tv[LOG2P-1], bfirst = tfirst[LOG2P-1], blast = tlast[LOG2P-1];

    // final stage: accumulate across the beats of a row
    reg  [31:0] acc;
    wire [31:0] acc_next = (bfirst ? 32'd0 : acc) + beat_sum;
    always @(posedge clk)
        if (bv) acc <= acc_next;
    assign f_push = rst_n && bv && blast;
    assign f_din  = acc_next;
endmodule
`default_nettype wire
