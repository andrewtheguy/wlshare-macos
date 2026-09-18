#!/usr/bin/env bash
#
# Render icon/AppIcon.svg into the asset catalog's app icon set.
#
#   scripts/make-icon.sh
#
# The SVG is the icon; the PNGs are generated from it and checked in, so a
# build needs neither this script nor rsvg-convert. Run it after editing the SVG.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (apt install librsvg2-bin / brew install librsvg)" >&2; exit 1; }

set_dir=Sources/WlshareViewer/Assets.xcassets/AppIcon.appiconset
mkdir -p "$set_dir"

images=()
for pt in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((pt * scale))
        suffix=""
        [ "$scale" = 1 ] || suffix="@${scale}x"
        name="icon_${pt}x${pt}${suffix}.png"
        rsvg-convert -w "$px" -h "$px" icon/AppIcon.svg -o "$set_dir/$name"
        images+=("    { \"idiom\" : \"mac\", \"size\" : \"${pt}x${pt}\", \"scale\" : \"${scale}x\", \"filename\" : \"$name\" }")
    done
done

{
    echo '{'
    echo '  "images" : ['
    (IFS=$'\n'; echo "${images[*]}") | sed '$!s/$/,/'
    echo '  ],'
    echo '  "info" : { "version" : 1, "author" : "xcode" }'
    echo '}'
} > "$set_dir/Contents.json"

cat > Sources/WlshareViewer/Assets.xcassets/Contents.json <<'JSON'
{
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON
