#!/usr/bin/env python3
"""Derive a pixel-aligned menu bar SVG from the existing app logo."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
logo = ET.parse(root / "Resources/AppIcon.svg").getroot()
ns = {"svg": "http://www.w3.org/2000/svg"}
lines = logo.find(".//svg:g[@id='note-lines']", ns)

# The original AppIcon.svg uses 60% corner smoothing. These normalized
# transition points preserve its cubic/arc/cubic construction, rather than
# replacing it with a circular SVG rect corner.
a, b = (248.6339 - 128) / 116, (216.1509 - 128) / 116
c, d = (140.6432 - 128) / 116, (191.3371 - 128) / 116

def number(value):
    return f"{value:.5f}".rstrip("0").rstrip(".")

def corner(x, y, radius, turns):
    def point(u, v):
        for _ in range(turns):
            u, v = -v, u
        return f"{number(x + u * radius)} {number(y + v * radius)}"
    return (f'L{point(-1.6, 0)}'
            f'C{point(-a, 0)} {point(-b, 0)} {point(-d, c)}'
            f'A{radius} {radius} 0 0 1 {point(-c, d)}'
            f'C{point(0, b)} {point(0, a)} {point(0, 1.6)}')

# View box 80...944 makes the body exactly 16 pt within its 18 pt canvas.
# Its straight edges land on pixel boundaries at both 1x and 2x.
body = "M691.2 128"
for x, y, turns in [(896, 128, 0), (896, 896, 1),
                    (128, 896, 2), (128, 128, 3)]:
    body += corner(x, y, 128, turns)

# A 3 pt deep notch, slightly shorter than the previous 3.54 pt. Its bottom
# corners use the same smooth transition as the original logo's perimeter.
r, left, right, bottom = 40, 344, 680, 272
body += f'L{left} 128V{number(bottom - 1.6 * r)}'
body += (f'C{left} {number(bottom - a*r)} {left} {number(bottom - b*r)} '
         f'{number(left + c*r)} {number(bottom - d*r)}'
         f'A{r} {r} 0 0 0 {number(left + d*r)} {number(bottom - c*r)}'
         f'C{number(left + b*r)} {bottom} {number(left + a*r)} {bottom} '
         f'{number(left + 1.6*r)} {bottom}'
         f'H{number(right - 1.6*r)}'
         f'C{number(right - a*r)} {bottom} {number(right - b*r)} {bottom} '
         f'{number(right - d*r)} {number(bottom - c*r)}'
         f'A{r} {r} 0 0 0 {number(right - c*r)} {number(bottom - d*r)}'
         f'C{right} {number(bottom - b*r)} {right} {number(bottom - a*r)} '
         f'{right} {number(bottom - 1.6*r)}V128Z')

def shift_y(path, offset):
    """Translate the original line outlines, including arc endpoints."""
    result = ""
    for command, values in re.findall(r"([MLCAZ])([^MLCAZ]*)", path):
        values = [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", values)]
        if command == "A":
            values[6] += offset
        else:
            for i in range(1, len(values), 2):
                values[i] += offset
        result += command + " ".join(number(v) for v in values)
    return result

# Move both lines down. Their top/bottom edges now fall at 7/8.5 and
# 10.5/12 pt, respectively: whole physical pixels on Retina displays.
cutouts = [shift_y(line.attrib["d"], offset) for line, offset in zip(lines, [34, 26], strict=True)]
result = f'''<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="80 80 864 864">
  <!-- Derived from Resources/AppIcon.svg by scripts/make-status-icon.py.
       Original 60% smooth corner construction and text-line outlines.
       16 pt body, 3 pt notch, Retina-aligned text cutouts. No raster mask. -->
  <path d="{body} {' '.join(cutouts)}" fill="black" fill-rule="evenodd"/>
</svg>
'''
destination = root / "Sources/IslandNote/Resources/StatusIcon.svg"
destination.write_text(result)
print(f"Derived {destination.relative_to(root)} from AppIcon.svg")
