#!/usr/bin/env python3
"""Bit-level error model for attacc_fp16_math_hi.sv.

The script uses Python's binary16 pack/unpack support and mirrors the RTL
integer interpolation.  It reports encoded-ULP distance for the finite input
ranges used by online softmax and SiLU.
"""

import math
import struct


EXP_LUT = [round((2 ** (-j / 32.0)) * 32768) for j in range(33)]
RECIP_LUT = [round(32768 / (1.0 + j / 64.0)) for j in range(65)]


def bits_to_half(bits):
    return struct.unpack("<e", struct.pack("<H", bits))[0]


def half_to_bits(value):
    try:
        return struct.unpack("<H", struct.pack("<e", value))[0]
    except OverflowError:
        return 0x7C00 if value >= 0 else 0xFC00


def round_shift(value, shift):
    base = value >> shift
    rem = value & ((1 << shift) - 1)
    half = 1 << (shift - 1)
    return base + int(rem > half or (rem == half and (base & 1)))


def abs_to_q12(bits):
    exponent = (bits >> 10) & 31
    mantissa = 1024 + (bits & 1023)
    if exponent == 0:
        return 0
    if exponent >= 22:
        return 0x3FFFF
    if exponent >= 13:
        return min(mantissa << (exponent - 13), 0x3FFFF)
    return round_shift(mantissa, 13 - exponent)


def q15_scaled_to_half(base, scale):
    if not base or scale >= 25:
        return 0
    if base >= 32768:
        exponent = 15 - scale
        mantissa = 0
    else:
        exponent = 14 - scale
        mantissa = round_shift(base - 16384, 4)
        if mantissa >= 1024:
            mantissa = 0
            exponent += 1
    if exponent > 0:
        return (exponent << 10) | mantissa
    sub = round_shift(base, scale - 9)
    return 0x0400 if sub >= 1024 else sub


def exp_rtl(bits):
    magnitude = abs_to_q12(bits) if bits & 0x8000 else 0
    z_q = (magnitude * 5909 + 2048) >> 12
    scale = min(z_q >> 12, 31)
    index = (z_q >> 7) & 31
    rem = z_q & 127
    delta = EXP_LUT[index] - EXP_LUT[index + 1]
    base = EXP_LUT[index] - ((delta * rem + 64) >> 7)
    return q15_scaled_to_half(base, scale)


def recip_rtl(bits):
    sign = bits & 0x8000
    exponent = (bits >> 10) & 31
    fraction = bits & 1023
    if exponent == 31:
        return 0x7E00 if fraction else sign
    if exponent == 0:
        return sign | 0x7BFF
    index, rem = fraction >> 4, fraction & 15
    delta = RECIP_LUT[index] - RECIP_LUT[index + 1]
    base = RECIP_LUT[index] - ((delta * rem + 8) >> 4)
    if base >= 32768:
        out_exp, mantissa = 30 - exponent, 0
    else:
        out_exp = 29 - exponent
        mantissa = round_shift(base - 16384, 4)
        if mantissa >= 1024:
            out_exp += 1
            mantissa = 0
    if out_exp >= 31:
        return sign | 0x7BFF
    if out_exp <= 0:
        sub = round_shift(base, exponent - 24)
        return sign | (0x0400 if sub >= 1024 else sub)
    return sign | (out_exp << 10) | mantissa


def summarize(name, samples, model, reference):
    histogram = {}
    worst = (-1, None)
    total = 0
    for bits in samples:
        got = model(bits)
        expected = half_to_bits(reference(bits))
        distance = abs((got & 0x7FFF) - (expected & 0x7FFF))
        histogram[distance] = histogram.get(distance, 0) + 1
        total += 1
        if distance > worst[0]:
            worst = (distance, bits, got, expected)
    le1 = sum(count for distance, count in histogram.items() if distance <= 1)
    le2 = sum(count for distance, count in histogram.items() if distance <= 2)
    print(
        "{}: samples={} <=1ULP={:.3f}% <=2ULP={:.3f}% maxULP={} "
        "at in=0x{:04x} got=0x{:04x} ref=0x{:04x}".format(
            name, total, 100.0 * le1 / total, 100.0 * le2 / total,
            worst[0], worst[1], worst[2], worst[3]
        )
    )


def main():
    exp_samples = [
        bits for bits in range(0x8000, 0xFC00)
        if math.isfinite(bits_to_half(bits))
    ]
    recip_samples = [
        bits for bits in range(0x0400, 0x7C00)
        if 1.0 <= bits_to_half(bits) <= 65504.0
    ]
    summarize(
        "exp[all negative finite FP16]", exp_samples, exp_rtl,
        lambda bits: math.exp(bits_to_half(bits))
    )
    summarize(
        "recip[1,65504]", recip_samples, recip_rtl,
        lambda bits: 1.0 / bits_to_half(bits)
    )


if __name__ == "__main__":
    main()
