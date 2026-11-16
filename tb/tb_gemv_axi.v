// Smoke test for gemv_axi: AXI-Lite programming, one job with x load, one with x reuse.
`timescale 1ns/1ps
module tb_gemv_axi;
    localparam P = 32;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [5:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg  [31:0] wdata = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;
    reg  [P*8-1:0] sdata = 0;
    reg         svalid = 0, slast = 0;
    wire        sready;
    wire [31:0] mdata;
    wire [3:0]  mkeep;
    wire        mvalid, mlast, irq;
    reg         mready = 1;

    gemv_axi dut (.aclk(clk), .aresetn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(sdata), .s_axis_tvalid(svalid), .s_axis_tready(sready), .s_axis_tlast(slast),
        .m_axis_tdata(mdata), .m_axis_tkeep(mkeep), .m_axis_tvalid(mvalid), .m_axis_tready(mready),
        .m_axis_tlast(mlast), .irq(irq));

    task axi_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
            @(negedge clk); while (!awready) @(negedge clk);
            awvalid = 0; wvalid = 0;
            while (!bvalid) @(negedge clk);
        end
    endtask
    task axi_read(input [5:0] a, output [31:0] d);
        begin
            @(negedge clk); araddr = a; arvalid = 1;
            @(negedge clk); while (!arready) @(negedge clk);
            arvalid = 0;
            while (!rvalid) @(negedge clk);
            d = rdata;
        end
    endtask
    reg fired;
    task send(input [P*8-1:0] d);
        begin
            sdata = d; svalid = 1; fired = 0;
            while (!fired) begin fired = sready === 1'b1; @(negedge clk); end // ready sampled before the edge
            svalid = 0;
        end
    endtask

    localparam M = 5, NB = 3;
    reg signed [7:0] x [0:NB*P-1];
    reg signed [7:0] w [0:M*NB*P-1];
    reg signed [31:0] exp_y [0:M-1];
    reg [P*8-1:0] beat;
    integer i, j, b, errs = 0, got, job;
    reg [31:0] r;

    always @(posedge clk) if (mvalid && mready) begin
        if ($signed(mdata) !== exp_y[got] || mlast !== (got == M - 1)) begin
            errs = errs + 1; $display("job %0d row %0d: got %0d exp %0d", job, got, $signed(mdata), exp_y[got]);
        end
        got = got + 1;
    end

    initial begin
        for (i = 0; i < NB*P; i = i + 1) x[i] = $random;
        repeat (3) @(negedge clk); rstn = 1;
        axi_read(6'h14, r);
        if (r !== {16'd32, 16'd32}) begin errs = errs + 1; $display("INFO = %h", r); end
        for (job = 0; job < 2; job = job + 1) begin
            for (i = 0; i < M*NB*P; i = i + 1) w[i] = $random;
            for (i = 0; i < M; i = i + 1) begin
                exp_y[i] = 0;
                for (j = 0; j < NB*P; j = j + 1) exp_y[i] = exp_y[i] + w[i*NB*P+j] * x[j];
            end
            got = 0;
            axi_write(6'h08, M);
            axi_write(6'h0C, NB);
            axi_write(6'h00, job == 0 ? 32'h3 : 32'h1); // job 1 reuses x
            if (job == 0) for (b = 0; b < NB; b = b + 1) begin
                for (i = 0; i < P; i = i + 1) beat[i*8 +: 8] = x[b*P+i];
                send(beat);
            end
            for (b = 0; b < M*NB; b = b + 1) begin
                for (i = 0; i < P; i = i + 1) beat[i*8 +: 8] = w[b*P+i];
                send(beat);
            end
            r = 0;
            while (!r[1]) axi_read(6'h04, r);
            if (got != M || !irq) begin errs = errs + 1; $display("job %0d: got %0d results irq=%b", job, got, irq); end
            axi_read(6'h10, r);
            $display("job %0d: %0d cycles", job, r);
        end
        if (errs == 0) $display("PASS"); else $display("FAIL (%0d errors)", errs);
        $finish;
    end
endmodule
