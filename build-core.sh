#!/usr/bin/env bash
#
# Build the Rust core into the static library the app links.
#
#   ./build-core.sh            # release, this Mac's architecture
#   ./build-core.sh debug      # debug, for a faster edit-build-run loop
#
# The result is dist/libwlshare_client_core.a beside dist/wlshare_client.h, the
# two paths project.yml points LIBRARY_SEARCH_PATHS and HEADER_SEARCH_PATHS at.
# There is no xcframework and no release zip: the core is in this repo, so it
# is built from source every time, and the only consumer is one app target.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

profile=${1:-release}
case $profile in
    release) flags=(--release) ;;
    debug) flags=() ;;
    *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

# Named explicitly rather than left to the host default: Xcode builds arm64 and
# a core built for anything else links with a message about architectures that
# says nothing about why.
target=${WLSHARE_CORE_TARGET:-aarch64-apple-darwin}

command -v cargo >/dev/null || { echo "cargo not found — install Rust" >&2; exit 1; }
# Nothing checks for a sibling ../wlshare: wlshare-rfb is a pinned tag that cargo
# fetches by itself, which is what lets a machine holding only this repo — a
# release runner, say — build the app.

echo "[core] cargo build --target $target ${flags[*]-}"
(cd core && cargo build --target "$target" ${flags[@]+"${flags[@]}"})

mkdir -p dist
cp "core/target/$target/$profile/libwlshare_client_core.a" dist/
cp core/include/wlshare_client.h dist/
echo "[core] dist/libwlshare_client_core.a ($(du -h dist/libwlshare_client_core.a | cut -f1))"
