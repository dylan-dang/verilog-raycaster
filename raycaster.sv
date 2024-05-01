`default_nettype none
`timescale 1ns / 1ps

`define LEVEL       "levels/8x8/multi.mem"
`define MAP_X       8  
`define MAP_Y       8 
`define MAP_SCALE_X 64.0
`define MAP_SCALE_Y 64.0
`define MAP_SCALE_Z 64.0
`define MAP_WRAP

`define TEX_X 256
`define TEX_Y 256

`define PLAYER_SPEED      2.0
`define PLAYER_TURN_SPEED 0.05 // radians
`define PLAYER_INIT_X     (MAP_SCALE_X * MAP_X / 2)
`define PLAYER_INIT_Y     (MAP_SCALE_Y * MAP_Y / 2)
`define PLAYER_INIT_ANGLE 0.0

`define FOV (PI / 3) // 60deg

`define TRIG_SAMPLES 256

// `define MAP_OVERLAY
`define OVERLAY_SCALE_X     0.5
`define OVERLAY_SCALE_Y     0.5
`define OVERLAY_OFFSET_X    0.0
`define OVERLAY_OFFSET_Y    0.0
`define OVERLAY_PLAYER_SIZE 5.0

// Q16.16 fixed point number
typedef logic signed [31:0] fix_t;

typedef logic[7:0] uint8_t;
typedef logic[15:0] uint16_t;
typedef logic[31:0] uint32_t;

typedef struct packed {
    fix_t x;
    fix_t y;
} vec_t;

typedef enum logic[1:0] {
    CELL_AIR,
    CELL_OSAKA,
    CELL_GRASS,
    CELL_HUOHUO
} cell_t;

typedef struct packed {
    logic is_vert;
    fix_t inv_dist;
    fix_t distance;
    vec_t pos;
    cell_t cell_type;
} ray_t;

typedef struct packed {
    logic is_vert;
    fix_t height;
    fix_t inv_height;
    vec_t ray_pos;
    fix_t ray_angle;
    cell_t cell_type;
} line_t;

typedef struct packed {
    uint8_t b;
    uint8_t g;
    uint8_t r;
} color_t;

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

module raycaster (
    input  wire logic clk_in,        // pixel clock
    input  wire logic rst_in,        // reset pin
    input  wire logic[3:0] mvmt_in,  // player movement keys
    output      logic [9:0] sx_out,  // horizontal screen position
    output      logic [9:0] sy_out,  // vertical screen position
    output      logic de_out,        // data enable (low in blanking interval)
    output      uint8_t r_out,       // 8-bit red
    output      uint8_t g_out,       // 8-bit green
    output      uint8_t b_out        // 8-bit blue
    );

    /* --------------------------- screen --------------------------- */

    logic [9:0] sx, sy; // screen position

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
    localparam TRIG_SAMPLES = `TRIG_SAMPLES;
    fix_t sin_table[TRIG_SAMPLES];
    fix_t sec_table[TRIG_SAMPLES];
    generate
        for(genvar i = 0; i < TRIG_SAMPLES; i++) begin
            assign sin_table[i] = to_fix($sin(PI/2 * i/TRIG_SAMPLES));
            assign sec_table[i] = to_fix(1/$cos(PI/2 * i/TRIG_SAMPLES));
        end
    endgenerate

    function fix_t sin(input fix_t x);
        fix_t quad = mult(x, to_fix(2 / PI));
        fix_t entry = mult(quad & 32'h0000ffff, to_fix(TRIG_SAMPLES));
        logic[$clog2(TRIG_SAMPLES)-1:0] index = 
            entry[15+$clog2(TRIG_SAMPLES):16];
        begin
            case (quad[17:16] /*int part mod 4*/)
                2'd0: sin = sin_table[index];
                2'd1: sin = sin_table[TRIG_SAMPLES-1 - index];
                2'd2: sin = -sin_table[index];
                2'd3: sin = -sin_table[TRIG_SAMPLES-1 - index];
            endcase
        end
    endfunction
    
    function fix_t sec(input fix_t x);
        fix_t quad = mult(x, to_fix(2 / PI));
        fix_t entry = mult(quad & 32'h0000ffff, to_fix(TRIG_SAMPLES));
        logic [$clog2(TRIG_SAMPLES)-1:0] index = entry[15+$clog2(TRIG_SAMPLES):16];
        begin
            case (quad[17:16] /*int part mod 4*/)
                2'd0: sec = sec_table[index];
                2'd1: sec = -sec_table[TRIG_SAMPLES - index];
                2'd2: sec = -sec_table[index];
                2'd3: sec = sec_table[TRIG_SAMPLES - index];
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

    localparam MAP_X = `MAP_X;
    localparam MAP_Y = `MAP_Y;
    localparam real MAP_SCALE_X = `MAP_SCALE_X;
    localparam real MAP_SCALE_Y = `MAP_SCALE_Y;
    localparam real MAP_SCALE_Z = `MAP_SCALE_Z;

    cell_t map [MAP_Y-1:0][MAP_X-1:0];
    initial begin
        $readmemh(`LEVEL, map);
    end

    function logic in_bounds(input vec_t pos);
        begin
            in_bounds = pos.x >= to_fix(0) && pos.x < to_fix(MAP_X*MAP_SCALE_X) &&
                        pos.y >= to_fix(0) && pos.y < to_fix(MAP_Y*MAP_SCALE_Y);
        end
    endfunction
    
    function cell_t cell_at(input vec_t pos);
        begin
            cell_at = map[(mult(pos.y, to_fix(1.0/MAP_SCALE_Y)) >> 16) % MAP_Y]
                         [(mult(pos.x, to_fix(1.0/MAP_SCALE_X)) >> 16) % MAP_X];
`ifndef MAP_WRAP
            if (!in_bounds(pos)) cell_at = CELL_AIR;
`endif
        end
    endfunction

    /* --------------------------- Texture --------------------------- */

    localparam TEX_X = `TEX_X;
    localparam TEX_Y = `TEX_Y;

    typedef color_t texture_t [(TEX_X*TEX_Y)-1:0];

    texture_t textures[2:0];

    function texture_t load_bmp (string path);
        integer fd;
        uint16_t signature, color_planes, bpp;
        uint32_t data_offset, width, height;
        texture_t texture;
        begin
            fd = $fopen(path, "rb");
            $fread(signature, fd, 0);
            if (signature != 16'h424d) begin
                $display("image is not a bitmap");
                $finish;
            end
            $fseek(fd, 32'ha, 0);
            $fread(data_offset, fd);
            data_offset = {<<8{data_offset}}; // reverse endianness

            $fseek(fd, 32'h12, 0);
            $fread(width, fd);
            width = {<<8{width}};
            $fread(height, fd);
            height = {<<8{height}};
            if (width != TEX_X || height != TEX_Y) begin
                $display("image is must be %dx%d, found %dx%d.", TEX_X, TEX_Y,
                width, height);
                $finish;
            end

            $fread(color_planes, fd);
            color_planes = {<<8{color_planes}};
            if (color_planes != 1) begin
                $display("image must have 1 color plane, found %d.", 
                         color_planes);
            end

            $fread(bpp, fd);
            bpp = {<<8{bpp}};
            if (bpp != 24) begin
                $display("image encoding must be 24-bit/pixel, found %d.", bpp);
            end

            $fseek(fd, data_offset, 0);
            $fread(texture, fd);
            $fclose(fd);
            load_bmp = texture;
        end
    endfunction

    initial begin
        textures[CELL_OSAKA-1] = load_bmp("textures/osaka.bmp");
        textures[CELL_GRASS-1] = load_bmp("textures/grass.bmp");
        textures[CELL_HUOHUO-1] = load_bmp("textures/huohuo.bmp");
    end


    /* --------------------------- Movement --------------------------- */

    localparam real PLAYER_SPEED = `PLAYER_SPEED;
    localparam real PLAYER_TURN_SPEED = `PLAYER_TURN_SPEED;
    localparam real PLAYER_INIT_ANGLE = `PLAYER_INIT_ANGLE;
    localparam real PLAYER_INIT_X = `PLAYER_INIT_X;
    localparam real PLAYER_INIT_Y = `PLAYER_INIT_Y;

    fix_t player_angle = to_fix(PLAYER_INIT_ANGLE);
    vec_t player = {
        to_fix(PLAYER_INIT_X),
        to_fix(PLAYER_INIT_Y)
    };
    vec_t player_delta = {
        to_fix(PLAYER_SPEED*$cos(PLAYER_INIT_ANGLE)), 
        to_fix(PLAYER_SPEED*$sin(PLAYER_INIT_ANGLE))
    };
    wire key_up, key_down, key_left, key_right;
    assign { key_up, key_down, key_left, key_right } = mvmt_in;

    always_ff @(posedge clk_in) begin
        if (frame) begin
            if (key_left || key_right) begin
                if (key_right) begin
                    player_angle += to_fix(PLAYER_TURN_SPEED);
                    if (player_angle >= to_fix(2*PI)) 
                        player_angle-=to_fix(2*PI);
                end
                if (key_left) begin
                    player_angle -= to_fix(PLAYER_TURN_SPEED);
                    if (player_angle < to_fix(0)) player_angle+=to_fix(2*PI);
                end
                player_delta.x <= mult(to_fix(PLAYER_SPEED), cos(player_angle));
                player_delta.y <= mult(to_fix(PLAYER_SPEED), sin(player_angle));
            end 

            if (key_up || key_down) begin
                if (key_up) begin
                    player.x += player_delta.x;
                    if (|cell_at(player)) player.x -= player_delta.x;
                    player.y += player_delta.y;
                    if (|cell_at(player)) player.y -= player_delta.y;
                end
                if (key_down) begin
                    player.x -= player_delta.x;
                    if (|cell_at(player)) player.x += player_delta.x;
                    player.y -= player_delta.y;
                    if (|cell_at(player)) player.y += player_delta.y;
                end
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
            // Newton's method
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

    localparam logic[63:0] i64_MAX = 64'hefff_ffff_ffff_ffff;
    localparam logic[31:0] i32_MAX = 32'hefff_ffff;

    function ray_t cast_ray(fix_t angle);
        vec_t h_ray, v_ray;
        vec_t h_ray_delta, v_ray_delta;

        fix_t sqdist_scl, inv_dist_scl;
        logic[63:0] h_sqdist = i64_MAX;
        logic[63:0] v_sqdist = i64_MAX;
        logic[63:0] sqdist;
            
        fix_t ncot_ra = -cot(angle);
        logic facing_up = angle > to_fix(PI);

        fix_t ntan_ra = -tan(angle);
        logic facing_left = angle > to_fix(PI/2) && angle < to_fix(3*PI/2);
        fix_t h_fuzz = to_fix(0.2), v_fuzz = to_fix(0.2);
        logic clip_h, clip_v;
        
        begin
            // -------- check horizontal walls --------
            
            // round down to nearest scale unit
            h_ray.y = mult(mult(player.y, to_fix(1.0/MAP_SCALE_Y)) &
                      32'hffff0000, to_fix(MAP_SCALE_Y));
            // start at first possible wall intersection
            if (!facing_up) h_ray.y += to_fix(MAP_SCALE_Y);
            h_ray.x = mult(player.y - h_ray.y, ncot_ra) + player.x;

            h_ray_delta.y = facing_up ? to_fix(-MAP_SCALE_Y) : to_fix(MAP_SCALE_Y);
            h_ray_delta.x = mult(-h_ray_delta.y, ncot_ra);
            h_fuzz = facing_up ? to_fix(-0.2) : to_fix(0.2);

            if (!near(angle, to_fix(0)) && !near(angle, to_fix(PI))) begin
                for (integer h_check = 0; h_check < MAP_Y; h_check++) begin
                    h_ray.y += h_fuzz;
                    clip_h = |cell_at(h_ray);
                    h_ray.y += h_fuzz;
                    if (clip_h) begin
                        h_sqdist = sq_dist(player, h_ray);
                        break;
                    end
                    h_ray.x += h_ray_delta.x;
                    h_ray.y += h_ray_delta.y;
                end
            end

            // -------- check vertical walls --------

            // round down to nearest scale unit
            v_ray.x = mult(mult(player.x, to_fix(1.0/MAP_SCALE_X)) &
                      32'hffff0000, to_fix(MAP_SCALE_X));
            // start at first possible wall intersection
            v_ray.x += facing_left ? 0 : to_fix(MAP_SCALE_X);
            v_ray.y = mult(player.x - v_ray.x, ntan_ra) + player.y;

            v_ray_delta.x = facing_left ? to_fix(-MAP_SCALE_X) : to_fix(MAP_SCALE_X);
            v_ray_delta.y = mult(-v_ray_delta.x, ntan_ra);
            v_fuzz = facing_left ? to_fix(-0.2) : to_fix(0.2);

            if (
                !near(angle, to_fix(PI/2)) &&
                !near(angle, to_fix(3*PI/2))
            ) begin
                for (integer v_check = 0; v_check < MAP_X; v_check++) begin
                    v_ray.x += v_fuzz;
                    clip_v = |cell_at(v_ray);
                    v_ray.x -= v_fuzz;
                    if (clip_v) begin
                        v_sqdist = sq_dist(player, v_ray);
                        break;
                    end 
                    v_ray.x += v_ray_delta.x;
                    v_ray.y += v_ray_delta.y;
                end
            end
            
            // -------- set ray info --------
            cast_ray.is_vert = v_sqdist < h_sqdist;
            sqdist = cast_ray.is_vert ? v_sqdist : h_sqdist;
            if (sqdist == i64_MAX) begin
                cast_ray.distance = i32_MAX;
                cast_ray.inv_dist = 0;
                cast_ray.pos = player;
                cast_ray.cell_type = CELL_AIR;
            end else begin
                sqdist_scl = 32'(sqdist >> 32); // d^2 / 2^16
                inv_dist_scl = inv_sqrt(sqdist_scl); // 1/sqrt(d^2/2^16) = 2^8/d

                cast_ray.inv_dist = inv_dist_scl >> 8;
                cast_ray.distance = mult(inv_dist_scl, sqdist_scl) << 8;
                cast_ray.pos = cast_ray.is_vert ? v_ray : h_ray;
                cast_ray.cell_type = cell_at(cast_ray.pos);
            end
        end
    endfunction


    /* --------------------------- Rendering --------------------------- */
    
    localparam real FOV = `FOV;

    // ray_t rays [H_RES-1:0];
    line_t lines[H_RES-1:0];
    always_ff @(posedge clk_in) begin
        // render on new frame and movement change
        if (frame && |(mvmt_in)) begin
            for (integer i = 0; i < H_RES; i++) begin
                ray_t ray;
                fix_t angle = (player_angle - to_fix(FOV / 2.0)) +
                                  to_fix(($itor(i) / $itor(H_RES)) * FOV);
                // normalize angle
                if (angle >= to_fix(2*PI)) angle-=to_fix(2*PI);
                if (angle < to_fix(0)) angle+=to_fix(2*PI);
                ray = cast_ray(angle);
                // scale by secant of camera angle to fix fisheye
                lines[i].height =
                    mult(mult(mult(ray.inv_dist, to_fix(MAP_SCALE_Z)),
                    to_fix(H_RES)), sec(player_angle - angle));
                // inverse operations of lines[i].height
                lines[i].inv_height = 
                    mult(mult(mult(ray.distance, to_fix(1.0/MAP_SCALE_Z)),
                    to_fix(1.0/H_RES)), cos(player_angle - angle));

                lines[i].is_vert = ray.is_vert;
                lines[i].ray_pos = ray.pos;
                lines[i].ray_angle = angle;
                lines[i].cell_type = ray.cell_type;
            end
        end
    end


    color_t color;
    always_comb begin
        uint8_t ty, tx;
        line_t line = lines[sx];
        fix_t sy_f = 32'(sy) << 16;
        logic drawing_wall = near(sy_f, to_fix(V_RES/2), line.height >> 1);

        if (drawing_wall) begin
            ty =8'((mult(sy_f - to_fix(V_RES/2), line.inv_height)
                    + to_fix(0.5)) >> (16 - $clog2(TEX_Y)));
            ty = -ty; // flip for bmp reading
            if (line.is_vert) begin
                tx = 8'(mult(line.ray_pos.y, to_fix(1.0/MAP_SCALE_Y)) >> 
                    (16 - $clog2(TEX_X)));
                // flip texture if 90deg < angle < 270deg
                if (line.ray_angle > to_fix(PI/2) &&
                    line.ray_angle < to_fix(3*PI/2)) tx = -tx;
            end else begin
                tx = 8'(mult(line.ray_pos.x, to_fix(1.0/MAP_SCALE_X)) >>
                    (16 - $clog2(TEX_X)));
                // flip texture if angle < 180deg
                if (line.ray_angle < to_fix(PI)) tx = -tx;
            end
            // flip texture if angle > 180deg
            color = textures[line.cell_type-1][TEX_Y*ty + tx];
            // shade vertical walls
            if (line.is_vert) begin
                color.r >>= 1;
                color.g >>= 1;
                color.b >>= 1;
            end
        end else begin
            color = { 8'h77, 8'h33, 8'h11 };
        end
    end
    
`ifdef MAP_OVERLAY
    localparam real OVERLAY_SCALE_X = `OVERLAY_SCALE_X;
    localparam real OVERLAY_SCALE_Y = `OVERLAY_SCALE_Y;
    localparam real OVERLAY_OFFSET_X = `OVERLAY_OFFSET_X;
    localparam real OVERLAY_OFFSET_Y = `OVERLAY_OFFSET_Y;
    localparam real OVERLAY_PLAYER_SIZE = `OVERLAY_PLAYER_SIZE;

    always_comb begin
        vec_t s_pos, s_cell_pos;
        vec_t bruh;
        logic in_map_bounds;
        cell_t cell_overlay;
        uint8_t ty, tx;

        s_pos.x = mult(32'(sx) << 16, to_fix(1/OVERLAY_SCALE_X)) -
                       to_fix(OVERLAY_OFFSET_X);
        s_pos.y = mult(32'(sy) << 16, to_fix(1/OVERLAY_SCALE_Y)) -
                       to_fix(OVERLAY_OFFSET_Y);

        s_cell_pos.x = s_pos.x % to_fix(MAP_SCALE_X);
        s_cell_pos.y = s_pos.y % to_fix(MAP_SCALE_Y);

        in_map_bounds = in_bounds(s_pos);
        cell_overlay = cell_at(s_pos);

        if (
            near(s_pos.x, player.x, to_fix(OVERLAY_PLAYER_SIZE)) &&
            near(s_pos.y, player.y, to_fix(OVERLAY_PLAYER_SIZE))
        ) begin
            // drawing player position
            color = { 8'h0, 8'h0, 8'hff };
        end else if (
            near(s_pos.x, player.x + player_delta.x, 
                 to_fix(OVERLAY_PLAYER_SIZE)) &&
            near(s_pos.y, player.y + player_delta.y,
                 to_fix(OVERLAY_PLAYER_SIZE))
        ) begin
            // drawing player direction
            color = { 8'h0, 8'hff, 8'hff };
        end else if (
            in_map_bounds &&
            (near(s_cell_pos.x, 0) || near(s_cell_pos.y, 0))
        ) begin
            // drawing gridline
            color = { 8'h0, 8'h0, 8'h0 };
        end else if (in_map_bounds && |cell_overlay) begin
            // drawing map cell
            tx = 8'(mult(s_cell_pos.x, to_fix(TEX_X/MAP_SCALE_X)) >> 16);
            ty = -(8'(mult(s_cell_pos.y, to_fix(TEX_Y/MAP_SCALE_Y)) >> 16));
            color = textures[cell_overlay-1][ty * TEX_Y + tx];
        end
    end
`endif

    always_ff @(posedge clk_in) begin
        sx_out <= sx;
        sy_out <= sy;
        de_out <= de;
        { b_out, g_out, r_out } <= de ? color : { 8'h0, 8'h0, 8'h0 };
    end
endmodule
