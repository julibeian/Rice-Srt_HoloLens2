#!/usr/bin/env python3
"""Pure CAM grid post-processing shared by the dynamic inference service.

No torch or numpy dependency, so the geometry and threshold rules can be
tested on any Python installation. Input is a rectangular grid of raw CAM
values; output is a normalised grid plus a coarse box in relative coordinates.
"""
from __future__ import annotations

import math


def payload(values, threshold=0.5):
    """Return a compact CAM annotation for a 2D list, or None if unusable."""
    if not isinstance(values, (list, tuple)) or not values:
        return None
    rows = [list(row) for row in values]
    height = len(rows)
    width = len(rows[0]) if rows else 0
    if height < 1 or width < 1 or any(len(row) != width for row in rows):
        return None
    cleaned = []
    peak = 0.0
    for row in rows:
        output = []
        for value in row:
            try:
                number = float(value)
            except (TypeError, ValueError):
                number = 0.0
            if not math.isfinite(number) or number < 0:
                number = 0.0
            peak = max(peak, number)
            output.append(number)
        cleaned.append(output)
    if peak <= 0:
        return None
    grid = [[round(value / peak, 3) for value in row] for row in cleaned]
    cells = [(x, y) for y in range(height) for x in range(width)
             if grid[y][x] >= threshold]
    if not cells:
        best = max(((grid[y][x], x, y) for y in range(height)
                    for x in range(width)), key=lambda item: (item[0], -item[1], -item[2]))
        cells = [(best[1], best[2])]
    xs = [cell[0] for cell in cells]
    ys = [cell[1] for cell in cells]
    x0, x1 = min(xs), max(xs) + 1
    y0, y1 = min(ys), max(ys) + 1
    peak_cell = max(((grid[y][x], x, y) for y in range(height)
                     for x in range(width)), key=lambda item: (item[0], -item[1], -item[2]))
    return {
        "kind": "cam",
        "grid": {"width": width, "height": height, "values": grid},
        "box": [round(x0 / width, 4), round(y0 / height, 4),
                round((x1 - x0) / width, 4), round((y1 - y0) / height, 4)],
        "peak": [round((peak_cell[1] + 0.5) / width, 4),
                 round((peak_cell[2] + 0.5) / height, 4)],
        "threshold": threshold,
    }
