#define vmodule   Vraytracer
#define STR(x)    #x
#define HEADER(x) STR(x.h)

#include <SDL.h>
#include <stdio.h>
#include <verilated.h>

#include HEADER(vmodule)

// screen dimensions
const int H_RES = 640;
const int V_RES = 480;

typedef struct Pixel {
    uint8_t a;  // alpha
    uint8_t b;  // blue
    uint8_t g;  // green
    uint8_t r;  // red
} Pixel;

int main(int argc, char* argv[]) {
    Verilated::commandArgs(argc, argv);

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        printf("SDL init failed.\n");
        return 1;
    }

    Pixel screenbuffer[H_RES * V_RES];

    SDL_Window* sdl_window = NULL;
    SDL_Renderer* sdl_renderer = NULL;
    SDL_Texture* sdl_texture = NULL;

    sdl_window = SDL_CreateWindow("Output", SDL_WINDOWPOS_CENTERED,
                                  SDL_WINDOWPOS_CENTERED, H_RES, V_RES,
                                  SDL_WINDOW_SHOWN);
    if (!sdl_window) {
        printf("Window creation failed: %s\n", SDL_GetError());
        return 1;
    }

    sdl_renderer = SDL_CreateRenderer(
        sdl_window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!sdl_renderer) {
        printf("Renderer creation failed: %s\n", SDL_GetError());
        return 1;
    }

    sdl_texture = SDL_CreateTexture(sdl_renderer, SDL_PIXELFORMAT_RGBA8888,
                                    SDL_TEXTUREACCESS_TARGET, H_RES, V_RES);
    if (!sdl_texture) {
        printf("Texture creation failed: %s\n", SDL_GetError());
        return 1;
    }

    // https://wiki.libsdl.org/SDL_GetKeyboardState
    const Uint8* keyb_state = SDL_GetKeyboardState(NULL);

    // initialize Verilog module
    vmodule* mod = new vmodule;

    // reset
    mod->rst_in = 1;
    mod->clk_in = 0;
    mod->eval();
    mod->clk_in = 1;
    mod->eval();
    mod->rst_in = 0;
    mod->clk_in = 0;
    mod->eval();

    uint64_t start_ticks = SDL_GetPerformanceCounter();
    uint64_t frame_count = 0;

    while (true) {
        // cycle clock
        mod->clk_in = 1;
        mod->eval();
        mod->clk_in = 0;
        mod->eval();

        if (mod->de_out) {
            // update screen during drawing interval
            Pixel* p = &screenbuffer[mod->sy_out * H_RES + mod->sx_out];
            p->a = 0xFF;
            p->b = mod->b_out;
            p->g = mod->g_out;
            p->r = mod->r_out;
        }

        // update texture once per frame (in blanking)
        if (mod->sy_out == V_RES && mod->sx_out == 0) {
            SDL_Event e;
            if (SDL_PollEvent(&e) && e.type == SDL_QUIT) break;
            // quit when q is pressed
            if (keyb_state[SDL_SCANCODE_Q]) break;

            // read player movement
            mod->mvmt_in =
                ((keyb_state[SDL_SCANCODE_UP] || keyb_state[SDL_SCANCODE_W])
                 << 3) |
                ((keyb_state[SDL_SCANCODE_DOWN] || keyb_state[SDL_SCANCODE_S])
                 << 2) |
                ((keyb_state[SDL_SCANCODE_LEFT] || keyb_state[SDL_SCANCODE_A])
                 << 1) |
                (keyb_state[SDL_SCANCODE_RIGHT] || keyb_state[SDL_SCANCODE_D]);

            SDL_UpdateTexture(sdl_texture, NULL, screenbuffer,
                              H_RES * sizeof(Pixel));
            SDL_RenderClear(sdl_renderer);
            SDL_RenderCopy(sdl_renderer, sdl_texture, NULL, NULL);
            SDL_RenderPresent(sdl_renderer);
            frame_count++;
        }
    }

    // calculate frame rate
    uint64_t end_ticks = SDL_GetPerformanceCounter();
    double duration =
        ((double)(end_ticks - start_ticks)) / SDL_GetPerformanceFrequency();
    double fps = (double)frame_count / duration;
    printf("fps: %.1f\n", fps);

    // end simulation
    mod->final();

    SDL_DestroyTexture(sdl_texture);
    SDL_DestroyRenderer(sdl_renderer);
    SDL_DestroyWindow(sdl_window);
    SDL_Quit();
    return 0;
}
