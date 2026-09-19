#!/usr/bin/env bash
#
# Build and run the app, on the Mac it is typed on.
#
#   scripts/run-macos.sh                        # ask in the app's own window
#   scripts/run-macos.sh 127.0.0.1:5999         # a server put there by a tunnel
#
# A password is not one of the words this takes: an argument list is in the
# shell's history and in everyone's `ps`. The app uses the one saved in a
# profile for the same destination and asks for anything else in its own form.
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
[ $# -le 1 ] || { echo "usage: $0 [host:port]  (the app asks for the password itself)" >&2; exit 2; }
server=${1:-}

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

if [ -n "$server" ]; then
    echo "[run] open $app --args -server $server"
    open "$app" --args -server "$server"
else
    echo "[run] open $app"
    open "$app"
fi
