`default_nettype none
`timescale 1ns / 1ps

`define fmask 32'h0000ffff // fractional part
`define imask 32'hffff0000 // integer part

// Q16.16 fixed point number
typedef logic signed [31:0] fix_t;

function fix_t to_fix(input real real_num);
    begin
        to_fix = fix_t'($rtoi(real_num * 2**16));
    end
endfunction

function real to_real(input fix_t fix_num);
    begin
        to_real = $itor(32'(fix_num)) / 2**16;
    end
endfunction

function fix_t mult(input fix_t a, input fix_t b);
    begin
        mult = 32'((48'(a * b)) >>> 16);
    end
endfunction

module raycaster (  // coordinate width
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

    /* --------------------------- trig LUT --------------------------- */
    // feature idea: lerp between entries

    localparam SAMPLES = 256;
    fix_t sin_table[SAMPLES];
    fix_t sec_table[SAMPLES];
    localparam PI = 3.14159265358979323846;
    generate
        for(genvar i = 0; i < SAMPLES; i++) begin
            assign sin_table[i] = to_fix($sin(PI/2 * i/SAMPLES));
            assign sec_table[i] = to_fix(1/$cos(PI/2 * i/SAMPLES));
        end
    endgenerate

    function fix_t sin(input fix_t x);
        begin
            fix_t quad = mult(x, to_fix(2 / PI));
            fix_t entry = mult(quad & `fmask, to_fix(SAMPLES));
            logic [$clog2(SAMPLES)-1:0] index = entry[15+$clog2(SAMPLES):16];
            case (quad[17:16] /*int part mod 4*/)
                2'd0: sin = sin_table[index];
                2'd1: sin = sin_table[SAMPLES - index];
                2'd2: sin = -sin_table[index];
                2'd3: sin = -sin_table[SAMPLES - index];
            endcase
        end
    endfunction
    
    function fix_t sec(input fix_t x);
        begin
            fix_t quad = mult(x, to_fix(2 / PI));
            fix_t entry = mult(quad & `fmask, to_fix(SAMPLES));
            logic [$clog2(SAMPLES)-1:0] index = entry[15+$clog2(SAMPLES):16];
            case (quad[17:16] /*int part mod 4*/)
                2'd0: sec = sec_table[index];
                2'd1: sec = -sec_table[SAMPLES - index];
                2'd2: sec = sec_table[SAMPLES - index];
                2'd3: sec = -sec_table[index];
            endcase
        end
    endfunction

    function fix_t cos(input fix_t x);
        begin
            cos = sin(x + to_fix(PI/2));
        end
    endfunction

    function fix_t csc(input fix_t x);
        begin
            csc = sec(x + to_fix(3*PI/2));
        end
    endfunction

    function fix_t tan(input fix_t x);
        begin
            tan = mult(sin(x), sec(x));
        end
    endfunction

    function fix_t cot(input fix_t x);
        begin
            tan = mult(cos(x), csc(x));
        end
    endfunction

    /* --------------------------- Map --------------------------- */

    localparam MAP_X = 8;
    localparam MAP_Y = 8;
    logic map [MAP_X-1:0][MAP_Y-1:0];
    initial begin
        $readmemh("level.mem", map);
    end

    /* --------------------------- Movement --------------------------- */

    localparam SPEED = to_fix(5);
    localparam TURN_SPEED = to_fix(0.1);
    localparam INIT_ANGLE = PI / 2;

    fix_t pa = to_fix(INIT_ANGLE);
    fix_t px = to_fix(1);
    fix_t py = to_fix(1);
    fix_t pdx = to_fix(SPEED*$cos(INIT_ANGLE));
    fix_t pdy = to_fix(SPEED*$sin(INIT_ANGLE));
    wire key_up, key_down, key_left, key_right;
    assign { key_up, key_down, key_left, key_right } = mvmt_in;

    always_ff @(posedge clk_in) begin
        if (frame) begin
            if (key_left) begin
                pa += TURN_SPEED;
                if (pa < to_fix(0)) pa+=to_fix(2*PI);
                pdx <= mult(SPEED, cos(pa));
                pdy <= mult(SPEED, sin(pa));
            end
            if (key_right) begin
                pa -= TURN_SPEED;
                if (pa > to_fix(2*PI)) pa-=to_fix(2*PI);
                pdx <= mult(SPEED, cos(pa));
                pdy <= mult(SPEED, sin(pa));
            end
            if (key_up) begin
                px += pdx;
                py += pdy;
            end
            if (key_down) begin
                px -= pdx;
                py -= pdy;
            end
        end
    end

    /* --------------------------- Raycasting --------------------------- */
    
    localparam FOV = to_fix(PI/3); // 60deg


    /* --------------------------- Rendering --------------------------- */

    localparam Q_SIZE = 20;
        logic square, square_2;
        always_comb begin
            /* verilator lint_off WIDTH */
            square = (sx >= (px >> 16)) && (sx < (px >> 16) + Q_SIZE) && (sy >= (py >> 16)) && (sy < (py >> 16) + Q_SIZE);
            square_2 = (sx >= ((px+pdx) >> 16)) && (sx < ((px+pdx) >> 16) + Q_SIZE) && (sy >= ((py+pdy) >> 16)) && (sy < ((py+pdy) >> 16) + Q_SIZE);

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
