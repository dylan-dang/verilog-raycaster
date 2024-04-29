`default_nettype none
`timescale 1ns / 1ps


// Q8.8 fixed point number
typedef logic signed [15:0] fix_t;

module raytracer (  // coordinate width
    input  wire logic clk_in,             // pixel clock
    input  wire logic rst_in,             // sim reset
    input  wire logic[3:0] mvmt_in,       // player movement
    output      logic [9:0] sx_out,  // horizontal screen position
    output      logic [9:0] sy_out,  // vertical screen position
    output      logic de_out,              // data enable (low in blanking interval)
    output      logic [7:0] r_out,         // 8-bit red
    output      logic [7:0] g_out,         // 8-bit green
    output      logic [7:0] b_out          // 8-bit blue
    );

    /* --------------------------- screen --------------------------- */

    logic [9:0] sx, sy;
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

    localparam H_RES = 640;  // horizontal screen resolution
    localparam V_RES = 480;  // vertical screen resolution

    logic frame;  // high for one tick at the start of vertical blanking
    always_comb frame = (sy == V_RES && sx == 0);

    /* --------------------------- sine LUT --------------------------- */

    localparam SPEED = 5;
    localparam ANGLES = 256;
    fix_t sine_table[ANGLES];
    localparam PI = 3.14159265358979323846;
    generate
        for(genvar i = 0; i < ANGLES; i++) begin
            assign sine_table[i] = fix_t'($rtoi((SPEED*$sin(2*PI * i/ANGLES)) * 2**8));
        end
    endgenerate

    /* --------------------------- Map --------------------------- */

    localparam MAP_X = 8;
    localparam MAP_Y = 8;
    logic map [MAP_X-1:0][MAP_Y-1:0];
    initial begin
        $readmemh("level.mem", map);
    end

    /* --------------------------- Movement --------------------------- */

    localparam INIT_ANGLE = PI / 2;
    logic[$clog2(ANGLES)-1:0] pa = ($clog2(ANGLES))'($rtoi(INIT_ANGLE/(2*PI)*ANGLES));
    fix_t px = 16'd20 << 8;
    fix_t py = 16'd20 << 8;
    fix_t pdx = fix_t'($rtoi((SPEED*$cos(INIT_ANGLE)) * 2**8));
    fix_t pdy = fix_t'($rtoi((SPEED*$sin(INIT_ANGLE)) * 2**8));
    wire forward, backward, left, right;
    assign { forward, backward, left, right } = mvmt_in;

    always_ff @(posedge clk_in) begin
        if (frame) begin
            if (left || right) begin
                pa = pa - ($clog2(ANGLES))'(left) + ($clog2(ANGLES))'(right);
                pdx <= sine_table[pa + ANGLES/4];
                pdy <= sine_table[pa];
            end
            if (forward) begin
                px += pdx;
                py += pdy;
            end
            if (backward) begin
                px -= pdx;
                py -= pdy;
            end
        end
    end

    /* --------------------------- Rendering --------------------------- */

    localparam Q_SIZE = 20;
        logic square, square_2;
        always_comb begin
            /* verilator lint_off WIDTH */
            square = (sx >= (px >> 6)) && (sx < (px >> 6) + Q_SIZE) && (sy >= (py >> 6)) && (sy < (py >> 6) + Q_SIZE);
            square_2 = (sx >= ((px+pdx) >> 6)) && (sx < ((px+pdx) >> 6) + Q_SIZE) && (sy >= ((py+pdy) >> 6)) && (sy < ((py+pdy) >> 6) + Q_SIZE);

        end

        // paint colour: white inside square, blue outside
        logic [3:0] paint_r, paint_g, paint_b;
        always_comb begin
            paint_r = (square) ? 4'hF : (square_2) ? 4'hc : 4'h1;
            paint_g = (square) ? 4'hF : (square_2) ? 4'hc : 4'h3;
            paint_b = (square) ? 4'hF : (square_2) ? 4'hc : 4'h7;
        end

        // display colour: paint colour but black in blanking interval
        logic [3:0] display_r, display_g, display_b;
        always_comb begin
            display_r = (de) ? paint_r : 4'h0;
            display_g = (de) ? paint_g : 4'h0;
            display_b = (de) ? paint_b : 4'h0;
        end

    always_ff @(posedge clk_in) begin
        sx_out <= sx;
        sy_out <= sy;
        de_out <= de;
        /* verilator lint_off WIDTH */
        r_out <= {2{display_r}};
        g_out <= {2{display_g}};
        b_out <= {2{display_b}};
    end
endmodule
