// Project F: FPGA Graphics - Square (Verilator SDL)
// (C)2023 Will Green, open source hardware released under the MIT License
// Learn more at https://projectf.io/posts/fpga-graphics/

`default_nettype none
`timescale 1ns / 1ps

module raytracer #(parameter CORDW=10) (  // coordinate width
    input  wire logic clk_in,             // pixel clock
    input  wire logic rst_in,             // sim reset
    output      logic [CORDW-1:0] sx_out,  // horizontal screen position
    output      logic [CORDW-1:0] sy_out,  // vertical screen position
    output      logic de_out,              // data enable (low in blanking interval)
    output      logic [7:0] r_out,         // 8-bit red
    output      logic [7:0] g_out,         // 8-bit green
    output      logic [7:0] b_out          // 8-bit blue
    );

    // display sync signals and coordinates
    logic [CORDW-1:0] sx, sy;
    logic de;

    screen display_inst (
        .clk_in,
        .rst_in,
        .sx_out(sx),
        .sy_out(sy),
        .hsync_out(),
        .vsync_out(),
        .de_out(de)
    );

    // define a square with screen coordinates
    logic square;
    always_comb begin
        square = (sx > 220 && sx < 420) && (sy > 140 && sy < 340);
    end

    // paint colour: white inside square, blue outside
    logic [3:0] paint_r, paint_g, paint_b;
    always_comb begin
        paint_r = (square) ? 4'hF : 4'h1;
        paint_g = (square) ? 4'hF : 4'h3;
        paint_b = (square) ? 4'hF : 4'h7;
    end

    // display colour: paint colour but black in blanking interval
    logic [3:0] display_r, display_g, display_b;
    always_comb begin
        display_r = (de) ? paint_r : 4'h0;
        display_g = (de) ? paint_g : 4'h0;
        display_b = (de) ? paint_b : 4'h0;
    end

    // SDL output (8 bits per colour channel)
    always_ff @(posedge clk_in) begin
        sx_out <= sx;
        sy_out <= sy;
        de_out <= de;
        r_out <= {2{display_r}};  // double signal width from 4 to 8 bits
        g_out <= {2{display_g}};
        b_out <= {2{display_b}};
    end
endmodule
