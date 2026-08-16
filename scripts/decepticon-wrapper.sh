#!/usr/bin/env bash
# =============================================================================
# decepticon-wrapper.sh — front-end for the fork-built launcher on this box.
# =============================================================================
# `~/.local/bin/decepticon` symlinks here (see CLAUDE.md § Launching). It routes:
#   decepticon            -> `decepticon start`   (the launch path we always want)
#   decepticon update     -> scripts/refresh.sh   (rebuild from THIS fork —
#                                                   NEVER the launcher's GHCR pull)
#   decepticon <anything> -> passed straight through to the real launcher
#                            (start/status/stop/logs/onboard/opscontrol/--help/…)
#
# Why: bare `decepticon` otherwise only prints help, and `decepticon update`
# would pull upstream ghcr.io/purpleailab images and clobber the fork-built
# ones. Both footguns are rerouted here.
# =============================================================================
set -euo pipefail

REPO="$HOME/Decepticon"
REAL="$REPO/clients/launcher/bin/decepticon"
REFRESH="$REPO/scripts/refresh.sh"

if [[ ! -x "$REAL" ]]; then
  echo "decepticon: launcher binary not found at $REAL" >&2
  echo "  build it with:  (cd \"$REPO\" && make launcher)" >&2
  exit 127
fi

case "${1:-}" in
  "")
    # Bare invocation -> the launch path. Transparent, not silent.
    echo "-> decepticon start   (bare 'decepticon' routes here; subcommands pass through)" >&2
    exec "$REAL" start
    ;;
  update)
    # Rebuild from the fork, never a GHCR pull.
    echo "-> rebuilding from this fork via scripts/refresh.sh (not a GHCR pull)" >&2
    exec "$REFRESH" "${@:2}"
    ;;
  *)
    exec "$REAL" "$@"
    ;;
esac
