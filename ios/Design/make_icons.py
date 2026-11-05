#!/usr/bin/env python3
"""Generates the WakeOnCue app icons for iPhone, Apple Watch and Mac.

The mark is a waveform with a red record dot at its center: the app is always
ready to capture, and the dot is the moment you cue it. Run from anywhere:

    python3 ios/Design/make_icons.py

Writes the SVG sources next to this script and the PNGs into each target's
asset catalog. Needs `rsvg-convert` (brew install librsvg).
"""

import json
import pathlib
import subprocess

DESIGN = pathlib.Path(__file__).resolve().parent
IOS = DESIGN.parent

SIZE = 1024
CENTER = SIZE / 2

# (x offset from center, bar height); bars are mirrored around the dot.
BARS = [(205, 340), (335, 180)]
BAR_WIDTH = 76
DOT_RADIUS = 112

DEFS = """
  <defs>
    <linearGradient id="background" x1="140" y1="60" x2="884" y2="964" gradientUnits="userSpaceOnUse">
      <stop stop-color="#24345C"/>
      <stop offset="0.55" stop-color="#141C33"/>
      <stop offset="1" stop-color="#080B15"/>
    </linearGradient>
    <linearGradient id="bar" x1="0" y1="300" x2="0" y2="724" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#C7D2EC"/>
    </linearGradient>
    <radialGradient id="dot" cx="470" cy="460" r="170" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FF7A7F"/>
      <stop offset="0.6" stop-color="#F43F5E"/>
      <stop offset="1" stop-color="#D61F45"/>
    </radialGradient>
    <radialGradient id="glow" cx="512" cy="512" r="260" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FF4D6A" stop-opacity="0.45"/>
      <stop offset="1" stop-color="#FF4D6A" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1024" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFFFFF" stop-opacity="0.14"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="12" stdDeviation="12" flood-color="#000000" flood-opacity="0.35"/>
    </filter>
  </defs>"""


def svg(body: str) -> str:
  return (
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
    f'viewBox="0 0 {SIZE} {SIZE}">{DEFS}\n{body}\n</svg>\n'
  )


def mark(bars=BARS, bar_fill="url(#bar)", dot_fill="url(#dot)", glow=True) -> str:
  parts = []
  if glow:
    parts.append(f'  <circle cx="{CENTER}" cy="{CENTER}" r="260" fill="url(#glow)"/>')
  for offset, height in bars:
    for x in (CENTER - offset, CENTER + offset):
      parts.append(
        f'  <rect x="{x - BAR_WIDTH / 2}" y="{CENTER - height / 2}" width="{BAR_WIDTH}" '
        f'height="{height}" rx="{BAR_WIDTH / 2}" fill="{bar_fill}"/>'
      )
  parts.append(f'  <circle cx="{CENTER}" cy="{CENTER}" r="{DOT_RADIUS}" fill="{dot_fill}"/>')
  return "\n".join(parts)


def scaled(content: str, scale: float) -> str:
  shift = CENTER * (1 - scale)
  return f'<g transform="translate({shift} {shift}) scale({scale})">\n{content}\n</g>'


# Mac icons sit on the macOS grid: an 824 pt rounded square with a drop shadow.
MAC_TILE = 'x="100" y="100" width="824" height="824" rx="185"'


def mac(content: str) -> str:
  return "\n".join([
    f'  <g filter="url(#shadow)"><rect {MAC_TILE} fill="url(#background)"/></g>',
    f'  <rect {MAC_TILE} fill="url(#sheen)"/>',
    f'  <rect {MAC_TILE} fill="none" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="4"/>',
    scaled(content, 824 / SIZE),
  ])


BACKGROUND = f'  <rect width="{SIZE}" height="{SIZE}" fill="url(#background)"/>'

SOURCES = {
  # iPhone: full-bleed square, the system applies the mask.
  "AppIcon": svg(BACKGROUND + "\n" + mark()),
  # iOS 18 dark appearance: transparent so the system dark backdrop shows.
  "AppIcon-dark": svg(mark()),
  # iOS 18 tinted appearance: grayscale, the system colors it by luminance.
  "AppIcon-tinted": svg(mark(bar_fill="#B8B8B8", dot_fill="#FFFFFF", glow=False)),
  # Apple Watch: circular mask, so the mark shrinks to stay clear of the edge.
  "AppIcon-watch": svg(BACKGROUND + "\n" + scaled(mark(), 0.9)),
  "AppIcon-mac": svg(mac(mark())),
  # 16 and 32 px Mac icons drop the outer bars and enlarge the rest to stay legible.
  "AppIcon-mac-small": svg(mac(scaled(mark(bars=BARS[:1], glow=False), 1.3))),
}


def render(source: str, size: int, out: pathlib.Path) -> None:
  out.parent.mkdir(parents=True, exist_ok=True)
  subprocess.run(
    ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(out), str(DESIGN / f"{source}.svg")],
    check=True,
  )


def write_contents(iconset: pathlib.Path, images: list) -> None:
  iconset.mkdir(parents=True, exist_ok=True)
  contents = {"images": images, "info": {"author": "xcode", "version": 1}}
  (iconset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def ios_iconset() -> None:
  iconset = IOS / "WakeOnCue/Assets.xcassets/AppIcon.appiconset"
  images = []
  for source, appearance in [("AppIcon", None), ("AppIcon-dark", "dark"), ("AppIcon-tinted", "tinted")]:
    render(source, SIZE, iconset / f"{source}.png")
    image = {"filename": f"{source}.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    if appearance:
      image["appearances"] = [{"appearance": "luminosity", "value": appearance}]
    images.append(image)
  write_contents(iconset, images)


def watch_iconset() -> None:
  catalog = IOS / "WakeOnCueWatch/Assets.xcassets"
  write_contents(catalog, [])
  iconset = catalog / "AppIcon.appiconset"
  render("AppIcon-watch", SIZE, iconset / "AppIcon.png")
  write_contents(iconset, [
    {"filename": "AppIcon.png", "idiom": "universal", "platform": "watchos", "size": "1024x1024"},
  ])


# Both Mac apps share the icon: the iOS repo's companion target and the standalone app in macos/.
MAC_CATALOGS = [IOS / "WakeOnCueMac/Assets.xcassets", IOS.parent / "macos/WakeOnCue/Assets.xcassets"]


def mac_iconset(catalog: pathlib.Path) -> None:
  write_contents(catalog, [])
  iconset = catalog / "AppIcon.appiconset"
  images = []
  for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
      pixels = points * scale
      source = "AppIcon-mac-small" if pixels <= 32 else "AppIcon-mac"
      filename = f"AppIcon-{points}@{scale}x.png"
      render(source, pixels, iconset / filename)
      images.append({
        "filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}",
      })
  write_contents(iconset, images)


def main() -> None:
  for name, content in SOURCES.items():
    (DESIGN / f"{name}.svg").write_text(content)
  ios_iconset()
  watch_iconset()
  for catalog in MAC_CATALOGS:
    mac_iconset(catalog)


if __name__ == "__main__":
  main()
