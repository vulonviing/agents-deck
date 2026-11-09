#!/bin/bash
# Renders index.html to ../ss1.png at 2x using headless Google Chrome (macOS).
set -e
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --force-device-scale-factor=2 --window-size=600,1100 --screenshot="$PWD/../ss1.png" "file://$PWD/index.html"
