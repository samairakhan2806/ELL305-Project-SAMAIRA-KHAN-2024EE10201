import shrike, time
from machine import Pin

shrike.flash("alu.bin")      
time.sleep_ms(100)

SCK  = Pin(14, Pin.OUT, value=0)   
SDI  = Pin(17, Pin.OUT, value=0)   
CS_N = Pin(16, Pin.OUT, value=1)   

OPS = {"ADD": 0b0000, "SLL": 0b0001, "SLT": 0b0010, "SLTU": 0b0011,
       "XOR": 0b0100, "SRL": 0b0101, "OR":  0b0110, "AND":  0b0111,
       "SUB": 0b1000, "SRA": 0b1101}

def send(op, a, b):
    """Send one 24-bit frame: {0000, op} A B, MSB first, SPI mode 0."""
    frame = ((op & 0xF) << 16) | ((a & 0xFF) << 8) | (b & 0xFF)
    CS_N(0); time.sleep_us(10)
    for i in range(23, -1, -1):
        SDI((frame >> i) & 1); time.sleep_us(5)
        SCK(1); time.sleep_us(5)
        SCK(0)
    time.sleep_us(10); CS_N(1)             # rising edge -> FPGA loads A, B, op

def s8(x):                                 # 8-bit two's complement -> int
    return x - 256 if x & 0x80 else x

def expected(name, a, b):
    sh = b & 7
    r = {"ADD": a + b, "SUB": a - b, "AND": a & b, "OR": a | b, "XOR": a ^ b,
         "SLL": a << sh, "SRL": a >> sh, "SRA": s8(a) >> sh,
         "SLT": int(s8(a) < s8(b)), "SLTU": int(a < b)}[name]
    return r & 0xFF

def demo(gap_ms=500):
    """One frame per operation; trigger the analyzer on CS_N rising."""
    tests = [("ADD", 0x7F, 0x01), ("SUB", 0x10, 0x20), ("AND", 0xF0, 0x3C),
             ("OR", 0xF0, 0x0F), ("XOR", 0xAA, 0xFF), ("SLL", 0x81, 0x03),
             ("SRL", 0x81, 0x03), ("SRA", 0x81, 0x03), ("SLT", 0xFF, 0x01),
             ("SLTU", 0xFF, 0x01)]
    for name, a, b in tests:
        send(OPS[name], a, b)
        print("%-4s A=%02X B=%02X -> expect %02X" % (name, a, b, expected(name, a, b)))
        time.sleep_ms(gap_ms)

A_PINS  = [5, 6, 7, 8, 9, 10, 11, 15]      # A0..A7  (A0 = LSB)
B_PINS  = [18, 19, 20, 21, 22, 23, 24, 25] # B0..B7
OP_PINS = [26, 27, 28, 29]                 # op0..op3

SWITCH_TO_GND = True

NAMES = {v: k for k, v in OPS.items()}

def live_mode():
    pull = Pin.PULL_UP if SWITCH_TO_GND else None
    pins = [Pin(p, Pin.IN, pull) for p in A_PINS + B_PINS + OP_PINS]

    def read_all():
        v = 0
        for i, p in enumerate(pins):
            bit = p.value()
            if SWITCH_TO_GND:
                bit ^= 1                   # ON pulls the pin low -> count as 1
            v |= bit << i
        return v

    last = None
    print("Live mode: set A, B and op on the switches; the result follows.")
    while True:
        v = read_all()
        time.sleep_ms(20)
        if v == read_all() and v != last:  # same for 20 ms = settled, and changed
            last = v
            a, b, op = v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xF
            send(op, a, b)
            name = NAMES.get(op, "????")
            exp = ("%02X" % expected(name, a, b)) if name in OPS else "00 (unused op)"
            print("%-4s A=%02X B=%02X -> expect %s" % (name, a, b, exp))
        time.sleep_ms(10)

#while True:
#    demo() # fixed test sequence (protocol analyzer check)
#demo()
live_mode() # slide switches (supervisor demo)