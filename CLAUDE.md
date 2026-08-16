# CLAUDE.md — how we work in this fork

> The contributor + agent guide for **this fork** of Decepticon. The
> [README](README.md) is what it is and how to run it; [ARCHITECTURE.md](ARCHITECTURE.md)
> is how it works internally; this file is how *we* work on it here.
>
> For upstream's own AI-assisted-contribution charter and code-review flow, see
> [CONTRIBUTING_AGENT.md](CONTRIBUTING_AGENT.md), [CONTRIBUTING.md](CONTRIBUTING.md),
> and [docs/contributing.md](docs/contributing.md) — this file does not replace
> them, it layers the fork's own conventions on top.

---

## What this fork is

This is a **personal red-team fork** of [PurpleAILAB/Decepticon](https://github.com/PurpleAILAB/Decepticon),
maintained by Alex (Exploitacious) for Umbrella IT Group and personal use. It
runs on a dedicated Kali attacker box and is used for red-team work and light,
authorized, automated pentests for ourselves and our clients.

**We do not contribute upstream.** This fork is our own; we shape it to our
needs. We *do* pull interesting fixes/features from upstream selectively, when
we want them — see [Tracking upstream](#tracking-upstream).

Fork identity in the tracked files (README badges, installer `REPO` variable,
the `decepticon-scan` action author, `decepticon.red` links) is **deliberately
left pointing at upstream for now** — rebranding those guarantees a merge
conflict on every upstream pull, and we get no value from it while the fork is
private. Ownership is recorded here and in [ARCHITECTURE.md](ARCHITECTURE.md)
instead. Revisit if the fork ever goes public under our own name.

---

## The project kata

This fork follows Alex's project kata (the portable repo-shape system). The six
rules that matter:

1. **The root holds canonical entry points only** — four docs: `README.md` (what
   exists), `ARCHITECTURE.md` (the spec/how-it-works), `CLAUDE.md` (how we work),
   `CHANGELOG.md` (history). Tool-convention files get a documented exception (see
   below). Any *new* root file needs a positive justification recorded here.
2. **`docs/` holds every deep-dive**, indexed by [`docs/README.md`](docs/README.md).
   Every doc opens with a one-line "what this is" and ends with a "see also".
3. **Component docs live next to their code** (`packages/*/README.md`,
   `clients/*/`, `benchmark/*/README.md`).
4. **No fact lives in two places** — cross-link by anchor instead of copying.
   `ARCHITECTURE.md` is the source of truth for how it works; `README.md` for the
   surface; the docs defer to both.
5. **Drift is a bug.** A change that touches a documented surface updates the doc
   in the same commit. When code and docs disagree, **code wins** and the doc is
   fixed. Known outstanding drift is tracked in
   [ARCHITECTURE.md § Known documentation drift](ARCHITECTURE.md#known-documentation-drift).
6. **Soft cap on file length** (~500 lines) — except the spec (`ARCHITECTURE.md`),
   which is allowed to be long because it *is* the spec.

### Documented root exceptions

These stay at root even though they aren't the canonical four, because a tool,
platform, or runtime string expects them there:

- `LICENSE`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `.github/`
  — GitHub community/health files.
- `TELEMETRY.md` — a runtime CLI string prints "See TELEMETRY.md"; moving it is a
  code change, not a doc move.
- `THIRD_PARTY_LICENSES.md` — attribution file, kept next to `LICENSE`.
- `CONTRIBUTING_AGENT.md` — the AI-contribution charter, referenced from the PR
  template and several ADRs.
- `README_KO.md` — the Korean README, paired with `README.md`.

Everything else that was previously loose at root has moved under `docs/` (e.g.
`RELEASE.md` → `docs/release.md`), or been removed if orphaned (the completed
`SPEC.md`).

---

## Running it on this box

The operational specifics of this box (VM details, the real `.env`, credentials,
disaster recovery) live in the **private** COWORK context, not in this public-fork
repo: `CONTEXT/projects/decepticon-lessons.md` and `CONTEXT/machines.md`. The
portable essentials:

- **Two directories.** `~/Decepticon` is this fork (all container images are
  **built from this checkout**). `~/.decepticon` is the compose home — it symlinks
  `docker-compose.yml`/`config/`/`containers/` back into the fork, and holds the
  *real* `.env`, `workspace/`, and `telemetry/` as local files. **Code lives in
  the fork; state lives in `~/.decepticon`.** A rebuild never touches
  `.env`/`workspace`/volumes.
- **We run without the OSS launcher** — plain `docker compose --profile cli` from
  `~/.decepticon`. That means images build from source (see
  [ARCHITECTURE.md § Launching the stack](ARCHITECTURE.md#launching-the-stack)).
- **`AUTO_UPDATE=false`** — never let it pull GHCR images; that would clobber the
  fork-built ones. Updates come from a rebuild only.
- **LLM: GLM 5.3 via OpenCode Go.** `DECEPTICON_AUTH_PRIORITY=custom_openai_api`,
  model `custom/glm-5.3` on `https://opencode.ai/zen/go/v1`, served by the LiteLLM
  proxy on `127.0.0.1:4000` (`reasoning_effort: max`, cost pinned `$0`). Full
  routing detail in
  [ARCHITECTURE.md § LLM routing](ARCHITECTURE.md#llm-routing--model-tiers).

### Rebuild loop

After changing the fork, rebuild + redeploy with `scripts/refresh.sh`:

```bash
./scripts/refresh.sh            # git pull + rebuild changed images + restart stack
./scripts/refresh.sh --no-pull  # build local uncommitted changes
./scripts/refresh.sh --force    # full no-cache rebuild (slow)
```

It never touches `~/.decepticon/.env`, `workspace/`, `telemetry/`, or the
postgres/neo4j volumes. Health check after a refresh:

```bash
curl -sS http://127.0.0.1:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-decepticon-master' \
  -H 'Content-Type: application/json' \
  -d '{"model":"custom/glm-5.3","messages":[{"role":"user","content":"ping"}],"max_tokens":50}'
```

---

## Dev workflow

- **Branch, don't commit to `main` directly.** Feature branches; merge when green.
- **Conventional Commits** (`type(scope): summary`), imperative, ~50 chars.
  **No AI attribution** in commit messages (no "Co-authored-by", no generated-with
  trailers).
- **Update docs in the same change** that touches a documented surface (kata Rule 5).
- **Local dev loops** (`Makefile`): `make dogfood` (full launcher UX on local
  code), `make dev` (compose-watch hot-reload), `make smoke` (compose-only build →
  up → health), `make infra` (backend only), `make test` / `make lint` /
  `make quality`.
- **Where new files go**: read the kata above. New deep-dive doc → `docs/` + an
  index row in `docs/README.md` + a "see also" footer. Component note → next to
  the code. Almost never a new root file.

---

## Tracking upstream

Upstream is configured as a fetch-only remote (push is disabled):

```bash
git remote -v
# origin    https://github.com/Exploitacious/Decepticon.git (fetch/push)
# upstream  https://github.com/PurpleAILAB/Decepticon.git   (fetch)
# upstream  DISABLE_NO_PUSH_TO_UPSTREAM                      (push)
```

To pull an interesting upstream change **when we want it** (not on a schedule):

```bash
git fetch upstream
git log --oneline main..upstream/main     # see what's new upstream
# cherry-pick specific commits we want:
git cherry-pick <sha>
# or review a range and take a subset
```

We deliberately do **not** merge `upstream/main` wholesale — full merges would
fight our fork's own doc reshape and conventions. Cherry-pick the specific fixes
or features that make sense, resolve conflicts in our favor (our kata shape
wins), and note anything notable in `CHANGELOG.md`.

### Upstream watch

Things we want from upstream but are **not** building ourselves — pull them down
when they land rather than diverging the core to build our own. Check with
`git fetch upstream && git log --oneline main..upstream/main`.

| Want | Why | Where it lands | On arrival |
|---|---|---|---|
| **Phase-2 plugin-contribution aggregator** — wire the typed `ToolContribution` / `MiddlewareContribution` / `PromptContribution` / `SubAgentContribution` into `plugin_loader._discover` so they're actually consumed (today only `SafetyDeclaration` is). | Cleaner, typed, per-role plugin API than the current `PluginBundle` grab-bag. No capability gap — `PluginBundle` + entry-points already do everything today, so this is ergonomics, not a blocker. | `packages/decepticon-core/decepticon_core/plugin_loader.py`, `packages/decepticon/decepticon/agents/build.py`, `contracts/` | Cherry-pick the commits, rebuild, note in `CHANGELOG.md`. |

Rule of thumb: if a want here would force edits to the deep core files
(`plugin_loader.py`, `agents/build.py`, `contracts/`), prefer waiting for
upstream over building it — those are the hardest to reconcile on a later pull.
Build it ourselves only when a real need can't wait.

---

## See also

- [README.md](README.md) — what Decepticon is + how to run it.
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the harness works, end to end.
- [docs/README.md](docs/README.md) — deep-dive index.
- [CONTRIBUTING_AGENT.md](CONTRIBUTING_AGENT.md) — upstream's AI-contribution charter.
- `CONTEXT/projects/decepticon-lessons.md` (private COWORK) — this box's ops runbook.
