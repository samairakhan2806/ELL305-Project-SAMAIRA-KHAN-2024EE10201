module shared_adder (
    input  [7:0] a,
    input  [7:0] b,
    input        sub,          // 1 = compute a - b
    output [7:0] sum,
    output [7:0] p,            // propagate = a ^ b'  (b' = b, or ~b when sub)
    output [7:0] g,            // generate  = a & b'
    output       cout,         // carry out of bit 7
    output       overflow      // signed overflow
);
    wire [7:0] bx = b ^ {8{sub}};      // invert b for subtraction
    wire [8:0] c;                      // carry chain

    assign p    = a ^ bx;
    assign g    = a & bx;
    assign c[0] = sub;                 // +1 completes two's complement

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : carry_chain
            assign c[i+1] = g[i] | (p[i] & c[i]);
        end
    endgenerate

    assign sum      = p ^ c[7:0];
    assign cout     = c[8];
    assign overflow = c[8] ^ c[7];     // carry into MSB != carry out of MSB
endmodule

module shared_shifter (
    input  [7:0] a,
    input  [2:0] shamt,
    input        left,         // 1 = SLL (mirror in, mirror out)
    input        arith,        // 1 = SRA (fill with sign bit)
    output [7:0] y
);
    function [7:0] reverse8(input [7:0] x);
        integer k;
        for (k = 0; k < 8; k = k + 1) reverse8[k] = x[7-k];
    endfunction

    wire [7:0] x    = left ? reverse8(a) : a;
    wire       fill = arith & a[7];
    wire [8:0] r    = $signed({fill, x}) >>> shamt;   // 9-bit: fill bit on top

    assign y = left ? reverse8(r[7:0]) : r[7:0];
endmodule

module alu_8bit (
    input      [7:0] a,
    input      [7:0] b,
    input      [3:0] op,
    output reg [7:0] y,
    output           zero,
    output reg       carry,     // ADD: carry out, SUB: borrow, else 0
    output reg       overflow   // ADD/SUB signed overflow, else 0
);
    localparam OP_ADD  = 4'b0000, OP_SLL = 4'b0001, OP_SLT = 4'b0010,
               OP_SLTU = 4'b0011, OP_XOR = 4'b0100, OP_SRL = 4'b0101,
               OP_OR   = 4'b0110, OP_AND = 4'b0111, OP_SUB = 4'b1000,
               OP_SRA  = 4'b1101;

    // SUB, SLT and SLTU all need a - b
    wire sub = (op == OP_SUB) || (op == OP_SLT) || (op == OP_SLTU);

    wire [7:0] sum, p, g, sh;
    wire       cout, v;

    shared_adder u_add (
        .a(a), .b(b), .sub(sub),
        .sum(sum), .p(p), .g(g), .cout(cout), .overflow(v)
    );

    shared_shifter u_shift (
        .a(a), .shamt(b[2:0]),
        .left(op == OP_SLL), .arith(op == OP_SRA),
        .y(sh)
    );

    wire lt_signed   = sum[7] ^ v;     // N xor V
    wire lt_unsigned = ~cout;          // borrow

    always @(*) begin
        y        = 8'h00;
        carry    = 1'b0;
        overflow = 1'b0;
        case (op)
            OP_ADD:  begin y = sum; carry = cout;  overflow = v; end
            OP_SUB:  begin y = sum; carry = ~cout; overflow = v; end
            OP_SLT:  y = {7'b0, lt_signed};
            OP_SLTU: y = {7'b0, lt_unsigned};
            OP_XOR:  y = p;
            OP_AND:  y = g;
            OP_OR:   y = p | g;
            OP_SLL, OP_SRL, OP_SRA: y = sh;
            default: y = 8'h00;
        endcase
    end

    assign zero = (y == 8'h00);
endmodule

module serial_loader (
    input            clk,
    input            sck_pin,
    input            sdi_pin,
    input            cs_n_pin,
    output reg [7:0] a,
    output reg [7:0] b,
    output reg [3:0] op,
    output reg       load_pulse      // one clk high when a new frame arrives
);
    reg [2:0]  sck_s;
    reg [2:0]  cs_s;
    reg [1:0]  sdi_s;
    reg [23:0] shreg;

    always @(posedge clk) begin
        sck_s <= {sck_s[1:0], sck_pin};
        cs_s  <= {cs_s[1:0],  cs_n_pin};
        sdi_s <= {sdi_s[0],   sdi_pin};
        load_pulse <= 1'b0;

        // shift one bit on each SCK rising edge while CS_N is low
        if (!cs_s[1] && (sck_s[2:1] == 2'b01))
            shreg <= {shreg[22:0], sdi_s[1]};

        // CS_N rising edge = end of frame -> load operands
        if (cs_s[2:1] == 2'b01) begin
            op         <= shreg[19:16];
            a          <= shreg[15:8];
            b          <= shreg[7:0];
            load_pulse <= 1'b1;
        end
    end
endmodule

(* top *)
module alu_top (
    (* iopad_external_pin, clkbuf_inhibit *) input clk,    // internal OSC clock
    (* iopad_external_pin *) output       clk_en,          // OSC enable

    // inputs from RP2040 (SPI-style frame)
    (* iopad_external_pin *) input        spi_sck,         // FPGA_IO18
    (* iopad_external_pin *) input        spi_sdi,         // FPGA_IO7  (moved from FPGA_IO17, see README)
    (* iopad_external_pin *) input        spi_cs_n,        // FPGA_IO0

    // outputs to protocol analyzer
    (* iopad_external_pin *) output [7:0] result,          // FPGA_IO8..IO15 (PMOD)
    (* iopad_external_pin *) output [7:0] result_oe,
    (* iopad_external_pin *) output       zero,            // FPGA_IO1
    (* iopad_external_pin *) output       zero_oe,
    (* iopad_external_pin *) output       carry,           // FPGA_IO2
    (* iopad_external_pin *) output       carry_oe,
    (* iopad_external_pin *) output       overflow,        // FPGA_IO16 = on-board LED
    (* iopad_external_pin *) output       overflow_oe
);
    assign clk_en      = 1'b1;
    assign result_oe   = 8'hFF;
    assign zero_oe     = 1'b1;
    assign carry_oe    = 1'b1;
    assign overflow_oe = 1'b1;

    wire [7:0] a, b, y;
    wire [3:0] op;
    wire       load_pulse, z, c, v;

    serial_loader u_rx (
        .clk(clk), .sck_pin(spi_sck), .sdi_pin(spi_sdi), .cs_n_pin(spi_cs_n),
        .a(a), .b(b), .op(op), .load_pulse(load_pulse)
    );

    alu_8bit u_alu (
        .a(a), .b(b), .op(op),
        .y(y), .zero(z), .carry(c), .overflow(v)
    );

    // register the outputs so all 11 lines change on the same clock edge
    // (one clean transition on the analyzer instead of glitches)
    reg [7:0] result_q;
    reg       zero_q, carry_q, overflow_q;
    always @(posedge clk) begin
        result_q   <= y;
        zero_q     <= z;
        carry_q    <= c;
        overflow_q <= v;
    end
    assign result   = result_q;
    assign zero     = zero_q;
    assign carry    = carry_q;
    assign overflow = overflow_q;

endmodule