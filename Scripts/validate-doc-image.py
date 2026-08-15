#!/usr/bin/env python3
"""Validate the alpha shape used by documentation screenshot windows."""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def paeth(left: int, above: int, upper_left: int) -> int:
    prediction = left + above - upper_left
    left_distance = abs(prediction - left)
    above_distance = abs(prediction - above)
    upper_left_distance = abs(prediction - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def rgba_rows(path: Path) -> tuple[int, int, list[bytes]]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG")

    offset = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        offset += length + 12
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", chunk_data
            )
        elif chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if None in (width, height, bit_depth, color_type, interlace):
        raise ValueError("missing IHDR")
    if bit_depth != 8 or color_type != 6 or interlace != 0:
        raise ValueError("expected a non-interlaced 8-bit RGBA PNG")

    bytes_per_pixel = 4
    row_bytes = width * bytes_per_pixel
    decoded = zlib.decompress(bytes(compressed))
    if len(decoded) != height * (row_bytes + 1):
        raise ValueError("unexpected decoded PNG size")

    rows: list[bytes] = []
    previous = bytearray(row_bytes)
    cursor = 0
    for _ in range(height):
        filter_type = decoded[cursor]
        cursor += 1
        raw = decoded[cursor : cursor + row_bytes]
        cursor += row_bytes
        row = bytearray(row_bytes)
        for index, value in enumerate(raw):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                predictor = paeth(left, above, upper_left)
            else:
                raise ValueError(f"unknown PNG filter {filter_type}")
            row[index] = (value + predictor) & 0xFF
        rows.append(bytes(row))
        previous = row
    return width, height, rows


def alpha(rows: list[bytes], x: int, y: int) -> int:
    return rows[y][(x * 4) + 3]


def has_transparent_window_corners(path: Path) -> bool:
    width, height, rows = rgba_rows(path)
    transparent_corners = (
        alpha(rows, 0, 0),
        alpha(rows, width - 1, 0),
        alpha(rows, 0, height - 1),
        alpha(rows, width - 1, height - 1),
    )
    opaque_edges = (
        alpha(rows, width // 2, 0),
        alpha(rows, width // 2, height - 1),
        alpha(rows, 0, height // 2),
        alpha(rows, width - 1, height // 2),
    )
    return all(value == 0 for value in transparent_corners) and all(
        value == 255 for value in opaque_edges
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-doc-image.py IMAGE.png", file=sys.stderr)
        return 2
    try:
        return 0 if has_transparent_window_corners(Path(sys.argv[1])) else 1
    except (OSError, ValueError, zlib.error) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
