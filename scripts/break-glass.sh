#! /usr/bin/env bash

echo "don't panic"

pkill -TERM -f run-forever.sh
pkill -f 'ffmpeg .*overlay.filter'
pkill -f 'moq --client-connect'

echo glass broken