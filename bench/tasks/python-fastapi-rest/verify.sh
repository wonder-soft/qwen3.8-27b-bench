#!/usr/bin/env bash
# Python has no build step, so "build" is an import check: does the app module
# load at all? That separates syntax/import errors from behavioural test failures.
set -uo pipefail
source "$(dirname "$0")/../../scripts/verify_common.sh"
# Fall back to whatever python3 is on PATH. The old default was cab's
# /workspace/venv/bin/python, which does not exist here — and because
# run_repeat.sh cannot pass PY through, the import check failed for a missing
# interpreter and the task scored a **false 0/5** rather than erroring out.
PY=${PY:-$(command -v python3)}

PROJ=${1:?usage: verify.sh <project-dir>}
cd "$PROJ" || { verdict missing missing; exit 2; }

BUILD=fail; TEST=skip
run_step "import check" /tmp/v_build.log "$PY" -c "import app.main; print(app.main.app)" && BUILD=pass
[ "$BUILD" = pass ] && { run_step "pytest" /tmp/v_test.log "$PY" -m pytest -q && TEST=pass || TEST=fail; }
verdict "$BUILD" "$TEST"
