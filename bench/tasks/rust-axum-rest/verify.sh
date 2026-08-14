#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../scripts/verify_common.sh"
export PATH=$HOME/.cargo/bin:$PATH

PROJ=${1:?usage: verify.sh <project-dir>}
cd "$PROJ" || { verdict missing missing; exit 2; }

BUILD=fail; TEST=skip
run_step "cargo build" /tmp/v_build.log cargo build && BUILD=pass
[ "$BUILD" = pass ] && { run_step "cargo test" /tmp/v_test.log cargo test && TEST=pass || TEST=fail; }
verdict "$BUILD" "$TEST"
