#!/usr/bin/env bash
#
# Build and run the app, on the Mac it is typed on.
#
#   scripts/run-macos.sh                        # 127.0.0.1:5900
#   scripts/run-macos.sh 127.0.0.1:5999         # a server put there by a tunnel
#   scripts/run-macos.sh 127.0.0.1:5999 secret  # and a password, for RSA-AES
#
# This needs a window server, so from the Linux checkout it must be started
# inside the macsandbox tmux session rather than over plain ssh — CLAUDE.local.md
# has the incantation. `open` rather than running the binary directly: an app
# launched by launchd gets the activation and the keyboard focus that a process
# started from a shell does not.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

server=${1:-127.0.0.1:5900}
password=${2:-}

./build-core.sh "${WLSHARE_CORE_PROFILE:-release}"
xcodegen generate
xcodebuild build \
    -project WlshareViewer.xcodeproj \
    -scheme WlshareViewer \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/run \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO

app=build/run/Build/Products/Debug/WlshareViewer.app
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }

args=(-server "$server")
[ -n "$password" ] && args+=(-password "$password")
echo "[run] open $app --args ${args[*]}"
open "$app" --args "${args[@]}"
