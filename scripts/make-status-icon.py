#!/usr/bin/env python3
"""Derive the menu bar template from the existing app logo's paths."""
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
logo = ET.parse(root / "Resources/AppIcon.svg").getroot()
ns = {"svg": "http://www.w3.org/2000/svg"}

lines = logo.find(".//svg:g[@id='note-lines']", ns)
result = '''<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="64 64 896 896" fill="none">
  <!-- Derived from Resources/AppIcon.svg by scripts/make-status-icon.py.
       Filled notched sheet with negative-space text lines; curl merged into body.
       Original text paths and logo proportions, optically adjusted for 18 pt:
       corner radius 180; top notch depth 176. No shading or highlights. -->
  <defs>
    <mask id="note" maskUnits="userSpaceOnUse" x="64" y="64" width="896" height="896">
'''
# Keep the logo's 768-unit body and 344-unit notch. Larger corners and a
# deeper notch remain distinct after reduction to a 15.4-point visible mark.
result += '      <rect x="128" y="128" width="768" height="768" rx="180" fill="white"/>\n'
result += '      <rect x="340" y="64" width="344" height="240" rx="56" fill="black"/>\n'
for line in lines:
    result += f'      <path d="{line.attrib["d"]}" fill="black"/>\n'
result += '''    </mask>
  </defs>
  <path d="M64 64H960V960H64Z" fill="black" mask="url(#note)"/>
</svg>
'''
destination = root / "Sources/IslandNote/Resources/StatusIcon.svg"
destination.write_text(result)
print(f"Derived {destination.relative_to(root)} from AppIcon.svg")
