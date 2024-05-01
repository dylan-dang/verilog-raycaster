#include <SDL.h>
#include <stdio.h>

#include <fstream>
#include <iostream>

Uint32 getPixel(SDL_Surface *surface, Sint16 x, Sint16 y) {
    if (x >= 0 && y >= 0 && x < surface->w && y < surface->h) {
        int bpp = surface->format->BytesPerPixel;
        Uint8 *pixel = (Uint8 *)surface->pixels + y * surface->pitch + x * bpp;
        switch (bpp) {
            case 1:
                return *pixel;
            case 2:
                return *(Uint16 *)pixel;
            case 3:
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
                return pixel[0] << 16 | pixel[1] << 8 | pixel[2];
#else
                return pixel[0] | pixel[1] << 8 | pixel[2] << 16;
#endif
            case 4:
                return *(Uint32 *)pixel;
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        std::cerr << "too little args!\n";
        return 1;
    }
    SDL_Surface *img = SDL_LoadBMP(argv[1]);
    if (img == NULL) {
        std::cerr << "could not read bmp!\n";
        return 1;
    }
    std::ofstream output(argv[2],
                         std::ios::binary | std::ios::out | std::ios::trunc);
    if (!output) {
        std::cerr << "output file could not be created\n";
        return 1;
    }
    for (Sint16 y = 0; y < img->h; y++) {
        for (Sint16 x = 0; x < img->w; x++) {
            Uint32 pixel = getPixel(img, x, y);
            Uint8 r, b, g;
            SDL_GetRGB(pixel, img->format, &r, &g, &b);
            output.write(reinterpret_cast<char *>(&r), sizeof(Uint8));
            output.write(reinterpret_cast<char *>(&g), sizeof(Uint8));
            output.write(reinterpret_cast<char *>(&b), sizeof(Uint8));
        }
    }
    output.close();
}
