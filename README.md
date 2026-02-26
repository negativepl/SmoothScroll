# SmoothScroll

A lightweight macOS menu bar app that makes mouse scroll wheel buttery smooth — like a trackpad.

No subscription. No bloat. Just ~200 lines of Swift.

<p align="center">
  <img src="icon.png" width="128" alt="SmoothScroll icon">
</p>

## Why?

Mouse scroll wheels on macOS feel janky — they send large, discrete jumps instead of the smooth pixel-by-pixel scrolling you get from a trackpad. SmoothScroll intercepts those events and replaces them with smooth, animated scrolling using exponential easing.

Works with any mouse (Logitech, Razer, generic USB mice, etc.) without affecting trackpad behavior.

## Features

- Smooth scrolling with exponential ease-out animation at 120Hz
- Automatically distinguishes mouse from trackpad (passes trackpad events through unchanged)
- Works with mice that report as "continuous" scroll devices (e.g. Logitech with smooth scroll)
- Adjustable **speed** (how far each scroll notch moves)
- Adjustable **smoothness** (how long the animation takes)
- Launch at Login support
- Lives in the menu bar — no Dock icon
- Zero dependencies, single Swift file

## Install

### Build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/YOUR_USERNAME/SmoothScroll.git
cd SmoothScroll
chmod +x build.sh
./build.sh
cp -r build/SmoothScroll.app /Applications/
```

### First launch

1. Open SmoothScroll from `/Applications` or Spotlight
2. macOS will prompt for **Accessibility** permission
3. Go to **System Settings → Privacy & Security → Accessibility** and enable SmoothScroll
4. The app will automatically start working once permission is granted

## Usage

Click the mouse icon in the menu bar:

- **Smooth Scrolling** — toggle on/off
- **Speed** — Slow / Normal / Fast / Very Fast
- **Smoothness** — Very Smooth / Smooth / Normal / Responsive
- **Launch at Login** — start automatically with macOS
- **Quit**

## How it works

1. Installs a `CGEventTap` to intercept scroll wheel events globally
2. Detects mouse vs trackpad by checking `scrollWheelEventScrollPhase` (trackpad has phases, mouse doesn't)
3. Suppresses the original mouse scroll event
4. Accumulates the pixel delta into a buffer
5. A 120Hz timer drains the buffer using exponential decay, posting smooth pixel-based scroll events
6. Sub-pixel error tracking prevents rounding drift

## Requirements

- macOS 13.0+ (Ventura or later)
- Accessibility permission

## License

MIT
