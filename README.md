# Raycaster

Raycasting engine created in System Verilog. Submitted as the final project for
CS350C at UT Austin by Dylan Dang.

## Dependencies

To build this project you will need:

1. C++ toolchain
2. verilator
3. SDL2

This project was tested in Ubuntu 22.04, however it should work on other
platforms.

To install the dependencies on Debian-based distros, you may run:

```shell
sudo apt install build-essential verilator libsdl2-dev
```

## Building and Running

To build the project, you can run:

```shell
make build
```

This should output the compiled binary to `obj_dir/raycaster`. From there, you
may execute it directly or use the make command:

```shell
make run
```

To clean, build, and run in one step, you may use:

```shell
make start
```

### Overview

This raycaster module outputs a 3d projection of level on a 640x480 screen
by casting rays from a player point to to determine intersections with a grid
of cells. This algorithm is ran the blanking interval, and outputs colored
pixels every clock cycle while data enable pin is high. It takes in the
movement key inputs to update the internal player and rerender the scene.
It supports textures and custom maps.

### Optimizations and Overcoming Hardware Limitations

Writing this raycaster taught me a lot about verilog and how utilize several
techniques to creaate a impressive pseudo 3d world. Furthermore, I employed
various strategies in order to optimize hardware synthesis some of which will
be listed below.

### Fixed point representation

Unlike software-oriented languages, Verilog does not come with floating point
arithmetic, at least not for synthesis; rather, Verilog only comes equipped with
integer operations. In order to do floating point operations, you would need to
create your own floating point unit. However, doing so is complex and slow.
This makes it tricky to perform accurate mathematics in order to project the
world onto the scene. To get around this limitation, I utlilized a simple trick:
fixed point representation.

Fixed point representation is a simple yet powerful way to represent fractional
values with the use of fast integer arithmetic circuits. It comes by treating a
portion of the binary digit as fractional, however such distinction only exists
in the programmers' mind. In order to keep track of which registers hold fixed
point numbers, I defined a 32-bit type `fix_t` to follow a Q16.16 format. All
operations remain the same except multiplication since it outputs in Q32.32 so
it must be shifted right 16 bits, handled by the `mult` function.

### Avoiding division

In hardware, division by an arbitrary amount is slow. To remedy this, this
raycaster uses _no_ divisions, only multiplication and addition. You may be
thinking, "but divisions are necessary to perform the calculations needed for
raycasting." However, there are a few more tricks to get around this.

1. Using bitshifts when dividing by a power of 2.

ALthough this helps with some of the divisions, this does not work for all
cases, so we must use another tactic.

2. Multiplying by the reciprocal

Since we are using fixed point representation, we can actually multiply by the
reciprocal and still get the same result! The problem now is actually getting
the reciprocal. If the divisor is constant, such as those from the settings, we
can simply get the reciprocal at _compile time_. Using the function `to_fix`, I
am able to convert compile time only `real` values to fixed point reciprocals.
However, the problem still remains for getting inverse of square root and trig
functions necessary for calculating angles and mapping world space to screen
space. To perform these calculation, I have one final trick up my sleeve.

3. Look up tables

This is the last resort when needing to multiply a number by dynamic divisor.
However, this only occurs with trigonometry functions or the inverse square
root. Which will be explained in the two sections.

### Calculating trigonometry functions

Working with angles inherantly requires us to use trignometry, but how do
compute them? The answer is we don't! To compute the sine of an angle, I simply
take evenly spaced samples of $\sin$ from $0$ to $\pi \over 2$ to create a
lookup table (LUT) at compile time. We can exploit the symmetry of sine to store
only a fourth of values necessary for an entire circle. Then cosine can be
derived by $ \cos x = \sin (x + {\pi \over 2}) $.

This is all fine and dandy for sine and cosine, but
$ \tan x = {\sin x \over \cos x} $ and as stated before, we do _not_ want to
perform division. Therefore, we must store a second lookup table for
$ 1 \over \cos x $, also known as $ \sec x $ and we turn our division problem
into multiplication. With these two tables it is enought to derive all 6
trigonometric functions using trigonometric identities.

### Calculating ray distance

To get the height of a line on the screen. We need the inverse of the ray
distance. That is:

$$
h_{line} = {s_{z}h_{screen}{\sec {(\theta_{player} - \theta_{ray})}} \over
\sqrt {(x_{player} - x_{ray}) ^ 2 + (y_{player} - y_{ray}) ^ 2}}
$$

Everything is fine, except for the pesky sqrt and division. Killing two birds
one stone, we reduce our problem to finding $ 1 \over \sqrt x $. However,
a relatively precise lookup table for $ 2 ^{32} $ possible values is far too
much. There is no repitiion such as in the trigonometry function in which we
can exploit. This is where our old friend Newton's method comes into play.

Using Newton's method we can get a sucessively better approximations using
fixed number of iterations to finding root of a function with an good initial
guess. Applying Newton's method to $ x - {1 \over y^2} = 0 $, We have

$$
    y_{n + 1} =  y_n ({3 \over 2} - {x \over 2} y_n ^2 )
$$

So now, $ 3 \over 2 $ can be stored as a constant and $ x \over 2 $ can be
calculated with a bit shift. With this, we are back to multiplication and
addition! This equation is well known for its use in Quake III Arena. However,
we don't have the luxury of exploiting the structure of floating point numbers
to get a good initial guess. So instead, we perform an expontential samples and
store them in another LUT for our initial guesses. Furthermore, we can also
simply get distance by just multiplying since $ {x \over \sqrt x} = \sqrt x $.

Last problem is that our square distance, $ x $, overflows our Q16.16 input. So,
before putting it in `inv_sqrt` we divide it by $ 2^{16} $ through a bit shift
and then we can restore it by dividing again it by $ \sqrt {2 ^ {16}} = 2^8 $.
And there we have it.

## Customization

Near the top of `raycaster.sv` many macros exist in order to customize the
compiled program. "boolean" types are true when the desired setting is merely
defined. Some things, like textures and cell types, may only be customized by
editing the code directly.

### Level

Levels are stored under the `levels` folder. They consist of white space
seperated hex values pertaining the the type of cell it an index is. Type 0 is
air and the rest may be viewed and edited in the `cell_t` enum.

| setting     | type    | usage                                                     |
| ----------- | ------- | --------------------------------------------------------- |
| LEVEL       | string  | path to level file to load                                |
| MAP_X       | integer | number of cells in the world x direction (level width)    |
| MAP_Y       | integer | number of cells in the world y direction (level height)   |
| MAP_SCALE_X | real    | units a cell takes in the world x direction               |
| MAP_SCALE_Y | real    | units a cell takes in the world y direction               |
| MAP_SCALE_Z | real    | units a cell takes in the world z direction (wall height) |
| MAP_WRAP    | boolean | whether to repeat map cells when exiting map bounds       |

### Textures

Textures are stored as bitmaps under the `textures/` folder and are mapped to
the `textures` array through `load_bmp` ran at compile time. A known limitation
is that `TEX_X` and `TEX_Y` must be divisible by 4 since bitmap specifications
require rows be 4 byte aligned.

| settings | type    | usage                            |
| -------- | ------- | -------------------------------- |
| TEX_X    | integer | width in pixels of all textures  |
| TEX_Y    | integer | height in pixels of all textures |

### Player

| setting           | type | usage                                       |
| ----------------- | ---- | ------------------------------------------- |
| PLAYER_SPEED      | real | units the player should move in one frame   |
| PLAYER_TURN_SPEED | real | radians the player should turn in one frame |
| PLAYER_INIT_X     | real | world x position in units player starts     |
| PLAYER_INIT_Y     | real | world y position in units player starts     |
| PLAYER_INIT_ANGLE | real | direction in radians player begins facing   |

### Rendering

| setting | type | usage                    |
| ------- | ---- | ------------------------ |
| FOV     | real | field of view in radians |

### Math

| setting      | type    | usage                                                 |
| ------------ | ------- | ----------------------------------------------------- |
| TRIG_SAMPLES | integer | number of samples sine and secant LUTs should contain |

### Map Overlay

Map screen dimensions are equal to the
(overlay scale)\*(map dimension)\*(map scale) within each direction.

| setting             | type    | usage                                                 |
| ------------------- | ------- | ----------------------------------------------------- |
| MAP_OVERLAY         | boolean | whether to draw map overlay                           |
| OVERLAY_SCALE_X     | real    | scale of map overlay in screen x direction            |
| OVERLAY_SCALE_Y     | real    | scale of map overlay in screen y direction            |
| OVERLAY_OFFSET_X    | real    | pixel offset of map overlay in the screen x direction |
| OVERLAY_OFFSET_Y    | real    | pixel offset of map overlay in the screen y direction |
| OVERLAY_PLAYER_SIZE | real    | width and height of player indicicator in map overlay |

# Attributions

Collection of links I found helpful while creating this:

-   [3DSage raycaster series](https://youtu.be/gYRrGTC7GtA?si=6N2Tv2YT5pbi7ixZ)
-   [Wikipedia BMP file format](https://en.wikipedia.org/wiki/BMP_file_format)
-   [Project F Beginning FPGA Graphics](https://projectf.io/posts/fpga-graphics/)
-   [Project F Fixed Point Numbers](https://projectf.io/posts/fixed-point-numbers-in-verilog/)
-   [Efficient approximate square roots and division in Verilog](https://www.shironekolabs.com/posts/efficient-approximate-square-roots-and-division-in-verilog/)
-   [Stackoverflow Inverse sqrt for fixed point](https://stackoverflow.com/questions/6286450/inverse-sqrt-for-fixed-point)
