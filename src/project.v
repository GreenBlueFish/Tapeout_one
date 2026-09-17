/*
 * Copyright (c) 2026 Rowan Leonard
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module project (
    input  wire clk,
    input  wire rst_n,
    input  wire enable,
    input  wire [7:0] load,
    output wire [7:0] bus
);

    reg [7:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 8'b0;
        end else begin
            counter <= counter + 1;
        end
    end

    assign bus = enable ? counter : 8'hz;

endmodule
