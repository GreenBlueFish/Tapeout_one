# Functionality and Usage

What the chip does, how to drive it, and how it was verified.

See also: [architecture.md](architecture.md) and
[code_walkthrough.md](code_walkthrough.md).

---

## 1. What it does

Conway's Game of Life is a grid of cells that are each alive or dead. Every
generation, each cell counts its eight neighbours:

| Live neighbours | Cell is alive now | Cell is dead now |
|---|---|---|
| 0 or 1 | dies | stays dead |
| 2 | survives | stays dead |
| 3 | survives | **born** |
| 4 to 8 | dies | stays dead |

This chip gives each of the 16 cells its own circuit, so all cells compute
their next state at once, with no processor and no shared memory. The current
generation is shown full-screen on a VGA monitor as a 4×4 board of white
(alive) and dark blue (dead) squares separated by grey lines. A host loads the
starting pattern and tells the chip when to advance.

Each generation takes 12 clock cycles (under half a microsecond):

1. **Exchange (3 cycles):** every cell learns its eight neighbours over four
   side wires, relaying the diagonals.
2. **Count (8 cycles):** the neighbour bits are packed to one side of a shift
   register, so the count can be read from two bits with no adder.
3. **Commit (1 cycle):** all 16 cells update together.

Generations only start at the beginning of vertical blanking, so the screen
never shows a half-finished update.

---

## 2. Pins

| Pin | Signal | Use |
|---|---|---|
| `ui_in[1:0]` | `speed` | Generations per step press: 1, 2, 4 or 8 (2^speed) |
| `ui_in[3:2]` | — | unused |
| `ui_in[4]` | `load_data` | Pattern bit, read every clock while `load_en` is high |
| `ui_in[5]` | `load_en` | High to shift a pattern in; pauses the simulation |
| `ui_in[6]` | `run` | Reserved, not used |
| `ui_in[7]` | `step` | Rising edge starts a burst of generations |
| `uo_out[7:0]` | TinyVGA | R1, G1, B1, VSync, R0, G0, B0, HSync (bit 0 → 7) |
| `uio[7:0]` | — | unused (all inputs) |
| `clk` | 25.175 MHz | VGA pixel clock |
| `rst_n` | reset | Active low; clears the grid and sequencer |

---

## 3. Using the chip

### Loading a pattern

1. Hold `load_en` high.
2. Present one bit per clock on `load_data` for 16 clocks (1 = alive).
3. Drop `load_en`.

Cells are numbered `row*4 + column` from the top left. The chain snakes
through the rows, so send the cells in this order:

```
12, 13, 14, 15,  11, 10, 9, 8,  4, 5, 6, 7,  3, 2, 1, 0
```

The display shows the pattern shifting in; nothing is computed while
`load_en` is high.

### Running

- Set `speed`, then give `step` a rising edge. The chip runs 2^`speed`
  generations, one per frame (60 per second), then holds.
- Holding `step` high does nothing more. A new press during a burst restarts
  the count rather than adding to it.
- Pulse `rst_n` low to clear the grid.

### Example: blinker

Load cells 1, 5 and 9 alive (a vertical line in column 1), set `speed = 0`,
and press `step`: the line turns horizontal (cells 4, 5, 6). Press again and
it turns back.

### External hardware

- TinyVGA Pmod on the output header and a monitor that accepts
  640×480 @ 60 Hz.
- 25.175 MHz project clock, set from the demo board.
- Something to drive the inputs: the RP2040 on the demo board, or switches and
  a button. A debounced `step` gives the cleanest behaviour (bounce is
  harmless, since each edge reloads the burst rather than adding).

---

## 4. Verification

Simulated with cocotb and Icarus Verilog against a Python model of the Game of
Life.

| Tests | Result |
|---|---|
| Cell unit tests (2): all 512 combinations of state and neighbours through the three exchange steps | pass |
| System tests (21, `test/test.py`), reduced frame (`SIM_FAST_FRAME`) | 21/21 pass (~10 s) |
| System tests (21), full 640×480 frame | 21/21 pass (~27 min) |
| Gate level | runs in the Tiny Tapeout GitHub Actions flow; results to be reviewed |

The system tests cover reset, serial load (whole grid and one cell at a time),
step edge-triggering, burst lengths for every `speed`, reloading during a
burst, reset mid-burst, random patterns against the model, dead-border cases,
commits only in vertical blanking, sync periods and pulse widths, black
blanking, and the picture drawn for each cell.

### Running the tests

```sh
cd test
GUI_FAST_FRAME=1 make -B COMPILE_ARGS+=-DSIM_FAST_FRAME   # fast, seconds
make -B                                                    # full frame, ~30 min
```

---

## 5. Limitations

- 4×4 is enough for blocks and blinkers, but too small for gliders to travel.
- Cells outside the grid count as dead, so patterns at the edge die or settle.
- No free-running mode yet; the grid only advances on `step`. The `run` pin is
  reserved for it.
