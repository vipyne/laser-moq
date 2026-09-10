#!/usr/bin/env bash
# Prints avfoundation video/audio devices (ffmpeg exits non-zero here by design).
ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | grep -E '^\[AVFoundation' || true
