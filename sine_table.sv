module sine_table #(parameter ANGLES = 256, parameter SPEED = 5) ();
    localparam PI = 3.14159265358979323846;
    fix_t sine_table[ANGLES];
    generate
        for(genvar i = 0; i < ANGLES; i++) begin
            assign sine_table[i] = fix_t'($rtoi((5*$sin(PI/2 * i/ANGLES)) * 2**8));
        end
    endgenerate
    logic[$clog2(ANGLES)-1:0] pa;
    fix_t px, py, pdx, pdy;

    
endmodule