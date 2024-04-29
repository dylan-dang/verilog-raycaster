`ifndef __DEFS_H
`define __DEFS_H

typedef logic [15:0] halfword_t;
typedef struct packed {
    halfword_t int_part;
    halfword_t frac_part;
} word_t;

function word_t to_fixed(real n);
    to_fixed = word_t'($rtoi(n * 2 ** $bits(halfword_t)));
endfunction

function real to_real(word_t n);
    to_real = $itor(n) / 2 ** $bits(halfword_t);
endfunction

function word_t pad_frac(halfword_t frac_part);
    pad_frac = {halfword_t'(0), frac_part};
endfunction

function word_t pad_int(halfword_t int_part);
    pad_int = {int_part, halfword_t'(0)};
endfunction

`endif