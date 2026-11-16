// Replays a GEMV trace (format in sw/accel.h) through gemv_int8 and checks every
// result bit-exactly. Random input/output stalls exercise the handshakes.
//   plusargs: +trace=<file>  +stall_in=<0..127>  +stall_out=<0..127>  +seed=<n>
`timescale 1ns/1ps
module tb_gemv;
    localparam P = 32, LOG2P = 5, XDEPTH = 32, XAW = 5;
    localparam HALF = 5;
    localparam MAXM = 65536;

    reg clk = 0, rst_n = 0;
    always #HALF clk = ~clk;

    reg          start = 0, cfg_load_x = 0;
    reg  [31:0]  cfg_m = 0;
    reg  [15:0]  cfg_nb = 0;
    wire         busy, done;
    reg  [P*8-1:0] s_tdata = 0;
    reg          s_tvalid = 0;
    wire         s_tready;
    wire [31:0]  m_tdata;
    wire         m_tvalid, m_tlast;
    reg          m_tready = 0;

    gemv_int8 #(.P(P), .LOG2P(LOG2P), .XDEPTH(XDEPTH), .XAW(XAW)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .cfg_load_x(cfg_load_x), .cfg_m(cfg_m),
        .cfg_nb(cfg_nb), .busy(busy), .done(done), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
        .m_tlast(m_tlast));

    integer fd, stall_in, stall_out, seed, dummy;
    integer njobs = 0, nerr = 0, nresults = 0;
    reg [63:0] total_beats = 0, total_cycles = 0, cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg signed [31:0] yexp [0:MAXM-1];
    integer out_idx, cur_m;

    // output side: random backpressure + checker
    always @(negedge clk) m_tready <= (($random(seed) & 127) >= stall_out);
    always @(posedge clk) if (m_tvalid && m_tready) begin
        if (m_tdata !== yexp[out_idx] || m_tlast !== (out_idx == cur_m - 1)) begin
            nerr = nerr + 1;
            if (nerr <= 10) $display("MISMATCH job %0d row %0d: got %0d (last=%b) exp %0d",
                                     njobs, out_idx, $signed(m_tdata), m_tlast, yexp[out_idx]);
        end
        out_idx = out_idx + 1;
        nresults = nresults + 1;
    end

    function [31:0] rd32(input integer f);
        integer b0, b1, b2, b3;
        begin
            b0 = $fgetc(f); b1 = $fgetc(f); b2 = $fgetc(f); b3 = $fgetc(f);
            rd32 = {b3[7:0], b2[7:0], b1[7:0], b0[7:0]};
        end
    endfunction

    task send_beat_from_file;
        integer k, b;
        reg fired;
        begin
            while (($random(seed) & 127) < stall_in) @(negedge clk);
            for (k = 0; k < P; k = k + 1) begin b = $fgetc(fd); s_tdata[k*8 +: 8] = b[7:0]; end
            s_tvalid = 1;
            fired = 0;
            while (!fired) begin fired = s_tready === 1'b1; @(negedge clk); end
            s_tvalid = 0;
            total_beats = total_beats + 1;
        end
    endtask

    reg [31:0] magic, m, nb, reuse;
    integer i, pos_w, pos_end;
    reg [63:0] t0;
    initial begin
        if (!$value$plusargs("trace=%s", tracefile)) begin $display("need +trace="); $finish; end
        if (!$value$plusargs("stall_in=%d", stall_in)) stall_in = 0;
        if (!$value$plusargs("stall_out=%d", stall_out)) stall_out = 0;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        fd = $fopen(tracefile, "rb");
        if (fd == 0) begin $display("cannot open %0s", tracefile); $finish; end

        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        magic = rd32(fd);
        while (magic == 32'h564D4547) begin
            m = rd32(fd); nb = rd32(fd); reuse = rd32(fd);
            if (m > MAXM || nb > XDEPTH) begin $display("job too large m=%0d nb=%0d", m, nb); $finish; end
            // start the job
            cfg_m = m; cfg_nb = nb; cfg_load_x = reuse == 0; start = 1;
            @(negedge clk); start = 0;
            t0 = cyc;
            out_idx = 0; cur_m = m;
            if (reuse == 0) for (i = 0; i < nb; i = i + 1) send_beat_from_file;
            // expected results sit after W: read them first, then stream W
            pos_w = $ftell(fd);
            dummy = $fseek(fd, pos_w + m * nb * P, 0);
            for (i = 0; i < m; i = i + 1) yexp[i] = rd32(fd);
            pos_end = $ftell(fd);
            dummy = $fseek(fd, pos_w, 0);
            for (i = 0; i < m * nb; i = i + 1) send_beat_from_file;
            while (!done) @(negedge clk);
            if (out_idx != m) begin nerr = nerr + 1; $display("job %0d: got %0d results, exp %0d", njobs, out_idx, m); end
            total_cycles = total_cycles + (cyc - t0);
            njobs = njobs + 1;
            dummy = $fseek(fd, pos_end, 0);
            magic = rd32(fd);
        end
        $display("jobs=%0d results=%0d beats=%0d cycles=%0d utilization=%0.3f errors=%0d",
                 njobs, nresults, total_beats, total_cycles, total_beats * 1.0 / total_cycles, nerr);
        if (nerr == 0 && njobs > 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    reg [8*256-1:0] tracefile;
endmodule
