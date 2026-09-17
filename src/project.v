/*
 * Copyright (c) 2026 Rowan Leonard
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_counter (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    // Tiny Tapeout pin mapping:
    // ui_in[0]   = synchronous load enable
    // ui_in[1]   = output enable for the bidirectional 8-bit bus
    // uio[7:0]   = data input while oe=0; counter output while oe=1
    // uo_out     = counter value (always visible for debugging/testing)
    // rst_n      = active-low asynchronous reset

    wire load = ui_in[0];
    wire oe   = ui_in[1];

    counter counter_inst (
        .clk (clk),
        .rst_n (rst_n),
        .load (load),
        .in (uio_in),
        .bus (uo_out)
    );
    assign uio_out = uo_out;
    assign uio_oe  = {8{oe}};

    wire _unused = &{ena, ui_in[7:2], 1'b0};
endmodule

module counter (
    input  wire clk,
    input  wire rst_n,
    input  wire load,
    input  wire [7:0] in,
    output wire [7:0] bus
);

    reg [7:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 8'b0;
        end else if (load == 1'b1) begin
            counter <= in;
        end else begin
            counter <= counter + 1;
        end
    end
    assign bus = counter;

endmodule
