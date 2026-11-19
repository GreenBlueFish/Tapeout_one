# Code Walkthrough

Module-by-module description of `src/`. Excerpts are from the source;
`...` marks omitted lines.

Related: [architecture.md](architecture.md), [functionality.md](functionality.md).

## 0. Hierarchy

```
tt_um_vga_interface          src/project.v
├── vga_timing   u_timing    src/vga_timing.v
└── golchip_core u_core      src/golchip.v   #(N=4, W=2)
    ├── golchip_sequencer u_seq
    ├── golchip_grid      u_grid
    │   └── golchip_cell  g_row[r].g_col[c].u_cell   (x16)
    └── golchip_readmux   u_mux
```

All files set `default_nettype none`. One clock domain; all state is reset
synchronously.

## 1. `tt_um_vga_interface` (`project.v`)

### Pin decode

```verilog
wire       reset     = ~rst_n;     // active-high for vga_timing
wire       step      = ui_in[7];
wire       run       = ui_in[6];   // reserved
wire       load_en   = ui_in[5];
wire       load_data = ui_in[4];
wire [1:0] speed     = ui_in[1:0];
```

### Beam → cell

```verilog
localparam CELL_W = HDISP / N;   // 160 (10 under SIM_FAST_FRAME)
localparam CELL_H = VDISP / N;   // 120 (5)
wire [W-1:0] col = hpos / CELL_W;
wire [W-1:0] row = vpos / CELL_H;
```

Constant-divisor division. Results overflow to 0 outside the active area;
masked by `display_on` in the renderer. `SIM_FAST_FRAME` selects HDISP/VDISP
= 40/20 and SEPW = 1.

### Core instance

```verilog
golchip_core #(.N(N), .W(W)) u_core (
    .clk(clk), .rst_n(rst_n), .run(run), .load_en(load_en),
    .load_data(load_data), .step(step), .speed(speed),
    .clear(1'b0), .vblank_start(vblank_start), .row(row), .col(col),
    .cell_bit(cell_bit), .gen_tick(gen_tick), .busy(busy), .cells(cells));
```

`clear` tied off; `gen_tick`, `busy`, `cells[15:1]` consumed only by the
`_unused` lint sink.

### Renderer

```verilog
wire on_grid_line = ((hpos % CELL_W) < SEPW) | ((vpos % CELL_H) < SEPW);
always @(*) begin
    if (!display_on)       {r, g, b} = 6'b00_00_00;
    else if (on_grid_line) {r, g, b} = 6'b01_01_01;
    else if (cell_bit)     {r, g, b} = 6'b11_11_11;
    else                   {r, g, b} = 6'b00_00_01;
end
```

### Output register

```verilog
always @(posedge clk)
    if (reset) uo_reg <= 8'b0;
    else       uo_reg <= {hsync, b[0], g[0], r[0], vsync, b[1], g[1], r[1]};
assign uo_out  = uo_reg;
assign uio_out = 8'b0;
assign uio_oe  = 8'b0;
```

Syncs pass through the same register as colour, so both see one cycle of
latency.

## 2. `vga_timing` (`vga_timing.v`)

Parameters: H 640/16/96/48, V 480/10/2/33 (fast: H 40/2/4/2, V 20/1/2/1).
Derived: `H_SYNC_START=656`, `H_SYNC_END=751`, `H_MAX=799`,
`V_SYNC_START=490`, `V_SYNC_END=491`, `V_MAX=524`.

```verilog
always @(posedge clk)
    if (reset)              hpos <= 0;
    else if (hpos >= H_MAX) hpos <= 0;
    else                    hpos <= hpos + 1;

always @(posedge clk)
    if (reset) vpos <= 0;
    else if (hpos >= H_MAX) vpos <= (vpos >= V_MAX) ? 0 : vpos + 1;

assign display_on   = (hpos < H_DISPLAY) && (vpos < V_DISPLAY);
assign hsync        = ~((hpos >= H_SYNC_START) && (hpos <= H_SYNC_END));
assign vsync        = ~((vpos >= V_SYNC_START) && (vpos <= V_SYNC_END));
assign vblank_start = (vpos == V_DISPLAY) && (hpos == 0);
```

(`vpos` logic condensed from the nested `if` in the source.) Syncs and
`display_on` are combinational; registered in the top level.

## 3. `golchip_core`

Structural only.

```verilog
wire [2:0] ld;
wire       shift_en, commit;
golchip_sequencer u_seq (... .ld(ld), .shift_en(shift_en), .commit(commit), .busy(busy));
golchip_grid #(.N(N)) u_grid (... .ld(ld), .shift_en(shift_en), .commit(commit),
                              .load_en(load_en), .load_data(load_data), .cells(cells), ...);
golchip_readmux #(.N(N), .W(W)) u_mux (.cells(cells), .row(row), .col(col), .cell_bit(cell_bit));
assign gen_tick = commit;
```

`chain_out` from the grid is test-only and sunk to `_unused`.

## 4. `golchip_sequencer`

State: `phase[3:0]`, `step_sync[1:0]`, `step_prev`, `gens_left[3:0]`.

```verilog
wire step_rise = step_sync[1] & ~step_prev;

always @(*) case (speed)
    2'd0: burst_len = 1;  2'd1: burst_len = 2;
    2'd2: burst_len = 4;  default: burst_len = 8;
endcase

wire start = vblank_start && (phase == 0) && !load_en && (gens_left != 0);

always @(posedge clk)
    if (!rst_n || clear) begin
        phase <= 0; step_sync <= 0; step_prev <= 0; gens_left <= 0;
    end else begin
        step_sync <= {step_sync[0], step};
        step_prev <= step_sync[1];

        if (step_rise && !load_en)          gens_left <= burst_len;
        else if (commit && gens_left != 0)  gens_left <= gens_left - 1;

        if (start)               phase <= 1;
        else if (phase == LAST)  phase <= 0;      // LAST = 12
        else if (phase != 0)     phase <= phase + 1;
    end

assign ld[0]    = (phase == 1);
assign ld[1]    = (phase == 2);
assign ld[2]    = (phase == 3);
assign shift_en = (phase >= 4) && (phase <= 11);
assign commit   = (phase == LAST);
assign busy     = (phase != 0) || (gens_left != 0);
```

Notes:

- `step_rise` has priority over the decrement, so a new edge in the same
  cycle as a `commit` reloads rather than decrements.
- `gens_left` is checked only at `start`; a burst runs one generation per
  `vblank_start`.
- `run` is an input with no fan-out (`_unused_run`).

## 5. `golchip_grid`

```verilog
localparam P = N + 2;
wire [N*N-1:0] links;
wire [P*P-1:0] pad;
wire [N*N:0]   chain;
assign chain[0]  = load_data;
assign chain_out = chain[N*N];

// pad: 0 on the ring, links[(r-1)*N + (c-1)] inside
for (r = 0; r < P; r++) for (c = 0; c < P; c++)
    assign pad[r*P + c] = (r == 0 || c == 0 || r == P-1 || c == P-1)
                          ? 1'b0 : links[(r-1)*N + (c-1)];
```

(Condensed: the source uses named `if/else` generate blocks `g_border` /
`g_inner`.)

```verilog
for (r = 0; r < N; r++) for (c = 0; c < N; c++) begin : g_row / g_col
    localparam integer IDX = r*N + c;
    localparam integer POS = r*N + ((r % 2 == 0) ? c : (N-1-c));
    localparam integer PR = r + 1, PC = c + 1;
    golchip_cell u_cell (
        .ld(ld), .shift_en(shift_en), .commit(commit), .load_en(load_en),
        .chain_in(chain[POS]),
        .in_n(pad[(PR-1)*P + PC]),   .in_s(pad[(PR+1)*P + PC]),
        .in_e(pad[PR*P + PC + 1]),   .in_w(pad[PR*P + PC - 1]),
        .link(links[IDX]), .s(cells[IDX]), ...);
    assign chain[POS+1] = cells[IDX];
end
```

- `cells[IDX]`, `IDX = r*N + c`, row 0 = top of screen.
- `POS` is the chain position (snake order). The first bit shifted in ends
  at POS 15 (cell 12) after 16 clocks.
- Each `link` net fans out to ≤ 4 cells via `pad`.

## 6. `golchip_cell`

Ports: `ld[2:0]`, `shift_en`, `commit`, `load_en`, `chain_in`,
`in_n/s/e/w`, outputs `link`, `s`. Internal `sr[7:0]`.

```verilog
assign link = ld[1] ? sr[0] : ld[2] ? sr[1] : s;

wire [9:0] e = {1'b1, sr, 1'b0};
assign sr_packed[i] = (e[i+1] & e[i+2]) | (e[i] & ~e[i+1]);   // i = 0..7

wire exactly3 = sr[5] & ~sr[4];
wire exactly2 = sr[6] & ~sr[5];
wire next_s   = exactly3 | (s & exactly2);

always @(posedge clk)
    if (!rst_n || clear) begin s <= 0; sr <= 0; end
    else begin
        if (shift_en) sr <= sr_packed;
        else begin
            if (ld[0]) begin sr[0] <= in_n; sr[1] <= in_s; sr[2] <= in_e; sr[3] <= in_w; end
            if (ld[1]) begin sr[4] <= in_w; sr[5] <= in_e; end
            if (ld[2]) begin sr[6] <= in_w; sr[7] <= in_e; end
        end
        if (load_en)     s <= chain_in;
        else if (commit) s <= next_s;
    end
```

Notes:

- `link` is a 3:1 mux; `ld[1]`/`ld[2]` are one-hot with `ld[0]` by
  construction of the sequencer.
- In phase 2, a neighbour's `link` carries that neighbour's `sr[0]` (its N),
  so `in_w` = NW and `in_e` = NE. Phase 3 likewise with `sr[1]` (S).
- `shift_en` takes priority over the `ld` loads; they never overlap.
- `load_en` takes priority over `commit` for `s`; the sequencer cannot start
  while loading, so they do not overlap in practice.
- `sr` is not cleared between generations; phases 1–3 overwrite all 8 bits.

## 7. `golchip_readmux`

```verilog
assign cell_bit = cells[row*N + col];
```

Combinational; registered downstream in `uo_reg`.

## 8. One `step` (speed = 0), cycle level

| Cycle | Event |
|---|---|
| t, t+1 | `step` through `step_sync` |
| t+2 | `step_rise`; `gens_left <= 1` |
| next `vblank_start` | `start`; `phase <= 1` |
| phase 1–3 | `ld[0..2]`; all `sr` filled |
| phase 4–11 | `shift_en`; `sr <= sr_packed` |
| phase 12 | `commit`; `s <= next_s` in all cells; `gens_left <= 0`; `phase <= 0` |
| next frame | new generation rendered |

## 9. Test sources

| File | Content |
|---|---|
| `test/tb.v` | TT harness; instantiates `tt_um_vga_interface`, adds `VPWR`/`VGND` under `GL_TEST` |
| `test/test.py` | 21 cocotb tests with a Python B3/S23 model; `GUI_FAST_FRAME` selects fast-frame timing |
| `test/tb_selfcheck.v` | Standalone Icarus timing check |
| `test/Makefile` | `PROJECT_SOURCES = project.v vga_timing.v golchip.v`; GL uses `gf180mcu_fd_sc_mcu7t5v0` |
