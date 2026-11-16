// VC707 bring-up status on the 8 user LEDs (GPIO_LED_0..7):
//   0 MIG MMCM locked          4 heartbeat on MIG ui_clk (200 MHz)
//   1 DDR3 calibration done    5 heartbeat on system clock (100 MHz)
//   2 100 MHz clk_wiz locked   6 CPU held in reset
//   3 peripheral reset released 7 MIG ui_clk_sync_rst asserted
`default_nettype none
module status_leds (
    input  wire       clk_ui,
    input  wire       clk_sys,
    input  wire       mig_locked,
    input  wire       calib_done,
    input  wire       sys_locked,
    input  wire       periph_aresetn,
    input  wire       mb_reset,
    input  wire       ui_rst,
    output wire [7:0] led
);
    reg [27:0] cnt_ui = 0;
    reg [26:0] cnt_sys = 0;
    always @(posedge clk_ui)  cnt_ui  <= cnt_ui + 1'b1;
    always @(posedge clk_sys) cnt_sys <= cnt_sys + 1'b1;
    assign led = {ui_rst, mb_reset, cnt_sys[26], cnt_ui[27], periph_aresetn, sys_locked, calib_done, mig_locked};
endmodule
`default_nettype wire
