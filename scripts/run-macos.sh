#!/usr/bin/env bash
#
# Build and run the app, on the Mac it is typed on.
#
#   scripts/run-macos.sh                        # ask in the app's own window
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

# No server on the command line is how a packaged app is launched: the app puts
# its connect form up instead.
server=${1:-}
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

args=()
[ -n "$server" ] && args+=(-server "$server")
[ -n "$password" ] && args+=(-password "$password")
# `${args[*]-}`, because `set -u` and the bash macOS ships call an empty array
# unbound.
echo "[run] open $app ${args[*]-}"
if [ ${#args[@]} -eq 0 ]; then
    open "$app"
else
    open "$app" --args "${args[@]}"
fi
