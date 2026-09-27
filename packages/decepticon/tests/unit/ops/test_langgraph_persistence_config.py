"""Regression guard: the shipped langgraph service must not write to the host disk.

`langgraph dev` always runs the in-memory runtime, whose flush loop re-pickles
the ENTIRE checkpoint state to /app/.langgraph_api/*.pckl every 10s with no
dirty check and no pruning (measured on VM 150: 198 MB rewritten every ~10s,
26.9 MiB/s, 32.3 TB in 18 days). The runtime's disable switch is a no-op through
`langgraph dev` in the pinned langgraph-cli (see docs/adr/0013), so the fix is a
size-capped tmpfs on /app/.langgraph_api: the writes land in RAM, not the NVMe.

This test fails on the old config (no tmpfs floor) and passes once the tmpfs is
in place. It is a static config check, no container is started. The tmpfs
assertion is the load-bearing guard; the env-var assertion records the
forward-compatible flag that will take over if upstream honors it.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

_REPO_ROOT = Path(__file__).resolve().parents[5]
_COMPOSE = _REPO_ROOT / "docker-compose.yml"

_DISABLE_KEY = "LANGGRAPH_DISABLE_FILE_PERSISTENCE"
_API_DIR = "/app/.langgraph_api"


def _langgraph_service() -> dict:
    compose = yaml.safe_load(_COMPOSE.read_text(encoding="utf-8"))
    services = compose["services"]
    assert "langgraph" in services, "compose has no langgraph service"
    return services["langgraph"]


def _env_default_truthy(value: str) -> bool:
    """True if a compose env value resolves to a truthy default.

    Accepts a bare ``true`` or a ``${VAR:-true}`` interpolation whose default
    is truthy.
    """
    value = value.strip()
    if value.lower() == "true":
        return True
    m = re.fullmatch(r"\$\{[^:}]+:-([^}]*)\}", value)
    return bool(m) and m.group(1).strip().lower() == "true"


def test_compose_mounts_size_capped_tmpfs_floor() -> None:
    """THE fix: /app/.langgraph_api is a size-capped tmpfs so the runtime's
    unavoidable 10s re-pickling hits RAM (capped), never the host NVMe."""
    volumes = _langgraph_service().get("volumes", [])
    tmpfs_mounts = [
        v
        for v in volumes
        if isinstance(v, dict) and v.get("type") == "tmpfs" and v.get("target") == _API_DIR
    ]
    assert tmpfs_mounts, (
        f"compose langgraph service must back {_API_DIR} with a tmpfs so writes "
        "never reach the host disk (ADR-0013)."
    )
    size = tmpfs_mounts[0].get("tmpfs", {}).get("size")
    assert isinstance(size, int) and size > 0, (
        f"the {_API_DIR} tmpfs must be size-capped so a runaway blob fails loud "
        f"with ENOSPC in RAM instead of wearing the disk; got size={size!r}."
    )


def test_compose_sets_forward_compat_disable_flag() -> None:
    """Records the forward-compatible disable flag. It is a no-op through
    `langgraph dev` today (ADR-0013) but must stay set so it takes over if a
    future upstream bump honors it."""
    env = _langgraph_service().get("environment", [])
    # compose environment is a list of "KEY=VALUE" strings here.
    pairs = dict(item.split("=", 1) for item in env if "=" in item)
    assert _DISABLE_KEY in pairs, f"compose langgraph service must set {_DISABLE_KEY} (ADR-0013)."
    assert _env_default_truthy(pairs[_DISABLE_KEY]), (
        f"{_DISABLE_KEY} must default to true; got {pairs[_DISABLE_KEY]!r} (ADR-0013)."
    )
