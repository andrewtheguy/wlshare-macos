#!/usr/bin/env bash
#
# Run this repo's checks natively on this Mac.
#
#   ci/ci.sh                   # the default jobs
#   ci/ci.sh core              # only these
#   ci/ci.sh --list            # what jobs exist
#
# From the Linux checkout this is reached through scripts/mac-ci.sh, which
# pushes this tree, the sibling ../wlshare the core links against, and
# ../devtools, then runs this over ssh.
#
# Jobs:
#   core     the Rust core: cargo test, then clippy with warnings denied
#   app      build the core for arm64 and build the app against it
#   package  the Release build and the disk image a release ships
#   live     the ignored session tests, against WLSHARE_TEST_SERVER
#
# `live` is not in the default set: it needs a wlshare to talk to, which on
# this machine means a tunnel someone put there. Ask for it by name. Nor is
# `package`: it is a from-scratch Release build of what `app` has already
# compiled, and only a release — or a check that the release will work — wants
# it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ALL_JOBS=(core app package live)
DEFAULT_JOBS=(core app)

usage() { echo "usage: $0 [--list] [${ALL_JOBS[*]}]" >&2; exit 2; }

jobs=()
while [ $# -gt 0 ]; do
    case $1 in
        --list)
            printf '%s\n' "available: ${ALL_JOBS[*]}" "default:   ${DEFAULT_JOBS[*]}"
            exit 0 ;;
        -h|--help) usage ;;
        *)
            for known in "${ALL_JOBS[@]}"; do
                [ "$1" = "$known" ] && { jobs+=("$1"); shift; continue 2; }
            done
            echo "unknown job: $1" >&2; usage ;;
    esac
done
[ ${#jobs[@]} -eq 0 ] && jobs=("${DEFAULT_JOBS[@]}")

step() { echo; echo "=== $* ==="; }
die() { echo "[ci] error: $*" >&2; exit 1; }

DERIVED=build/ci/DerivedData

job_core() {
    step 'core: cargo test'
    (cd core && cargo test)
    step 'core: cargo clippy'
    (cd core && cargo clippy --all-targets -- -D warnings)
}

job_app() {
    command -v xcodebuild >/dev/null || die 'xcodebuild not found — install Xcode and run xcode-select'
    command -v xcodegen >/dev/null || die 'xcodegen not found (brew install xcodegen)'
    step 'app: the Rust core'
    ./build-core.sh release
    step 'app: xcodegen'
    xcodegen generate
    step 'app: xcodebuild'
    # CODE_SIGNING_ALLOWED=NO so a machine with no identity still builds; the
    # app is ad-hoc signed for running locally, which scripts/run-macos.sh does.
    xcodebuild build \
        -project WlshareViewer.xcodeproj \
        -scheme WlshareViewer \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED" \
        CODE_SIGNING_ALLOWED=NO
}

job_package() {
    step 'package: the disk image'
    # The same script the release workflow runs, so this job is the rehearsal
    # for a release and not an imitation of one.
    scripts/package-mac.sh
}

job_live() {
    step 'live: the session tests'
    [ -n "${WLSHARE_TEST_SERVER:-}" ] || echo "[ci] WLSHARE_TEST_SERVER unset; trying 127.0.0.1:5999"
    (cd core && cargo test --test live_session -- --ignored --nocapture --test-threads=1)
}

for job in "${jobs[@]}"; do
    "job_$job"
done
echo
echo "[ci] ${jobs[*]} passed"
