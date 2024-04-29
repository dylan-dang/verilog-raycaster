`default_nettype none
`timescale 1ns / 1ps

/**
 * 640x480p60 screen
 */
module screen (
    input  wire logic clk_in,   // clock
    input  wire logic rst_in,   // reset pin
    output      logic [9:0] sx_out,  // horizontal screen position
    output      logic [9:0] sy_out,  // vertical screen position
    output      logic hsync_out,    // horizontal sync
    output      logic vsync_out,    // vertical sync
    output      logic de_out        // data enable (low during blanking interval)
    );

    // horizontal timings
    parameter HA_END = 639;             // end of active pixels
    parameter HS_START = HA_END + 16;   // sync start
    parameter HS_END = HS_START + 96;   // sync end
    parameter LINE   = 799;             // last pixel on line

    // vertical timings
    parameter VA_END = 479;             // end of active pixels
    parameter VS_START = VA_END + 10;   // sync starts after front porch
    parameter VS_END = VS_START + 2;    // sync end
    parameter SCREEN = 524;             // last line on screen

    always_comb begin
        // invert: negative polarity
        hsync_out = ~(sx_out >= HS_START && sx_out < HS_END);  
        vsync_out = ~(sy_out >= VS_START && sy_out < VS_END);
        de_out = (sx_out <= HA_END && sy_out <= VA_END);
    end

    // calculate screen position
    always_ff @(posedge clk_in) begin
        if (sx_out == LINE /* last pixel */) begin 
            sx_out <= 0;
            sy_out <= (sy_out == SCREEN /* last line */) ? 0 : sy_out + 1;
        end else begin
            sx_out <= sx_out + 1;
        end
        if (rst_in) begin
            sx_out <= 0;
            sy_out <= 0;
        end
    end
endmodule
