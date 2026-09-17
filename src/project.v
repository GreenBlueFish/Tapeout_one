/*
 * Copyright (c) 2026 Rowan Leonard
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_counter (
    input  wire clk,
    input  wire rst_n,
    input  wire ena,
    output wire [7:0] uo_out,

    //unused
    input reg [7:0] ui_in,
    input reg [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);
    
    reg [7:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 8'b0;
        end else begin
            counter <= counter + 1;
        end
    end

    assign uo_out = ena ? counter : 8'hz;

    //pointless logic, I want to keep the unused wires
    assign uio_out = 8'hz;
    assign uio_oe[7:1]  = 7'hz;
    wire _unused = &{ui_in, uio_in};
    assign uio_oe[0] = _unused_ok;

endmodule
