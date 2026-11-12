# Regular vs Resource-Shared 8-bit RISC-V ALU on the Shrike-Lite FPGA

ELL305 project by **Samaira Khan (2024EE10201)**

An 8-bit arithmetic logic unit implementing the ten integer operations of the RISC-V RV32I base instruction set, built in two versions and compared on real hardware:

- **Regular ALU** (`main.v`): one module per operation, with a multiplexer selecting the result.
- **Resource-shared ALU** (`main_shared.v`): all ten operations from **one adder and one shifter**, using **26 fewer LUTs (16.8%)** than the regular design.

The design runs on the **Vicharak Shrike-Lite** board (Renesas ForgeFPGA SLG47910V + RP2040). The operands are entered on slide switches, sent to the FPGA as a serial frame, and the result is verified on a **Digilent Analog Discovery 3** protocol analyzer.

## Operations

The 4-bit opcode is built the way a RISC-V decoder builds it: `{funct7[5], funct3}`.

| Operation | Opcode | Function |
|---|---|---|
| ADD | 0000 | A + B |
| SUB | 1000 | A − B |
| AND | 0111 | A & B |
| OR | 0110 | A \| B |
| XOR | 0100 | A ^ B |
| SLL | 0001 | A << B[2:0] |
| SRL | 0101 | A >> B[2:0] (zero fill) |
| SRA | 1101 | A >>> B[2:0] (sign fill) |
| SLT | 0010 | 1 if A < B (signed) |
| SLTU | 0011 | 1 if A < B (unsigned) |

Unused opcodes give 0. Status flags: **zero**, **carry** (carry for ADD, borrow for SUB) and **overflow** (signed, ADD/SUB).

## How the shared ALU works

- **One adder for seven operations.** An adder computes *propagate* `p = a ^ b` and *generate* `g = a & b` for every bit. These are exactly the XOR and AND results, and OR is `p | g`. SUB reuses the adder with B inverted and carry-in 1. SLT is the sign of A − B corrected for overflow, and SLTU is the borrow of A − B.
- **One shifter for three shifts.** A single right shifter fills with 0 (SRL) or the sign bit (SRA). SLL reverses the bit order, shifts right, and reverses back. The reversal is only wiring.

## Resource comparison (Go Configure Resources Report)

| Resource | Regular | Shared | Change |
|---|---|---|---|
| CLB LUT5s (of 1,120) | 155 | 129 | −26 (−16.8%) |
| CLBs (of 140) | 30 | 27 | −3 |
| Flip-flops | 60 | 60 | unchanged |
| GPIOs (of 19) | 14 | 14 | unchanged |

Both designs share the same interface logic and pin assignment, so the whole saving comes from the ALU core.

## Repository layout

```
hardware/     main.v, main_shared.v          Verilog sources (top module: alu_top)
firmware/     alu_test.py                    MicroPython script for the RP2040
bitstreams/   alu.bin, alu_shared.bin        generated with Go Configure
report/       alu_report.tex, figures/       LaTeX report and screenshots
```

## Architecture

The FPGA has only 14 header pins, but a parallel ALU would need 31. So the RP2040 sends the opcode and both operands as one **24-bit SPI-style frame** (mode 0, MSB first): `{0000, op}`, `A`, `B`. On the rising edge of chip select, the FPGA loads the frame, computes, and drives the result and flags on its pins.

```
RP2040 (switches) --SCK, data, CS_N--> serial loader --> ALU core --> output registers --> analyzer
```

The FPGA is clocked by its internal 50 MHz oscillator; all inputs are synchronised to it.

## Pin assignment

| Signal | FPGA pin | Connection |
|---|---|---|
| `spi_sck` | FPGA_IO18 | jumper from RP_IO14 |
| `spi_sdi` | FPGA_IO7 | jumper from RP_IO17 |
| `spi_cs_n` | FPGA_IO0 | jumper from RP_IO16 |
| `result[7:0]` | FPGA_IO8–IO15 (PMOD) | analyzer DIO 0–7 |
| `zero` | FPGA_IO1 | analyzer DIO 8 |
| `carry` | FPGA_IO2 | analyzer DIO 9 |
| `overflow` | FPGA_IO16 | on-board LED |
| `clk` / `clk_en` | OSC_CLK / OSC_EN | internal oscillator |

Analyzer DIO 11, 12 and 13 monitor SCK, data and CS_N, so the SPI decoder shows each frame. Every output pad also needs its `_oe` port connected to the matching OE row in the I/O Planner.

The data input was originally on FPGA_IO17, but that pin was held high on the first board, so it was moved to FPGA_IO7. The current assignment works on any Shrike-Lite.

### Slide switches

Each switch connects its RP2040 pin to a common ground when ON (internal pull-ups, ON = 1):

| Switches | RP2040 pins |
|---|---|
| A0–A6 | GPIO5–GPIO11 |
| A7 | GPIO15 |
| B0–B7 | GPIO18–GPIO25 |
| op0–op3 | GPIO26–GPIO29 |

## Building and running

1. **Bitstream:** in Go Configure, create a ForgeFPGA project for **SLG47910V (Rev BB)**, add `main.v` or `main_shared.v`, synthesise, assign the pins in the I/O Planner as above (including OSC_CLK = `clk` and OSC_EN = `clk_en`), and generate the bitstream. Rename `FPGA_bitstream_MCU.bin` to `alu.bin` or `alu_shared.bin`.
2. **Upload:** in Thonny (MicroPython on the RP2040), upload the `.bin` file and `alu_test.py` to the board.
3. **Run:** the script loads the bitstream with `shrike.flash("alu.bin")`. Choose the mode at the bottom of the file: `live_mode()` reads the switches, `demo()` cycles through fixed test cases. Save it as `main.py` to start automatically at power-up.
4. **Analyzer:** in WaveForms' Logic tool, add a hex bus on DIO 0–7 and an SPI decoder (select DIO 13 active low, clock DIO 11, data DIO 12, rising edge, 8 bits, MSB first). Trigger on the falling edge of DIO 13.

## Test cases

| Operation | SPI bytes | Result | Zero | Carry | Overflow |
|---|---|---|---|---|---|
| ADD 7F, 01 | 00 7F 01 | 80 | 0 | 0 | 1 |
| SUB 10, 20 | 08 10 20 | F0 | 0 | 1 | 0 |
| AND F0, 3C | 07 F0 3C | 30 | 0 | 0 | 0 |
| OR F0, 0F | 06 F0 0F | FF | 0 | 0 | 0 |
| XOR AA, FF | 04 AA FF | 55 | 0 | 0 | 0 |
| SLL 81, 03 | 01 81 03 | 08 | 0 | 0 | 0 |
| SLL 0D, 02 | 01 0D 02 | 34 | 0 | 0 | 0 |
| SRL 81, 03 | 05 81 03 | 10 | 0 | 0 | 0 |
| SRA 81, 03 | 0D 81 03 | F0 | 0 | 0 | 0 |
| SLT FF, 01 | 02 FF 01 | 01 | 0 | 0 | 0 |
| SLTU FF, 01 | 03 FF 01 | 00 | 1 | 0 | 0 |

Both the regular and the shared design produced identical results on the analyzer.

## Tools

- Renesas Go Configure Software Hub (ForgeFPGA Workshop)
- Thonny with Vicharak's MicroPython build for the RP2040
- Digilent WaveForms with the Analog Discovery 3
