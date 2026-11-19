`default_nettype none

// ===========================================================================
//
//    1. golchip_core       wires everything together (hand-off to the VGA side)
//    2. golchip_sequencer  decides WHEN things happen (12-cycle routine)
//    3. golchip_grid       5 x 5 cells, side-neighbour wiring, load chain
//    4. golchip_cell       one cell: shift register + Game of Life rule
//    5. golchip_readmux     picks the cell the monitor is drawing
//
//  (Module order in a Verilog file doesn't matter to the tools.)
// ===========================================================================


// ===========================================================================
// 1. golchip_core : sequencer + grid + read mux
//
//   VGA -> core : vblank_start, row, col
//   core -> VGA : cell_bit   (register it together with hsync/vsync)
// ===========================================================================
module golchip_core (
    input  wire           clk,
    input  wire           rst_n,

    // control pins (ui_in)
    input  wire           run,
    input  wire           load_en,
    input  wire           load_data,
    input  wire           step,
    input  wire [1:0]     speed,
    input  wire           clear,

    // from the VGA side
    input  wire           vblank_start,
    input  wire [2:0]     row,          // 0..4 inside the grid
    input  wire [2:0]     col,          // 0..4 inside the grid

    // to the VGA side / debug pins
    output wire           cell_bit,
    output wire           gen_tick,     // 1-cycle pulse per committed generation
    output wire           busy,

    // whole grid, for tests and debugging
    output wire [24:0]    cells
);

    wire [2:0] ld;
    wire       shift_en, commit;
    wire       chain_out;

    golchip_sequencer u_seq (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear        (clear),
        .vblank_start (vblank_start),
        .run          (run),
        .step         (step),
        .load_en      (load_en),
        .speed        (speed),
        .ld           (ld),
        .shift_en     (shift_en),
        .commit       (commit),
        .busy         (busy)
    );

    golchip_grid u_grid (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (clear),
        .ld        (ld),
        .shift_en  (shift_en),
        .commit    (commit),
        .load_en   (load_en),
        .load_data (load_data),
        .cells     (cells),
        .chain_out (chain_out)
    );

    golchip_readmux u_mux (
        .cells    (cells),
        .row      (row),
        .col      (col),
        .cell_bit (cell_bit)
    );

    assign gen_tick = commit;

    // chain_out is only used by tests; keep the linter quiet
    wire _unused = chain_out;

endmodule


// ===========================================================================
// 2. golchip_sequencer : runs one generation per eligible frame (doc 3.3, 4.4)
//
//   phase 0      idle
//   phase 1..3   exchange steps   (ld[0]..ld[2], relay scheme -- see grid)
//   phase 4..11  compaction       (shift_en, 8 cycles)
//   phase 12     commit
//
//   A generation is 12 cycles and only starts on vblank_start, so the
//   monitor never sees a half-updated grid.
// ===========================================================================
//   Advance model (customised for this project):
//   * A rising edge on `step` schedules a burst of 2^speed generations.
//   * Generations are the ONLY way the grid advances (no free-running mode).
//   * Each generation is a 12-cycle routine started on `vblank_start`, so a
//     commit always lands during vertical blanking and the monitor never
//     sees a half-updated grid. A burst therefore spans 2^speed frames.
//   * `speed` sets how many generations one step computes:
//       speed 0 -> 1, speed 1 -> 2, speed 2 -> 4, speed 3 -> 8.
//   * Raising `load_en` cancels any burst still in progress (and any
//     generation mid-routine), so a freshly loaded grid never advances
//     until the next step.
//   * The step edge detector resets as if `step` were already high, so
//     holding step high through reset does not count as a rising edge.
module golchip_sequencer (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clear,
    input  wire       vblank_start,  // 1-cycle pulse at start of vertical blanking (from VGA)
    input  wire       run,           // reserved / unused (step is the only trigger)
    input  wire       step,          // rising edge = compute 2^speed generations
    input  wire       load_en,       // holds the sequencer idle
    input  wire [1:0] speed,         // generations computed per step (2^speed)
    output wire [2:0] ld,
    output wire       shift_en,
    output wire       commit,
    output wire       busy
);

    localparam [3:0] LAST = 4'd12;

    reg [3:0] phase;
    reg [1:0] step_sync;   // 2-flop synchroniser: step comes from an async pin
    reg       step_prev;
    reg [3:0] gens_left;   // generations still to compute in the current burst

    wire step_rise = step_sync[1] & ~step_prev;

    // How many generations a single step requests: 2^speed (1, 2, 4 or 8).
    reg [3:0] burst_len;
    always @(*) begin
        case (speed)
            2'd0:    burst_len = 4'd1;
            2'd1:    burst_len = 4'd2;
            2'd2:    burst_len = 4'd4;
            default: burst_len = 4'd8;
        endcase
    end

    // Start a generation at vblank when idle, not loading, and work remains.
    wire start = vblank_start && (phase == 4'd0) && !load_en
              && (gens_left != 4'd0);

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            phase     <= 4'd0;
            step_sync <= 2'b11;   // treat step as already high: a level held
            step_prev <= 1'b1;    // through reset is not a rising edge
            gens_left <= 4'd0;
        end else begin
            step_sync <= {step_sync[0], step};
            step_prev <= step_sync[1]; // edge detect / metastability guard

            // A step edge (re)loads the burst counter. Loading cancels any
            // remaining burst, and a step during load is ignored. A step while
            // a burst is still running simply reloads the remaining count to a
            // fresh burst.
            if (load_en)
                gens_left <= 4'd0;
            else if (step_rise)
                gens_left <= burst_len;
            else if (commit && gens_left != 4'd0)
                gens_left <= gens_left - 4'd1;

            // Phase machine: 0 idle, 1..12 one generation routine.
            // Loading aborts a generation that is part-way through.
            if (load_en)
                phase <= 4'd0;
            else if (start)
                phase <= 4'd1;
            else if (phase == LAST)
                phase <= 4'd0;
            else if (phase != 4'd0)
                phase <= phase + 4'd1;
        end
    end

    assign ld[0]    = (phase == 4'd1);
    assign ld[1]    = (phase == 4'd2);
    assign ld[2]    = (phase == 4'd3);
    assign shift_en = (phase >= 4'd4) && (phase <= 4'd11);
    assign commit   = (phase == LAST);
    assign busy     = (phase != 4'd0) || (gens_left != 4'd0);

    // run is reserved for a possible future free-run mode; keep lint quiet.
    wire _unused_run = run;

endmodule


// ===========================================================================
// 3. golchip_grid : 5 x 5 array of cells
//
//   cells[r*5 + c] is the state of the cell at row r, column c.
//   Row 0 is the top of the screen, column 0 the left.
//
//   Relay exchange (no diagonal wires, no tri-states):
//   every cell has ONE output wire, `link`, that goes only to its four side
//   neighbours (N, S, E, W). Diagonal values are passed along by a side
//   neighbour -- e.g. my NW is the N of my W:
//
//     step 1  everyone sends s        -> I hear N, S, E, W
//     step 2  everyone sends its N    -> from W I hear NW, from E I hear NE
//     step 3  everyone sends its S    -> from W I hear SW, from E I hear SE
//
//   Each wire still has exactly one driver; only WHAT it carries changes.
//
//   Dead border: the grid is surrounded by a ring of constant 0s, so edge
//   cells hear 0 from outside the grid (and relayed values are 0 too).
//
//   Load chain (snake order): row 0 left->right, row 1 right->left, ...
//   chain[p] is the input of the cell at chain position p.
//   The first bit shifted in ends up in the last cell of the chain.
// ===========================================================================
module golchip_grid (
    input  wire           clk,
    input  wire           rst_n,
    input  wire           clear,
    input  wire [2:0]     ld,
    input  wire           shift_en,
    input  wire           commit,
    input  wire           load_en,
    input  wire           load_data,
    output wire [24:0]    cells,
    output wire           chain_out   // last cell of the chain (handy for tests)
);

    // 5x5 cells, padded to 7x7 with the dead ring.
    wire [24:0] links;               // each cell's one output wire
    wire [48:0] pad;                 // links with a dead ring around them
    wire [25:0] chain;

    assign chain[0]  = load_data;
    assign chain_out = chain[25];

    genvar r, c;
    generate
        // ---- padded copy of the link wires -------------------------------
        for (r = 0; r < 7; r = r + 1) begin : g_pr
            for (c = 0; c < 7; c = c + 1) begin : g_pc
                if (r == 0 || c == 0 || r == 6 || c == 6) begin : g_border
                    assign pad[r*7 + c] = 1'b0;
                end else begin : g_inner
                    assign pad[r*7 + c] = links[(r-1)*5 + (c-1)];
                end
            end
        end

        // ---- the cells ---------------------------------------------------
        for (r = 0; r < 5; r = r + 1) begin : g_row
            for (c = 0; c < 5; c = c + 1) begin : g_col
                localparam integer IDX = r*5 + c;
                localparam integer POS = r*5 + ((r % 2 == 0) ? c : (4-c));
                localparam integer PR  = r + 1;   // position in the padded grid
                localparam integer PC  = c + 1;

                golchip_cell u_cell (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .clear    (clear),
                    .ld       (ld),
                    .shift_en (shift_en),
                    .commit   (commit),
                    .load_en  (load_en),
                    .chain_in (chain[POS]),
                    .in_n     (pad[(PR-1)*7 + PC    ]),   // from the cell above
                    .in_s     (pad[(PR+1)*7 + PC    ]),   // from the cell below
                    .in_e     (pad[ PR   *7 + PC + 1]),   // from the cell to the right
                    .in_w     (pad[ PR   *7 + PC - 1]),   // from the cell to the left
                    .link     (links[IDX]),
                    .s        (cells[IDX])
                );

                assign chain[POS+1] = cells[IDX];
            end
        end
    endgenerate

endmodule


// ===========================================================================
// 4. golchip_cell : one Game of Life cell
//
//   s      : current state (1 = alive). Only changes on commit or load.
//   sr     : 8-bit compacting shift register holding the neighbour bits.
//            sr[0] is the left-most stage, sr[7] the right-most.
//   link   : this cell's one output wire to its four side neighbours.
//
// Each generation the sequencer drives:
//   ld[0]     step 1: send s.      sr[0..3] <= N, S, E, W
//   ld[1]     step 2: send sr[0].  sr[4], sr[5] <= NW (via W), NE (via E)
//   ld[2]     step 3: send sr[1].  sr[6], sr[7] <= SW (via W), SE (via E)
//   shift_en  8 cycles: every 1 moves right if the stage to its right is empty,
//             so with k live neighbours sr ends as 0..0 1..1 (k ones on the right)
//   commit    s <= next_s
// ===========================================================================
module golchip_cell (
    input  wire       clk,
    input  wire       rst_n,     // active-low reset (from the Tiny Tapeout pin)
    input  wire       clear,     // synchronous clear of s and sr
    input  wire [2:0] ld,        // exchange-step enables
    input  wire       shift_en,  // compaction cycle
    input  wire       commit,    // s <= next_s
    input  wire       load_en,   // load-chain mode: s takes chain_in instead
    input  wire       chain_in,  // s of the previous cell in the load chain
    input  wire       in_n,      // link wire of the cell above
    input  wire       in_s,      // link wire of the cell below
    input  wire       in_e,      // link wire of the cell to the right
    input  wire       in_w,      // link wire of the cell to the left
    output wire       link,      // my one output wire to my side neighbours
    output reg        s          // alive boolean value
);

    reg [7:0] sr;

    // ---- what I send on my link wire --------------------------------------
    //   step 2: the N value I heard in step 1 (sr[0])
    //   step 3: the S value I heard in step 1 (sr[1])
    //   otherwise: my own state
    assign link = ld[1] ? sr[0]
                : ld[2] ? sr[1]
                :         s;

    // ---- compaction (pack the 1s to the right) ----------------------------
    // e pads sr with an empty wall on the left and a full wall on the right:
    //   e[i]   = stage left of sr[i]
    //   e[i+1] = sr[i]
    //   e[i+2] = stage right of sr[i]
    wire [9:0] e = {1'b1, sr, 1'b0};  // 0 sr 1
    wire [7:0] sr_packed;

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_pack
            assign sr_packed[i] = (e[i+1] & e[i+2])    // a 1 that is blocked stays
                                | (e[i]   & ~e[i+1]);  // an empty stage takes the 1 from its left
        end
    endgenerate

    // ---- next state, read straight off the packed register ----------------
    //   sr[6] = count >= 2,  sr[5] = count >= 3,  sr[4] = count >= 4
    wire exactly3 = sr[5] & ~sr[4];
    wire exactly2 = sr[6] & ~sr[5];
    wire next_s   = exactly3 | (s & exactly2);

    // ---- registers --------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n || clear) begin
            s  <= 1'b0;
            sr <= 8'b0;
        end else begin
            if (shift_en) begin
                sr <= sr_packed;
            end else begin
                if (ld[0]) begin                 // step 1: side neighbours
                    sr[0] <= in_n;
                    sr[1] <= in_s;
                    sr[2] <= in_e;
                    sr[3] <= in_w;
                end
                if (ld[1]) begin                 // step 2: relayed N values
                    sr[4] <= in_w;               //   W's N = my NW
                    sr[5] <= in_e;               //   E's N = my NE
                end
                if (ld[2]) begin                 // step 3: relayed S values
                    sr[6] <= in_w;               //   W's S = my SW
                    sr[7] <= in_e;               //   E's S = my SE
                end
            end

            if (load_en)     s <= chain_in;
            else if (commit) s <= next_s;
        end
    end

endmodule


// ===========================================================================
// 5. golchip_readmux : pick the one cell the monitor is drawing
//
//   row / col come from the VGA counters (already offset and sliced).
//   During blanking they can go past 4 (up to 6), so anything outside the
//   5x5 grid reads as dead instead of indexing off the end of `cells`.
//   Purely combinational; register the result before it drives the pins.
// ===========================================================================
module golchip_readmux (
    input  wire [24:0] cells,
    input  wire [2:0]  row,
    input  wire [2:0]  col,
    output wire        cell_bit
);

    wire in_grid = (row < 3'd5) && (col < 3'd5);
    wire [5:0] idx = row*3'd5 + col;   // up to 6*5+6 = 36 fits in 6 bits

    assign cell_bit = in_grid & cells[idx];

endmodule

`default_nettype wire
