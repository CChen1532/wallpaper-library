#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 工具/快速墙纸/wallpaper-switch.py restore
