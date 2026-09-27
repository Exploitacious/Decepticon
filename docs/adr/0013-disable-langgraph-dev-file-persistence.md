# 0013. Keep langgraph-dev's idle pickle writes off the host disk with a tmpfs

- **Status:** Proposed
- **Date:** 2026-09-27
- **Deciders:** Exploitacious
- **Related:** docker-compose.yml (`langgraph` service), `.env.example`, `packages/decepticon/tests/unit/ops/test_langgraph_persistence_config.py`

## Context

The stack runs the LangGraph server as `langgraph dev` (a compose service,
built from `containers/langgraph.Dockerfile`). `langgraph dev` always selects
the in-memory runtime: it hardcodes `__database_uri__=":memory:"` and
`runtime_edition="inmem"` and never reads the process `DATABASE_URI`, so setting
`DATABASE_URI` has no effect on which runtime loads (`langgraph_cli` 0.4.29
`cli.py` `dev()` -> `run_server()`; `langgraph_api` 0.10.0 `cli.py`).

The in-memory runtime keeps its checkpoint state in three dicts (`storage`,
`writes`, `blobs`) mirrored to disk under `/app/.langgraph_api/` as
`.langgraph_checkpoint.{1,2,3}.pckl` plus `.langgraph_ops.pckl`. A daemon thread
(`langgraph_runtime_inmem` 0.30.0 `_persistence.py`, `_flush_interval = 10`,
`_flush_loop`) calls `PersistentDict.sync()` on every registered store every 10
seconds unconditionally. `sync()` (`langgraph_checkpoint` 4.1.1
`langgraph/checkpoint/memory/__init__.py`) re-pickles the entire dict and
atomically replaces the file. There is no dirty flag anywhere in the class, so
the whole state is rewritten every interval whether or not anything changed, and
the `blobs` dict (`.langgraph_checkpoint.3.pckl`) is only pruned by an explicit
`delete_thread()`, never by TTL or the flush loop, so it grows unbounded.

Measured on VM 150 (idle): `.3.pckl` reached 198 MB, rewritten roughly every 10
seconds even with zero activity: 26.9 MiB/s, 32.3 TB over 18 days, driving the
homelab's only NVMe at 0.44%/day. `/app/.langgraph_api` was not volume-mounted,
so those writes hit the container's writable layer on the host disk.

The obvious fix would be to disable the file persistence. The runtime does have
a switch, `LANGGRAPH_DISABLE_FILE_PERSISTENCE` (read at import by
`_persistence.py` and the checkpoint memory backend), settable in principle via
`"disable_persistence": true` in `langgraph.json`. We verified on this box that
**neither route works through `langgraph dev` in the pinned versions**:

- `langgraph_cli` 0.4.29 loads config through `validate_config_file()`, whose
  schema does not include `disable_persistence`; the key is silently stripped
  (confirmed: the validated config's keys do not contain it), so
  `config_json.get("disable_persistence", False)` is always `False`.
- `run_server()` then builds a `to_patch` env dict with
  `LANGGRAPH_DISABLE_FILE_PERSISTENCE=str(disable_persistence).lower()` = `false`
  and applies it with `patch_environment()`; the loaded-env merge explicitly
  refuses to overwrite keys already in `to_patch`. So a container-level env var,
  a `.env` entry, and the config key are all overridden to `false` in the worker
  process that does the writing (observed directly: the worker subprocess env
  showed `LANGGRAPH_DISABLE_FILE_PERSISTENCE=false` even when the container was
  launched with it set to `true`, and the `.pckl` files were still written).

So there is no supported way to stop the writes from inside `langgraph dev` at
these versions. There is also no knob for the 10s interval (`_flush_interval` is
a hardcoded module constant).

## Decision

Keep the writes off the host NVMe by backing `/app/.langgraph_api` with a
size-capped `tmpfs` in the compose `langgraph` service (1 GiB). The runtime
still re-pickles every 10s, but into RAM, so the disk sees nothing.

Also set `LANGGRAPH_DISABLE_FILE_PERSISTENCE=true` in the compose env as a
forward-compatible signal: it is a no-op today (overridden as described above),
does no harm, and will disable the writes for real if a future upstream bump
honors it. `langgraph.json` is left unchanged (an unrecognized key is stripped
today and could be rejected by a stricter future validator).

Verified on this box (single image build, run idle ~60s each):
- Without the tmpfs: `.langgraph_ops.pckl` (8.4 MB after one seeded run) was
  rewritten every 10s and the container's block-IO **write** climbed to 277 MB.
- With the tmpfs: the same file was still rewritten every 10s (into RAM), the
  tmpfs held ~8 MB, and the container's block-IO **write stayed at 0 B**.

## Consequences

- **Easier:** idle host-disk writes from this service are zero; NVMe wear from
  it stops. Guarded by a static test on the shipped compose
  (`test_langgraph_persistence_config.py`) that fails without the tmpfs.
- **Harder:** nothing operationally.
- **Given up:** LangGraph run/checkpoint history no longer survives a container
  restart (the tmpfs is cleared). Near-zero loss in practice: the stack already
  ran `:memory:` (ephemeral across restarts), `/app/.langgraph_api` was never
  volume-mounted (state was already lost on every recreate/rebuild), and
  engagement evidence persists independently via `EventLogMiddleware`
  (`events.jsonl`) and the workspace mount. In-run state (sub-agent handoffs
  within one server process) is unaffected: it lives in the same in-memory dicts.
- **Residual cost (not solved here):** the runtime still burns CPU and RAM
  bandwidth re-pickling the full state every 10s; only the *disk* cost is
  removed. Eliminating the re-pickle needs an upstream fix (see below).
- **Cap behavior:** the tmpfs is capped at 1 GiB (~5x the observed 198 MB). If
  the state exceeds it, `sync()` fails with `ENOSPC`; `_flush_loop` has no
  `try/except`, so its daemon thread dies loudly and further persistence stops,
  with no disk wear. Raise the size for very long engagements.

## Alternatives considered

- **Disable file persistence via `disable_persistence` / the env var.** Rejected
  as the fix (kept only as a forward-compatible signal): proven non-functional
  through `langgraph dev` in langgraph-cli 0.4.29 / langgraph-api 0.10.0, because
  the config validator strips the key and `run_server` overwrites the env var in
  the worker (evidence above). This is an upstream defect; the clean long-term
  fix is to get upstream to honor the switch (or to plumb it correctly), at which
  point the flag we already set takes over from the tmpfs.
- **A real Postgres checkpointer on the stack's existing Postgres.** Rejected:
  `langgraph dev` cannot use it; the Postgres runtime needs
  `LANGGRAPH_RUNTIME_EDITION=postgres`, the separate `langgraph-runtime-postgres`
  package, Redis, and a migrations path, i.e. abandoning `langgraph dev`. Far
  larger and riskier than the disk problem warrants; the box does not need
  durable cross-restart run history.
- **Throttle the flush interval.** Rejected: `_flush_interval` is a hardcoded
  module constant with no env or config knob, and a longer interval still
  re-pickles the full unbounded blob.
- **A custom container entrypoint that calls `run_server(disable_persistence=True)`
  directly, bypassing the broken config path.** Rejected: it would have to
  replicate `langgraph dev`'s config loading, graph resolution, and the fork's
  `--no-reload` / `--allow-blocking` handling, and would re-break on every
  upstream bump. The tmpfs is version-independent.

## See also

- [/CHANGELOG.md](../../CHANGELOG.md) - the fork's Unreleased entry for this fix.
- `docs/adr/0006-agent-driven-container-lifecycle.md` - the broader
  compose/runtime lifecycle this service lives in.
