#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared framework modules.
source "$ROOT/lib/core.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/ci.sh"
source "$ROOT/lib/workspace.sh"
source "$ROOT/lib/signing.sh"
source "$ROOT/lib/build_plan.sh"
source "$ROOT/lib/publishing.sh"
source "$ROOT/lib/diagnostics.sh"

# Package backends.
source "$ROOT/backends/rpm.sh"
source "$ROOT/backends/deb.sh"
source "$ROOT/backends/flatpak.sh"

main "$@"
