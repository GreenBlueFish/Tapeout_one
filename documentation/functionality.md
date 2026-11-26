# Functionality

External behaviour, operating procedure and verification status.

Related: [architecture.md](architecture.md), [code_walkthrough.md](code_walkthrough.md).

## 1. Pinout

| Pin | Signal | Behaviour |
|---|---|---|
| `ui_in[1:0]` | `speed` | Burst length 2^speed (1, 2, 4, 8) |
| `ui_in[3:2]` | — | unused |
| `ui_in[4]` | `load_data` | Serial data, sampled every clock while `load_en=1` |
| `ui_in[5]` | `load_en` | Shift mode; blocks generation start and `step` |
| `ui_in[6]` | `run` | reserved |
| `ui_in[7]` | `step` | Async; rising edge arms a burst |
| `uo_out[7:0]` | TinyVGA | `{HSync, B0, G0, R0, VSync, B1, G1, R1}` (bit 7→0), registered |
| `uio[7:0]` | — | `uio_out=0`, `uio_oe=0` |
| `clk` | | 25.175 MHz |
| `rst_n` | | Sync, active low; clears grid and sequencer |

## 2. Loading

Hold `load_en=1` for 16 clocks, one bit per clock on `load_data`, then
deassert. Cell index = `row*4 + col` (row 0 top). Transmit order:

```
12, 13, 14, 15, 11, 10, 9, 8, 4, 5, 6, 7, 3, 2, 1, 0
```

The display shows the chain shifting during load.

## 3. Stepping

- `step` rising edge (after 2-FF sync) sets `gens_left = 2**speed`.
- One generation is computed per frame, starting at `vblank_start`, until
  `gens_left = 0`. Burst of 8 ≈ 133 ms.
- Edge during an active burst reloads `gens_left` (does not add).
- Level-insensitive: holding `step` high has no further effect.
- Edges while `load_en=1` are ignored.

Example: load cells {1, 5, 9}, `speed=0`, step → {4, 5, 6}; step → {1, 5, 9}.

## 4. Display

640×480 @ 60 Hz, negative syncs. Full-screen 4×4, 160×120 px per cell,
4 px separators on the top/left of each cell.

| Region | RRGGBB |
|---|---|
| Blanking | 00 00 00 |
| Separator | 01 01 01 |
| Live | 11 11 11 |
| Dead | 00 00 01 |

Grid updates only during vertical blanking; no partial generations are
displayed.

## 5. Board setup

- TinyVGA Pmod on the output header.
- Project clock 25.175 MHz.
- Inputs from the RP2040 or DIP switches/button. `step` bounce only re-arms
  the burst.

## 6. Verification

cocotb 2.0.1 + Icarus Verilog, Python reference model.

| Suite | Scope | Result |
|---|---|---|
| `test_cell.py` (2) | `golchip_cell`: all 512 (`s`, neighbour) cases through the 3 relay phases, random data on ignored inputs, `link` per phase, ≤7-cycle compaction, `next_s`; clear/hold | pass |
| `test/test.py` (21), `SIM_FAST_FRAME` | system | 21/21, ~10 s |
| `test/test.py` (21), full frame | system | 21/21, ~27 min |
| Gate level | `test_ports_only_step` on GF180 netlist | via GDS action; not yet reviewed |

`test/test.py` coverage: reset; serial load (full and per cell); load blocks
step and generation; single generation; burst lengths for speed 1–3; edge
triggering; reload during burst; reset mid-burst; random patterns vs model;
dead-border cases; commit only in vblank; H/V periods and sync widths;
black blanking; per-cell rendering; ports-only (GL-safe) test.

```sh
cd test
GUI_FAST_FRAME=1 make -B COMPILE_ARGS+=-DSIM_FAST_FRAME
make -B
```

## 7. Limitations

- Dead border; no toroidal wrap.
- No free-run mode (`run` reserved).
- `busy`/`gen_tick` not observable at the pins.
