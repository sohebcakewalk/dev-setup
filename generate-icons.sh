#!/bin/bash
echo "Generating app icons..."

for size in 48 72 96 128 144 152 192 256 384 512; do
  sips -z $size $size logo.png --out ../../public/icons/icon-${size}x${size}.png
done

echo "App icons generated."
