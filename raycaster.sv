`default_nettype none
`timescale 1ns / 1ps

`define fmask 32'h0000ffff // fractional part
`define imask 32'hffff0000 // integer part
// `define MAP_OVERLAY

// Q16.16 fixed point number
typedef logic signed [31:0] fix_t;

typedef struct packed {
    fix_t x;
    fix_t y;
} vec_t;

typedef struct packed {
    logic is_vert;
    fix_t height;
} line_t;

function fix_t to_fix(input real real_num);
    begin
        to_fix = fix_t'($rtoi(real_num * 2**16));
    end
endfunction

function real to_real(input fix_t fix_num);
    begin
        to_real = $itor(fix_num) / 2**16;
    end
endfunction

function fix_t mult(input fix_t a, b);
    begin
        mult = 32'((48'(a * b)) >>> 16);
    end
endfunction

function logic near(input fix_t a, b, tolerance = to_fix(0.01));
    begin
        near = a > b - tolerance && a < b + tolerance;
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

    localparam real PI = 3.14159265358979323846;
    localparam SAMPLES = 256;
    fix_t sin_table[SAMPLES];
    fix_t sec_table[SAMPLES];
    generate
        for(genvar i = 0; i < SAMPLES; i++) begin
            assign sin_table[i] = to_fix($sin(PI/2 * i/SAMPLES));
            assign sec_table[i] = to_fix(1/$cos(PI/2 * i/SAMPLES));
        end
    endgenerate

    function fix_t sin(input fix_t x);
        fix_t quad = mult(x, to_fix(2 / PI));
        fix_t entry = mult(quad & `fmask, to_fix(SAMPLES));
        logic [$clog2(SAMPLES)-1:0] index = entry[15+$clog2(SAMPLES):16];
        begin
            case (quad[17:16] /*int part mod 4*/)
                2'd0: sin = sin_table[index];
                2'd1: sin = sin_table[SAMPLES-1 - index];
                2'd2: sin = -sin_table[index];
                2'd3: sin = -sin_table[SAMPLES-1 - index];
            endcase
        end
    endfunction
    
    function fix_t sec(input fix_t x);
        fix_t quad = mult(x, to_fix(2 / PI));
        fix_t entry = mult(quad & `fmask, to_fix(SAMPLES));
        logic [$clog2(SAMPLES)-1:0] index = entry[15+$clog2(SAMPLES):16];
        begin
            case (quad[17:16] /*int part mod 4*/)
                2'd0: sec = sec_table[index];
                2'd1: sec = -sec_table[SAMPLES - index];
                2'd2: sec = -sec_table[index];
                2'd3: sec = sec_table[SAMPLES - index];
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
            cot = mult(cos(x), csc(x));
        end
    endfunction

    /* --------------------------- Map --------------------------- */

    localparam MAP_X = 8;
    localparam MAP_Y = 8;
    localparam MAP_S = 64;
    logic map [MAP_Y-1:0][MAP_X-1:0];
    initial begin
        $readmemh("level.mem", map);
    end
    
    function logic is_clipping(input vec_t pos);
        logic [$clog2(MAP_Y)-1:0] my = pos.y[21 + $clog2(MAP_Y):22];
        logic [$clog2(MAP_X)-1:0] mx = pos.x[21 + $clog2(MAP_X):22];
        begin
            is_clipping = map[my][mx];
        end
    endfunction

    /* --------------------------- Movement --------------------------- */

    localparam real SPEED = 2;
    localparam real TURN_SPEED = 0.05;
    localparam real INIT_ANGLE = 0;

    fix_t player_angle = to_fix(INIT_ANGLE);
    vec_t player = { to_fix(MAP_S * MAP_X / 2), to_fix(MAP_S * MAP_Y / 2) };
    vec_t player_delta = {
        to_fix(SPEED*$cos(INIT_ANGLE)), 
        to_fix(SPEED*$sin(INIT_ANGLE))
    };
    wire key_up, key_down, key_left, key_right;
    assign { key_up, key_down, key_left, key_right } = mvmt_in;

    always_ff @(posedge clk_in) begin
        if (frame) begin
            if (key_left || key_right) begin
                if (key_right) begin
                    player_angle += to_fix(TURN_SPEED);
                    if (player_angle >= to_fix(2*PI)) player_angle-=to_fix(2*PI);
                end
                if (key_left) begin
                    player_angle -= to_fix(TURN_SPEED);
                    if (player_angle < to_fix(0)) player_angle+=to_fix(2*PI);
                end
                player_delta.x <= mult(to_fix(SPEED), cos(player_angle));
                player_delta.y <= mult(to_fix(SPEED), sin(player_angle));
            end 

            if (key_up || key_down) begin
                if (key_up) begin
                    player.x += player_delta.x;
                    if (is_clipping(player)) player.x -= player_delta.x;
                    player.y += player_delta.y;
                    if (is_clipping(player)) player.y -= player_delta.y;
                end
                if (key_down) begin
                    player.x -= player_delta.x;
                    if (is_clipping(player)) player.x += player_delta.x;
                    player.y -= player_delta.y;
                    if (is_clipping(player)) player.y += player_delta.y;
                end
                if (player.x < to_fix(5)) player.x = to_fix(5);
                if (player.y < to_fix(5)) player.y = to_fix(5);
                if (player.x > to_fix(H_RES)) player.x = to_fix(H_RES);
                if (player.y > to_fix(V_RES)) player.y = to_fix(V_RES);
            end
        end
    end

    /* --------------------------- Raycasting --------------------------- */

    function fix_t inv_sqrt(input fix_t x);
        fix_t threehalfs = to_fix(1.5);
        fix_t guess;
        begin
            if      (x[30]) guess = 32'sh00000034;
            else if (x[29]) guess = 32'sh00000049;
            else if (x[28]) guess = 32'sh00000068;
            else if (x[27]) guess = 32'sh00000093;
            else if (x[26]) guess = 32'sh000000d1;
            else if (x[25]) guess = 32'sh00000127;
            else if (x[24]) guess = 32'sh000001a2;
            else if (x[23]) guess = 32'sh0000024f;
            else if (x[22]) guess = 32'sh00000344;
            else if (x[21]) guess = 32'sh0000049e;
            else if (x[20]) guess = 32'sh00000688;
            else if (x[19]) guess = 32'sh0000093c;
            else if (x[18]) guess = 32'sh00000d10;
            else if (x[17]) guess = 32'sh00001279;
            else if (x[16]) guess = 32'sh00001a20;
            else if (x[15]) guess = 32'sh000024f3;
            else if (x[14]) guess = 32'sh00003441;
            else if (x[13]) guess = 32'sh000049e6;
            else if (x[12]) guess = 32'sh00006882;
            else if (x[11]) guess = 32'sh000093cd;
            else if (x[10]) guess = 32'sh0000d105;
            else if (x[9])  guess = 32'sh0001279a;
            else if (x[8])  guess = 32'sh0001a20b;
            else if (x[7])  guess = 32'sh00024f34;
            else if (x[6])  guess = 32'sh00034417;
            else if (x[5])  guess = 32'sh00049e69;
            else if (x[4])  guess = 32'sh0006882f;
            else if (x[3])  guess = 32'sh00093cd3;
            else if (x[2])  guess = 32'sh000d105e;
            else if (x[1])  guess = 32'sh001279a7;
            else            guess = 32'sh00200000;
            // Newton's method - x(n+1) =(x(n) * (1.5 - (val/2 * x(n)^2))
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            guess = mult(guess, threehalfs - mult(x >>> 1, mult(guess, guess)));
            inv_sqrt = guess;
        end
    endfunction

    function logic[63:0] sq_dist(vec_t a, vec_t b);
        logic[63:0] run = 64'(a.x) - 64'(b.x);
        logic[63:0] rise = 64'(a.y) - 64'(b.y);
        begin
            sq_dist = (run*run + rise*rise);
        end
    endfunction

    function line_t cast_ray(fix_t angle);
        vec_t h_ray, v_ray;
        vec_t h_ray_delta, v_ray_delta;

        fix_t sqdist;
        logic[63:0] h_sqdist = 64'hefff_ffff_ffff_ffff;
        logic[63:0] v_sqdist = 64'hefff_ffff_ffff_ffff;
            
        fix_t ncot_ra = -cot(angle);
        logic facing_up = angle > to_fix(PI);

        fix_t ntan_ra = -tan(angle);
        logic facing_left = angle > to_fix(PI/2) && angle < to_fix(3*PI/2);

        begin
            // -------- check horizontal walls --------
            h_ray.y = (player.y & 32'hffc00000) + 
                (facing_up ? to_fix(-0.001) : to_fix(MAP_S));
            h_ray.x = mult(player.y - h_ray.y, ncot_ra) + player.x;

            h_ray_delta.y = facing_up ? to_fix(-MAP_S) : to_fix(MAP_S);
            h_ray_delta.x = mult(-h_ray_delta.y, ncot_ra);

            if (!near(angle, to_fix(0)) && !near(angle, to_fix(PI))) begin
                for (integer h_check = 0; h_check < MAP_Y; h_check++) begin
                    if (is_clipping(h_ray)) begin
                        h_sqdist = sq_dist(player, h_ray);
                        break;
                    end
                    h_ray.x += h_ray_delta.x;
                    h_ray.y += h_ray_delta.y;
                end
            end

            // -------- check vertical walls --------
            v_ray.x = (player.x & 32'hffc00000) + 
                (facing_left ? to_fix(-0.001) : to_fix(MAP_S));
            v_ray.y = mult(player.x - v_ray.x, ntan_ra) + player.y;

            v_ray_delta.x = facing_left ? to_fix(-MAP_S) : to_fix(MAP_S);
            v_ray_delta.y = mult(-v_ray_delta.x, ntan_ra);

            if (!near(angle, to_fix(PI/2)) && !near(angle, to_fix(3*PI/2))) begin
                for (integer v_check = 0; v_check < MAP_X; v_check++) begin
                    if (is_clipping(v_ray)) begin
                        v_sqdist = sq_dist(player, v_ray);
                        break;
                    end 
                    v_ray.x += v_ray_delta.x;
                    v_ray.y += v_ray_delta.y;
                end
            end
            
            // -------- get ray height --------
            cast_ray.is_vert = v_sqdist < h_sqdist;
            sqdist = 32'((cast_ray.is_vert ? v_sqdist : h_sqdist) >> 32);
            sqdist = mult(sqdist, cos(player_angle - angle));
            cast_ray.height = mult(inv_sqrt(sqdist), to_fix(H_RES / 4));
        end
    endfunction

    localparam real FOV = PI / 3; // 60deg

    line_t lines [H_RES-1:0];
    always_ff @(posedge clk_in) begin
        // render on new frame and movement change
        if (frame && |(mvmt_in)) begin
            for (integer i = 0; i < H_RES; i++) begin
                fix_t angle = (player_angle - to_fix(FOV / 2.0)) +
                                  to_fix(($itor(i) / $itor(H_RES)) * FOV);
                // normalize angle
                if (angle >= to_fix(2*PI)) angle-=to_fix(2*PI);
                if (angle < to_fix(0)) angle+=to_fix(2*PI);
                lines[i] = cast_ray(angle);
            end
        end
    end

    /* --------------------------- Rendering --------------------------- */

    
    logic [3:0] paint_r, paint_g, paint_b;
    always_comb begin
        logic signed [31:0] bruh =  32'(sy) - 32'(V_RES/2);
        line_t line = lines[sx];
        logic draw = -(line.height >> 17) < bruh && bruh < (line.height >> 17);
        if (draw) begin
            paint_r = line.is_vert ? 4'hf : 4'hc;
            paint_g = 4'h0;
            paint_b = line.is_vert ? 4'hf : 4'h0;
        end else begin
            paint_r = 4'h1;
            paint_g = 4'h3;
            paint_b = 4'h7;
        end
    end
    
`ifdef MAP_OVERLAY
    localparam P_SIZE = 5;
    always_comb begin
        logic player_draw = 
            (32'(sx) >= (player.x >> 16) - P_SIZE) &&
            (32'(sx) <  (player.x >> 16) + P_SIZE) &&
            (32'(sy) >= (player.y >> 16) - P_SIZE) &&
            (32'(sy) <  (player.y >> 16) + P_SIZE);

        logic player_dir = 
            (32'(sx) >= ((player.x + 4 * player_delta.x) >> 16) - P_SIZE) &&
            (32'(sx) <  ((player.x + 4 * player_delta.x) >> 16) + P_SIZE) &&
            (32'(sy) >= ((player.y + 4 * player_delta.y) >> 16) - P_SIZE) &&
            (32'(sy) <  ((player.y + 4 * player_delta.y) >> 16) + P_SIZE);
        logic in_map = sx/MAP_S < MAP_X && sy/MAP_S < MAP_Y;

        logic map_draw = (in_map) && (map[sy / MAP_S][sx / MAP_S]) && (sx % 2 == 0 && sy % 2 == 0);

        logic gridline_draw = (in_map) && (sy % MAP_S == 0 || sx % MAP_S == 0);

        if (!de) begin
            // black in blanking interval
            paint_r = 4'h0;
            paint_g = 4'h0;
            paint_b = 4'h0;
        end else if (player_draw) begin
            paint_r = 4'hf;
            paint_g = 4'h0;
            paint_b = 4'h0;
        end else if (player_dir) begin
            paint_r = 4'h0;
            paint_g = 4'hf;
            paint_b = 4'h0;
        end else if (gridline_draw) begin
            paint_r = 4'h0;
            paint_g = 4'h0;
            paint_b = 4'h0;
        end else if (map_draw) begin
            paint_r = 4'hf;
            paint_g = 4'hf;
            paint_b = 4'hf;
        end
    end
`endif

    always_ff @(posedge clk_in) begin
        sx_out <= sx;
        sy_out <= sy;
        de_out <= de;
        r_out <= de ? {2{paint_r}} : 8'h0;
        g_out <= de ? {2{paint_g}} : 8'h0;
        b_out <= de ? {2{paint_b}} : 8'h0;
    end
endmodule
