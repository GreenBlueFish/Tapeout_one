# Tests

This directory contains a [cocotb](https://docs.cocotb.org/) testbench that
verifies the VGA timing and the Game-of-Life control interface of
`tt_um_vga_interface`.

## What is tested

VGA timing (always running, independent of the simulation):

- `test_reset` - leaves reset with resolvable (non-X) outputs, a cleared grid,
  and the unused bidirectional pins tied off as inputs.
- `test_hsync_period` - one horizontal line is exactly 800 pixel clocks.
- `test_vsync_period` - one full frame is exactly 525 x 800 clocks.

Control interface (serial load + step/speed):

- `test_serial_load` - a 16-bit pattern shifted in through `load_en`/`load_data`
  lands in the grid correctly (snake order).
- `test_load_holds_without_step` - the grid does not advance across vblanks
  while no step occurs.
- `test_step_one_generation` - `speed=0`: one `step` rising edge advances
  exactly one generation; a blinker flips orientation (checked against a
  Python Conway reference).
- `test_speed_multiple_generations` - `speed=1` computes 2 generations per
  step, `speed=2` computes 4.
- `test_display_reflects_grid` - a loaded live cell is drawn (non-black) on the
  screen, and the grid is unchanged while displaying.

## Runtime

Generations are committed during vertical blanking, so each `step`/`speed`
test simulates several full 640x480 frames (420,000 clocks per frame). The
full suite takes a few minutes under Icarus Verilog - this is expected, not a
hang.

## Running (Linux / macOS)

```shell
pip install -r requirements.txt
make -B
```

To view waveforms afterwards:

```shell
gtkwave tb.vcd
```

## Quick timing check without cocotb

`tb_selfcheck.v` verifies the VGA timing with Icarus Verilog alone:

```shell
iverilog -g2012 -o tb_selfcheck.vvp -s tb_selfcheck \
    tb_selfcheck.v ../src/project.v ../src/vga_timing.v ../src/golchip.v
vvp tb_selfcheck.vvp
```

## Gate-level simulation

After the GDS GitHub Action has produced `gate_level_netlist.v`, copy it here
and run:

```shell
make -B GATES=yes
```
