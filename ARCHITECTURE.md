# Decepticon Architecture

> How the Decepticon harness actually works, end to end — the container
> topology, the agent framework, the LLM gateway, the security model, and the
> surfaces you extend. This is the authoritative "how it works" reference; the
> [README](README.md) is the "what it is / how to run it" front door, and
> [CLAUDE.md](CLAUDE.md) is "how we work in this fork."
>
> Everything here is verified against the code in this checkout. Where a
> `docs/` deep-dive contradicts the code, the code wins and this file follows
> the code — the stale doc is flagged in [Known documentation drift](#known-documentation-drift).
> File:line citations point at the source of truth so you can re-verify.

---

## Contents

- [The 10,000-foot view](#the-10000-foot-view)
- [Runtime & infrastructure](#runtime--infrastructure)
  - [Docker topology: two networks](#docker-topology-two-networks)
  - [The service inventory](#the-service-inventory)
  - [How the sandbox is reached (HTTP, not the docker socket)](#how-the-sandbox-is-reached-http-not-the-docker-socket)
  - [The opscontrol bridge](#the-opscontrol-bridge)
- [Launching the stack](#launching-the-stack)
- [Security model & trust planes](#security-model--trust-planes)
- [The agent framework](#the-agent-framework)
  - [Three packages](#three-packages)
  - [Agent catalog](#agent-catalog)
  - [The agent-factory pattern](#the-agent-factory-pattern)
  - [Middleware](#middleware)
  - [Tools & the sandbox client](#tools--the-sandbox-client)
- [LLM routing & model tiers](#llm-routing--model-tiers)
- [Skills: the two catalogs](#skills-the-two-catalogs)
- [Knowledge graph & data stores](#knowledge-graph--data-stores)
- [Clients](#clients)
- [Benchmarking](#benchmarking)
- [CI & quality tooling](#ci--quality-tooling)
- [Telemetry](#telemetry)
- [Extending Decepticon](#extending-decepticon)
- [Repository layout](#repository-layout)
- [Known documentation drift](#known-documentation-drift)
- [See also](#see-also)

---

## The 10,000-foot view

Decepticon is an autonomous red-team harness. An LLM-driven orchestrator reads
an engagement package (Rules of Engagement, ConOps, OPPLAN) and delegates a real
kill chain — recon, exploitation, post-exploitation, lateral movement, C2 — to a
roster of specialist sub-agents, each of which runs its own commands inside an
isolated Kali sandbox and records findings to a shared attack graph.

The whole system runs as a Docker Compose stack split across **two networks**: a
management plane that holds the brains (the LLM gateway, the orchestrator
runtime, the databases) and an operational plane that holds the weapons (the
Kali sandbox, the C2 server, target infrastructure). Agents never touch a
provider API key or the host Docker socket directly; every model call goes
through one LiteLLM proxy, and every sandbox command goes over an HTTP daemon.
That separation is the spine of the security model.

You interact with it three ways: a terminal CLI (the default), a web dashboard
(spawned on demand), or as a Python library/SDK embedded in your own product.

---

## Runtime & infrastructure

### Docker topology: two networks

Two bridge networks are declared in `docker-compose.yml`:

- **`decepticon-net`** — the management plane. Carries `litellm`, `postgres`,
  `web`, `cli`, `skillogy`, and the BloodHound stack (`bhce`, `bhce-neo4j`,
  `bhce-postgres-init`).
- **`sandbox-net`** — the operational plane. Carries `sandbox` (Kali),
  `c2-sliver`, and `ghidra-mcp`.

Exactly two services are **dual-homed** — attached to both networks — and this
is enforced as an invariant, not left to convention. `tests/test_compose_network_isolation.py`
hard-codes `DUAL_HOMED_SERVICES = {"neo4j", "langgraph"}` and fails CI if a
third service ever joins both nets without an explicit test update.

- **`neo4j`** is the bridge for data: the sandbox writes attack-graph findings
  over Bolt from inside Kali, and the orchestrator reads them back from the
  management side. APOC is installed but deliberately hardened — its file-I/O
  and cross-database procedure families are stripped and replaced with an
  allowlist (`docker-compose.yml`) specifically to stop a
  `CALL apoc.cypher.runFile('file:///proc/self/environ')`-style pivot from a
  sandbox compromise into management-plane secrets.
- **`langgraph`** is the bridge for control: it needs `decepticon-net` to reach
  `litellm:4000` and `postgres:5432`, and it needs `sandbox-net` to reach the
  sandbox's HTTP daemon on `sandbox:9999`.

All host-published ports bind to `127.0.0.1` only.

```
                          ┌─────────────────────────────────────────────┐
   operator (host) ──┐    │              decepticon-net                 │
                     │    │  litellm:4000   postgres:5432   web:3000    │
   CLI / dashboard ──┼───▶│  skillogy:9100  bhce:8081                   │
                     │    │                                             │
                     │    │        ┌──────────┐        ┌──────────┐     │
                     │    │        │ langgraph│◀──────▶│  neo4j   │     │  ← dual-homed
                     │    │        │  :2024   │        │7687/7474 │     │
                     │    └────────┤          ├────────┤          ├─────┘
                     │             │          │        │          │
                     │    ┌────────┤          ├────────┤          ├─────┐
                     │    │        └────┬─────┘        └──────────┘     │
                     │    │             │ HTTP :9999                    │
                     │    │        ┌────▼─────┐   ┌───────────┐         │
                     │    │        │ sandbox  │   │ c2-sliver │  ...    │
                     │    │        │  (Kali)  │   │           │ targets │
                     │    │              sandbox-net                    │
                     │    └─────────────────────────────────────────────┘
                     │
                     └── opscontrol UDS (host daemon) ── starts/stops specialist workloads
```

### The service inventory

Every service declares both an `image:` (a GHCR tag, `ghcr.io/purpleailab/decepticon-*:${DECEPTICON_VERSION:-stable}`)
and a `build:` block, so a plain `docker compose up` builds from source while
the launcher pulls tagged images.

| Service | Purpose | Host port (127.0.0.1) | Network(s) | Profile |
|---|---|---|---|---|
| `litellm` | Central LLM gateway (LiteLLM proxy) | `4000` | decepticon-net | default |
| `postgres` | LiteLLM keys/spend + web DB + BloodHound DB | `5432` | decepticon-net | default |
| `neo4j` | Attack-chain knowledge graph (KGStore) | `7474`, `7687` | **both** | default |
| `langgraph` | Agent runtime (LangGraph Platform) | `2024` | **both** | default |
| `sandbox` | Kali execution sandbox (FastAPI daemon) | none | sandbox-net | default |
| `skillogy` | Graph-backed skill catalog service | `9100` | decepticon-net | default |
| `cli` | Terminal client (Ink) | none (tty) | decepticon-net | `cli` |
| `web` | Next.js dashboard + in-browser terminal | `3000`, `3003` | decepticon-net | `web` |
| `c2-sliver` | Sliver C2 server | none (443/53/8888 exposed, unmapped) | sandbox-net | `c2-sliver` |
| `ghidra-mcp` | Ghidra reversing MCP server | none | sandbox-net | `reversing` |
| `bhce` + `bhce-neo4j` + `bhce-postgres-init` | BloodHound Community Edition | `8081` | decepticon-net | `ad` |

Persistent named volumes: `postgres_data`, `neo4j_data`/`neo4j_logs`,
`sliver_data`, `bhce_neo4j_data`/`bhce_neo4j_logs`. The sandbox and web instead
bind-mount host paths under `${DECEPTICON_HOME}` — notably the per-engagement
`${DECEPTICON_ENGAGEMENT_WORKSPACE}`, so the sandbox only ever sees one
engagement's files, and `${DECEPTICON_HOME}/telemetry` for a stable install id
that survives image updates.

Credentials reach the containers via `env_file: .env` on `litellm` and
`langgraph`; a handful of infra knobs (`LITELLM_MASTER_KEY`, `POSTGRES_PASSWORD`,
`NEO4J_PASSWORD`, port overrides) are interpolated with `${VAR:-default}`
fallbacks. The shipped fallbacks (`sk-decepticon-master` / `decepticon`) are
dev-only — the launcher **refuses to start** if they're left at default
(`clients/launcher/cmd/start.go`, `checkDefaultCredentials`); a bare
`docker compose up` has no such guard.

### How the sandbox is reached (HTTP, not the docker socket)

This is the single most important — and most mis-documented — fact about the
runtime. **The orchestrator does not `docker exec` into the sandbox.** The old
`DockerSandbox` transport, which required bind-mounting `/var/run/docker.sock`
into the agent container, was removed because it was a host-escape vector for
prompt-injection-driven RCE.

Today the Kali sandbox runs a FastAPI daemon (`python -m decepticon.sandbox_server`,
`containers/sandbox-entrypoint.sh`) on `localhost:9999` inside its container.
`langgraph` (dual-homed) talks to it as `HTTPSandbox` over `sandbox:9999`
(`packages/decepticon/decepticon/backends/http_sandbox.py`,
`backends/factory.py`). The network-isolation test asserts that **no** service
except `cli` mounts the docker socket — and `cli` only does so for the operator's
`/web` slash command, never for agent code.

### The opscontrol bridge

Specialist workloads (Sliver C2, BloodHound/`ad`, reversing) are not up by
default; the orchestrator brings them up on demand with `ops_start("ad")` etc.
That is done through a second, deliberately narrow bridge that lives **outside**
`docker-compose.yml`: the Go launcher writes a compose overlay
(`docker-compose.opscontrol.yml`) that bind-mounts a host Unix-domain socket
into the `langgraph` container only. A host-side daemon serves a tiny HTTP API
over that socket and shells out to `docker compose --profile <workload> up`
against a **fixed allowlist** of workload names
(`clients/launcher/internal/opscontrol/allowlist.go`: `ad, c2-sliver, c2-havoc,
reversing, phishing, mobile, wireless, cloud, iot, ics, forensics,
supply-chain`) — never an arbitrary profile or raw `docker run`. The design
rationale (ADR-0006) is that the host daemon, not the agent container, is the
only process that ever touches host Docker. A plain `docker compose up` (no
launcher) never gets this overlay, so `ops_*` tool calls degrade to a "daemon
unreachable" diagnostic instead of failing boot.

---

## Launching the stack

There are two ways the stack comes up, and they are not equivalent.

**The Go launcher (`decepticon start`, `clients/launcher/`)** is the supported
path and does much more than compose:

1. Runs the onboarding wizard if `.env` is absent, and migrates stale `.env` keys.
2. Verifies Docker + Compose v2 are present.
3. Syncs `docker-compose.yml`/`config/`/`.env.example` into `~/.decepticon` if missing.
4. Wires host OAuth credential files (`~/.claude/.credentials.json`,
   `~/.codex/auth.json`) into the volume-mount env vars the compose file consumes.
5. Runs the self-update check per `AUTO_UPDATE` (unset/`true` = silent apply +
   re-exec; `prompt`/`ask` = interactive on a TTY; `false` = skip).
6. Runs the engagement picker **before** compose up, so the sandbox workspace
   mount is scoped from first boot.
7. Starts (or attaches to) the opscontrol host daemon.
8. Refuses default credentials.
9. Runs `docker compose --profile cli up -d --no-build --wait` — the launcher
   **never builds**, it only pulls tagged images.

**Plain `docker compose up`** skips every one of those steps: no onboarding, no
credential wiring, no engagement scoping, no opscontrol overlay, and — because
each service has a `build:` block — it will **build from source** any image not
present locally. This is exactly what the Umbrella fork does deliberately (see
[CLAUDE.md](CLAUDE.md)): the local checkout is the source of truth, so images are
built from it and `AUTO_UPDATE=false`.

**Makefile targets** codify the from-source paths: `make dogfood` (full launcher
UX on local code, isolated `.dogfood` home), `make smoke` (compose-only build →
up → health), `make dev` (compose-watch hot-reload of the Python packages),
`make infra` (backend only, for local-Node client dev).

**Release channels** (`docs/update-channels.md`): `DECEPTICON_CHANNEL` selects
`stable` (default, 7-day soak) vs `latest`; both are final-release-only. A
separate release-time mechanism (`.github/workflows/pin-digests.yml`) publishes
an `image-digests.txt` so operators can hard-pin images to a `@sha256:` digest
instead of the moving tag.

---

## Security model & trust planes

`docs/security/decepticon-threat-model.md` defines three trust planes:

- **Operator** — the host, API keys, OAuth tokens, `.env`.
- **Management** — everything on `decepticon-net` (langgraph, litellm, postgres,
  neo4j, web).
- **Operational** — everything on `sandbox-net` (Kali sandbox, Sliver, targets).

Bridges between planes are the highest-impact compromise paths, ranked by blast
radius: Neo4j dual-homing (Cypher/APOC) → LiteLLM (OAuth files + provider keys)
→ plugin entry-points (arbitrary Python on `import decepticon`) → the web
dashboard → and (added since the threat model was written) the opscontrol
socket.

Because this is a tool that **runs live attacks from inside itself**, the
sandboxing is layered:

- **Container hardening**: the Kali container runs as root (raw sockets / SYN
  scans need it) but with `cap_drop: ALL` then a minimal `cap_add` re-list,
  `no-new-privileges: true`, `mem_limit`, `pids_limit`, and `init: true` (tini
  reaps zombie tmux/bash grandchildren). The container boundary — not file
  permissions — is the security boundary (`/workspace` is world-writable by
  design).
- **Transport hardening**: the HTTP-only sandbox transport (above) removed the
  docker-socket escape path entirely.
- **Prompt-injection defenses above the boundary**: `UntrustedOutputMiddleware`
  wraps every attacker-influenceable tool return in a quarantine envelope, and
  `PromptInjectionShieldMiddleware` scans hostile output before the model sees
  it. RoE scope enforcement gates every bash call.

Six middleware slots are marked **safety-critical** (`ENGAGEMENT_CONTEXT`,
`ROE_GUARDRAIL`, `UNTRUSTED_OUTPUT`, `PROMPT_INJECTION_SHIELD`,
`SANDBOX_NOTIFICATION`, `OPSCONTROL_NOTIFICATION`, plus `HITL_APPROVAL`): a
plugin can only replace or disable them when `DECEPTICON_ALLOW_SAFETY_OVERRIDES=1`
is set, enforced by `_check_safety_gate` in `agents/build.py`, which raises
`SafetyOverrideViolation` otherwise.

---

## The agent framework

### Three packages

The Python runtime is split into three packages under `packages/`, layered
contract → framework → SDK:

- **`decepticon-core`** — the pure contract layer. Its only dependencies are
  `pydantic`/`pydantic-settings`/`typing-extensions`; it has **no** langchain,
  langgraph, deepagents, httpx, or fastapi. This is enforced by a test
  (`test_no_runtime_deps.py`) that imports every submodule in a fresh subprocess
  and fails if any runtime library ends up in `sys.modules`. It holds: the
  plugin contribution dataclasses + the `MiddlewareSlot` enum (`contracts/`),
  seven `@runtime_checkable` protocols (`protocols/`), the registries
  (`PluginRegistry`, `RoleRegistry`, `SafetyRegistry`, `SkillSourceRegistry`),
  the typed models (`types/`: engagement, llm, kg, roe), and the entry-point
  discovery (`plugin_loader.py`).
- **`decepticon`** — the opinionated framework built on core. Adds
  langchain/langgraph/deepagents/httpx/fastapi. Carries the agent factories,
  the middleware, the tool library, the LLM router/factory, the sandbox HTTP
  client, and the skill catalogs.
- **`decepticon-sdk`** — the plugin-author entrypoint. Re-exports the full core
  public surface under one import path, ships protocol-conformant test fakes
  (`FakeBackend`, `FakeLLM`, `FakeSandbox` in `decepticon_sdk.testing`), and
  provides the scaffolding CLI `decepticon-sdk plugin new --kind={tool,
  middleware, agent, callback, skill, prompt}`.

Dependency direction is strictly `decepticon → decepticon-core ← decepticon-sdk`;
core depends on neither.

> **Verified counts** (the package READMEs still say "16 agent factories, 11
> middleware" — that is stale, see [drift](#known-documentation-drift)). Actual:
> **25 agent factories** (19 in the standard bundle incl. the orchestrator, 6 in
> the plugins bundle), and **16 middleware classes** (13 exported from the public
> `__init__.py`, 3 internal-only).

### Agent catalog

`langgraph.json` registers 19 graphs, each mapping to
`packages/decepticon/decepticon/agents/standard/<name>.py:graph`:

| Graph | Role |
|---|---|
| `decepticon` | Orchestrator — builds the OPPLAN and delegates the kill chain via `task()`; carries no offensive tools of its own |
| `soundwave` | Standalone planning/interview assistant that writes the RoE/ConOps/OPPLAN docs; fresh engagements route here first |
| `recon` | Reconnaissance, OSINT, enumeration |
| `exploit` | Exploitation specialist (bash-executing) |
| `postexploit` | Post-exploitation specialist (bash-executing) |
| `analyst` | Research, graph-querying, executive summaries (KG-wired) |
| `reverser` | Static/dynamic binary analysis, decompilation |
| `contract_auditor` | Solidity / smart-contract auditing (KG-wired) |
| `cloud_hunter` | Cloud IAM escalation, storage attacks, metadata abuse |
| `ad_operator` | Active Directory attacks (Kerberoast, PtH, BloodHound, DCSync) (KG-wired) |
| `blue_cell` | Read-only detection-coverage specialist (defensive) |
| `phisher` | Phishing operations and lure deconfliction |
| `mobile_operator` | Android/iOS application attacks |
| `wireless_operator` | Wireless / RF attacks |
| `osint_operator` | OSINT specialist |
| `iot_operator` | IoT device attacks |
| `ics_operator` | ICS/OT attacks |
| `forensicator` | DFIR specialist |
| `supply_chain_operator` | Supply-chain attack specialist |

An opt-in **plugins bundle** (`DECEPTICON_PLUGINS=standard,plugins`) adds 6 more
under `agents/plugins/`: `vulnresearch` (orchestrator) + `scanner`, `detector`,
`verifier`, `patcher`, `exploiter` — a five-stage vulnerability-research
pipeline.

### The agent-factory pattern

Every graph is produced by a factory (`create_recon_agent`,
`create_decepticon_agent`, …) that takes `backend, llm, fallback_models,
sandbox/subagents, tools, middleware, system_prompt, recursion_limit` — all
optional. When a kwarg is `None`, the factory builds the OSS baseline via two
shared helpers in `agents/build.py` (`build_tools`, `build_middleware`), both of
which also query plugin entry-points for overrides. Passing an explicit value
for any surface fully replaces the baseline for that surface — this is the
"library composer" escape hatch. The factory then calls
`langchain.agents.create_agent(...)`, which compiles the LangGraph; the
module-level `graph = create_*_agent()` (guarded by `is_bundle_enabled("standard")`)
is what `langgraph.json` exposes.

Delegation uses `deepagents`: the orchestrator discovers every `SubAgentSpec`
whose `parent_agents` includes `"decepticon"`, wraps each compiled sub-agent so
its tool calls stream through both the CLI and the LangGraph HTTP API, and hands
them to `deepagents`' `SubAgentMiddleware`.

Each agent's middleware stack is assembled by walking the canonically-ordered
`MiddlewareSlot` enum, filtered per-role by `SLOTS_PER_ROLE` (25 role entries in
`decepticon_core/contracts/slots.py`).

### Middleware

16 middleware classes live under `decepticon/middleware/` (13 exported):

| Middleware | What it does |
|---|---|
| `EngagementContextMiddleware` | Injects engagement metadata (slug, target, RoE) each turn |
| `RoEGuardrailMiddleware` | Command-parse RoE gate: PASS / WARN / BLOCK per bash call |
| `HITLApprovalMiddleware` | Human-in-the-loop approval for high-impact actions |
| `UntrustedOutputMiddleware` | Quarantine-wraps attacker-influenceable tool output |
| `PromptInjectionShieldMiddleware` | Scans hostile output for injection payloads |
| `SkillsMiddleware` | Legacy text-matching skill catalog |
| `SkillogyMiddleware` | Graph-backed skill discovery (opt-in) |
| `FilesystemMiddleware` | File ops scoped to the engagement workspace |
| `OPPLANMiddleware` | OPPLAN CRUD + live objective-status injection |
| `KGMiddleware` | Owns the Neo4j attack graph; `kg_*` tools (analyst/ad/contract roles) |
| `EventLogMiddleware` | Persists engagement events to `events.jsonl` |
| `SandboxNotificationMiddleware` | Injects background-tmux-job completion diffs |
| `BudgetEnforcementMiddleware` | Per-engagement / per-agent USD spend caps |
| `OpsControlNotificationMiddleware`* | Orchestrator-only `ops_*` state transitions |
| `ModelOverrideMiddleware`* | Runtime `/model` switch support |
| `ProxyKeyOverrideMiddleware`* | Per-run LiteLLM virtual-key swap |

`*` = internal-only, not exported from `__init__.py`. `deepagents` supplies
additional stack members (`SubAgentMiddleware`, `ModelFallbackMiddleware`,
summarization, Anthropic prompt caching, dangling-tool-call repair).

### Tools & the sandbox client

Tools live under `decepticon/tools/` in 17 subdirectories (`ad, bash, browser,
cloud, contracts, defense, evidence, interaction, mcp, network, ops, proxy,
references, reporting, research, reversing, web`) — **143** `@tool`-decorated
callables in total. They are assembled per-role by `build_tools()` layering OSS
baseline → explicit overrides → plugin-contributed tools → disabled-name filter.
Every bash-executing specialist gets `[bash, bash_output, bash_kill, bash_status]`.

The sandbox client is `HTTPSandbox` (`backends/http_sandbox.py`), a deepagents
`BaseSandbox` subclass that forwards `execute`, `execute_tmux`,
`start_background`, `poll_completion`, `read_session_log_diff`, upload/download,
etc. over HTTP to the in-sandbox FastAPI daemon. `backends/factory.py` resolves
the endpoint (run config → LangGraph contextvar → `SANDBOX_URL` env, default
`http://localhost:9999`) and caches one client per `(url, token)`. The composite
backend routes `/skills/` to an in-process filesystem backend and everything else
(notably `/workspace/`) through the HTTP transport.

---

## LLM routing & model tiers

### The LiteLLM gateway

Every model call leaves the agent runtime as an OpenAI-shaped request to a single
LiteLLM proxy (default `http://localhost:4000`, local-dev key
`sk-decepticon-master`). The proxy is the one place that knows real provider
endpoints, credentials, and cost. Agents hold only a LiteLLM model id (e.g.
`anthropic/claude-opus-4-8`, `custom/glm-5.3`); the proxy resolves it via the
routes in `config/litellm.yaml`. `LLMFactory` builds each agent's client against
the proxy and wraps it as `_ProxiedChatOpenAI` so transport and upstream 4xx
errors become actionable messages.

### The auth-method system

Model selection is factored along three orthogonal axes: a power **Tier** (HIGH /
MID / LOW), an **AuthMethod** (a specific credential + route family), and a
**ModelProfile** (`eco`, `max`, `test`) that maps each role to a tier. An
AuthMethod is a credential, not a vendor — Anthropic has both `anthropic_api`
(key) and `anthropic_oauth` (subscription), configured and ordered independently.
Auth methods fall into four families, all terminating at the proxy:

- **Native provider routes** — LiteLLM's own prefixes (`anthropic/`, `openai/`,
  `gemini/`, `bedrock/`, `zai/`, …), authenticated with that provider's key.
- **OpenAI-compatible gateways** — reached through LiteLLM's `openai/` provider
  with an `api_base` override. `opencode` (`opencode.ai/zen/v1`) and
  `opencode_go` (`opencode.ai/zen/go/v1`) are two entries; the alias keeps the
  gateway's prefix (`opencode-go/glm-5.3`) so two gateways sharing an upstream
  slug never collide.
- **`custom_openai_api`** — the generic escape hatch for any OpenAI-compatible
  endpoint. Emits `custom/<CUSTOM_OPENAI_MODEL>` with base/key from
  `CUSTOM_OPENAI_API_BASE`/`CUSTOM_OPENAI_API_KEY`.
- **OAuth pass-through subscriptions** — Claude Code, ChatGPT/Codex, Copilot,
  Gemini, Grok, Perplexity — routed through custom LiteLLM handlers
  (`config/*_handler.py`) that exchange an on-disk token for a provider session.

### METHOD_MODELS and tier resolution

`METHOD_MODELS` (`decepticon_core/types/llm.py`) is the `(AuthMethod, Tier) →
model-id` matrix. `resolve_chain(tier, credentials)` walks the configured
methods in priority order and appends each method's model at the requested tier,
producing a primary-first fallback list; `ModelFallbackMiddleware` walks that
list when a primary fails. Endpoints whose model is chosen at runtime (Ollama, LM
Studio, llama.cpp, `custom_openai_api`) read a `*_MODEL` env var and drop out of
the chain entirely when unconfigured. Single-SKU gateways collapse all tiers to
one id — Cerebras is the canonical case, and OpenCode Go now follows it (all
tiers → `opencode-go/glm-5.3`).

Two operator knobs steer selection:

- **`DECEPTICON_AUTH_PRIORITY`** — comma-separated AuthMethod order (subscriptions
  before their paid-API peers, hosted before local). Unset uses
  `factory._DEFAULT_AUTH_PRIORITY`.
- **`DECEPTICON_MODEL_<ROLE>`** — overrides one role's primary model; the
  displaced tier default is pushed to the front of the fallbacks, so even a typo
  degrades to a vetted model.

### Current live GLM 5.3 configuration (this fork)

This fork runs entirely on **GLM 5.3 via the OpenCode Go subscription**
(`https://opencode.ai/zen/go/v1`, `reasoning_effort: max`, cost pinned `$0`
because the plan is flat, not per-token). Two intentional routes point at that
endpoint in `config/litellm.yaml`:

- **`custom/glm-5.3`** (keyed on `CUSTOM_OPENAI_API_KEY`) — what the
  `custom_openai_api` method emits, and the route the running proxy serves today
  (`DECEPTICON_AUTH_PRIORITY=custom_openai_api`). It is a **static** route because
  proxy-side dynamic registration of `CUSTOM_OPENAI_*` did not fire in the current
  image build.
- **`opencode-go/glm-5.3`** (keyed on `OPENCODE_GO_API_KEY`) — what the
  first-class `opencode_go_api` method emits at every tier; mirrors the same
  endpoint so the dedicated gateway method resolves to a real route.

The retired `opencode-go/glm-5.2`/`5.1`/`5` ids were removed from
`METHOD_MODELS`, the `/model` CLI catalog, and the routes. See
[decepticon-lessons.md](../../CONTEXT/projects/decepticon-lessons.md) (private
COWORK context) for the box-level `.env` and refresh procedure.

---

## Skills: the two catalogs

Two skill systems coexist, gated by a feature flag:

1. **Legacy `SkillsMiddleware`** (production default) — text-matching progressive
   disclosure over `SKILL.md` files shipped as package data under
   `decepticon/skills/**` (311 files). Three stages: frontmatter injected at boot
   → full body via `load_skill()` on demand → `references/` docs read as
   instructed. Roots: `/skills/standard/` (OSS roles), `/skills/plugins/` (plugin
   specialists), `/skills/shared/` (cross-cutting OPSEC/finding-format protocols).
   The schema is defined and CI-enforced in `docs/skill-schema.md`.
2. **Skillogy** (opt-in via `DECEPTICON_USE_SKILLOGY=1`) — a Neo4j-backed graph
   replacing text-matching autoload, motivated by tool-selection accuracy falling
   past ~100 tools. A standalone `skillogy` service container owns the Neo4j
   driver and serves agents over REST/gRPC; `SkillogyMiddleware` is a thin client
   exposing exactly **3** tools: `find_skill`, `load_skill`, `traverse`. The
   authoritative design is `docs/design/skillogy-brain-redesign.md` (v0.2);
   `docs/skillogy.md` and `docs/design/skillogy.md` are historical v0.1 drafts.

A third, unrelated thing also called a "skill": `integrations/agent-skills/decepticon/`
is an externally-facing Anthropic Agent Skill that teaches an *external* chat
agent how to **drive** a running Decepticon server over its `decepticon_*` MCP
tools. It is not part of the offensive catalog the agents consume.

---

## Knowledge graph & data stores

**PostgreSQL** runs three logical databases in one instance: `litellm` (virtual
keys, spend logs, budgets), `decepticon_web` (Prisma-managed dashboard data,
auto-created first-boot by `containers/postgres-init/01-create-web-db.sql`), and
`bloodhound` (idempotently ensured every boot by the `bhce-postgres-init`
sidecar, which needs the `pg_trgm` extension).

**Neo4j / KGStore** persists the cross-domain attack graph — hosts, services,
vulnerabilities, credentials, findings, and typed attack-chain relationships.
Agent-facing tools include `kg_add_node`, `kg_add_edge`, `kg_query`,
`kg_neighbors`, `kg_stats`, a family of `kg_ingest_*` parsers (SARIF, nmap XML,
nuclei JSONL, subfinder, httpx), and analysis tools (`kg_analyze_jwt`,
`kg_scan_solidity`, `kg_triage_binary`, …), all in `tools/research/tools.py`.
The runtime schema is applied by `middleware/kg_internal/migration_runner.py`
(ordered `V*.cypher` migrations recorded in a `:MigrationLog` node) — the static
`scripts/init_neo4j.cypher` is a manual bootstrap, not wired into any service.
`bhce-neo4j` is a **separate** Neo4j 4.4 instance solely for BloodHound.

Skillogy uses the same `neo4j` instance (different graph), rebuilt from the
checked-in `skills/.graph/skills.cypher` dump when empty.

---

## Clients

Four client surfaces plus a shared streaming package (npm workspaces), and one
Go module:

- **`clients/cli`** — the interactive terminal client (`@decepticon/cli`),
  TypeScript + React 19 + Ink 6, `@langchain/langgraph-sdk` to the backend
  (default `http://localhost:2024`). Slash commands (`/model`, `/web`, `/agent`,
  `/resume`, `/plugins`), Ink UI widgets, a Zustand-style store. This is the
  default UX.
- **`clients/desktop`** — an Electron shell. **Deprecated** (its own README says
  so): kept for existing users, will be removed. Supports a cloud-app mode
  (`DECEPTICON_DESKTOP_MODE=cloud|local|auto`).
- **`clients/web`** — the Next.js 16 / React 19 dashboard, Prisma 7 over
  PostgreSQL plus `neo4j-driver`, `@xyflow/react` (attack-graph canvas), and an
  in-browser terminal (`node-pty`/`xterm`/`ws`). Runs on `:3000` and a WebSocket
  terminal bridge on `:3003`. (Note: `clients/web/README.md` is still stock
  `create-next-app` boilerplate; `clients/web/LICENSE` has drifted from root
  LICENSE — see [drift](#known-documentation-drift).)
- **`clients/launcher`** — the Go binary (Charm TUI stack + Cobra) that owns
  onboarding + the full lifecycle (`start`, `stop`, `status`, `logs`, `health`,
  `update`, `remove`) and the opscontrol daemon.
- **`clients/shared/streaming`** — shared LangGraph streaming types/constants
  consumed by both cli and web.

---

## Benchmarking

The `benchmark/` package drives the full agent pipeline against external
CTF/vulnerability suites and produces per-run evidence plus an aggregate report.

**Five wired providers** (via `--provider`, dispatched in `benchmark/runner.py`,
each a `BaseBenchmarkProvider`): `xbow` (default; the 104-challenge XBOW
validation-benchmarks, a git submodule), `exploitbench` (ExploitBench V8
capability-graded environments), `mhbench` (multi-host network scenarios, git
submodule), `cybench` (Stanford Cybench, 40 pro-CTF tasks), `cybergym` (UC
Berkeley CyberGym CVE reproduction, ~1,500 tasks).

**Two independent sibling harnesses** (their own entry points, *not* reachable
via `--provider`): `benchmark/cve_bench/` (CVE-Bench, run via `make cve-bench-dry`;
only the offline dry-run has landed) and `benchmark/dreadgoad/` (AD attack range
on AWS, its own `BaseBenchmarkProvider`).

A run does `provider.setup()` (build/probe target) → drive a LangGraph thread and
poll to terminal (with cancel + verify-terminal discipline) → `provider.evaluate()`
(grep for `FLAG{...}`) → `provider.teardown()` (`docker compose down -v`).
Requires a LangGraph server started with `BENCHMARK_MODE=1`. Results land at
`benchmark/results/<challenge>/<timestamp>/`.

**Headline result**: 102/104 (**98.08%**) on XBOW validation, cycle-4 final (L1
100%, L2 98.0%, L3 87.5%), positioned #1 on the cross-project leaderboard in
`docs/benchmark-comparison.md`.

---

## CI & quality tooling

CI is deliberately consolidated (`docs/engineering/ci-arsenal.md`) after retiring
an 18-tool arsenal, into two workflows:

- **`ci.yml`** — five required checks: Python (ruff + basedpyright + pytest), CLI
  TypeScript typecheck+tests, Web ESLint + Next build, Go launcher (`go vet` +
  `go test`), and `actionlint`; plus Buildx + Trivy per image and `docker compose
  config` drift validation. Change-detected via `dorny/paths-filter`.
- **`security.yml`** — CodeQL (Python + JS/TS), Semgrep (repo rules, hard-gated on
  ERROR), Trivy, TruffleHog (`--only-verified`, hard gate), dependency-review.

Style/format/lint tools run **locally only** via `.pre-commit-config.yaml` (never
in CI): ruff + ruff-format, shellcheck, hadolint, typos, gitleaks, basedpyright.
Repo-specific Semgrep invariants live in `.semgrep/decepticon-rules.yml` (e.g.
`decepticon-no-shell-true-outside-sandbox`). Note: `.golangci.yml`,
`.yamllint.yaml`, and `.markdownlint.yaml*` at root are **orphaned** — nothing in
CI or pre-commit invokes them (see [drift](#known-documentation-drift)).

Other workflows: `release.yml` (tag → PyPI Trusted Publishing + signed/SBOM'd
images), `promote-stable.yml`, `pin-digests.yml`, `scorecard.yml`,
`todo-to-issue.yml`, and `security-scan-example.yml`.

**The `decepticon-scan` composite Action** (`.github/actions/decepticon-scan/`)
runs an autonomous red-team scan against the checked-out repo and emits SARIF
v2.1.0 for GitHub Code Scanning. Inputs: `target`, `scan-mode`
(`quick|standard|deep`), `scope-mode` (`full|diff`, diff-restricted for PR
gating), `fail-on` severity threshold, plus a free-form RoE `instruction`. If
`langgraph-url` is unset it stands up a local stack for the scan and tears it
down. Outputs `sarif-path`, `finding-count`, `exit-code`.

---

## Telemetry

Off by default (`DECEPTICON_TELEMETRY=off`; `DO_NOT_TRACK=1` and `BENCHMARK_MODE=1`
force it off). Two opt-in tiers: `basic` (event/agent/tool names, bucketed sizes,
token counts, structured finding fields like severity/CWE/MITRE — never the
finding's title/description/evidence) and `research` (adds the reasoning corpus
with target identifiers pattern-masked). Three defense layers before anything
leaves the machine: shape-only source redaction, a fail-closed client-side
Tier-C scanner that drops any event still matching IP/cred/host patterns, and a
gateway-side re-scan. The recipient is a maintainer-run Cloudflare Worker
(`telemetry-gateway/`) that drops client IP, validates the schema, re-scans,
rate-limits, and forwards to PostHog server-side — the OSS client never sees the
PostHog key. (`TELEMETRY.md` is kept at root because a runtime CLI string points
users to it by name.)

---

## Extending Decepticon

Two extension layers:

**Entry-point discovery** (mature, load-bearing). A third-party package populates
any of eight groups in its `pyproject.toml`: `decepticon.tools`,
`.middleware`, `.agents`, `.subagents`, `.callbacks`, `.skills`, `.prompts`,
`.roles` (plus `.bundles` for the override layer). A contribution can be a list
(additive), a factory, a bare instance, or a `PluginBundle` that can **replace**
or **disable** named tools/slots/prompts/sub-agents for a role set — the
replace/disable path is safety-gated (`SafetyOverrideViolation` without
`DECEPTICON_ALLOW_SAFETY_OVERRIDES=1`). Bundle activation is a 4-tier hierarchy:
`DECEPTICON_PLUGINS` env → `.decepticon.toml` → `pyproject.toml
[tool.decepticon.plugins]` → default `{"standard"}`.

**Typed Contribution API** (newer, mostly unwired). `decepticon-sdk` re-exports
`ToolContribution`, `MiddlewareContribution`, `PromptContribution`,
`SubAgentContribution`, `SafetyDeclaration`. Today only `SafetyDeclaration` is
actually consumed by the framework (`SafetyRegistry`); the other four are
validated dataclasses with no discovery path yet — a plugin author should use the
`PluginBundle` mechanism for tools/middleware/sub-agents.

**Runtime toggling** is exposed over HTTP by `plugins_api.py` (mounted via
`langgraph.json`'s `http.app`): `GET /_decepticon/bundles`, `POST
.../{name}/enable`, `POST .../{name}/disable` (refuses to disable `standard`).
Runtime-only — changes don't survive a restart.

**Author workflow**: `decepticon-sdk plugin new --kind=middleware --name=... --path=...`
scaffolds a buildable package wired to the right entry-point group; `uv build &&
pip install dist/*.whl`; the next agent-construction pass discovers it. Test with
`FakeBackend`/`FakeLLM`/`FakeSandbox` from `decepticon_sdk.testing`.

---

## Repository layout

This fork follows the project kata: the root holds only the four canonical
documentation files plus tool-convention exceptions.

**Canonical root docs**

| File | Role |
|---|---|
| `README.md` | What Decepticon is + how to run it |
| `ARCHITECTURE.md` | How it works (this file) — the spec/rulebook slot |
| `CLAUDE.md` | How we work in this fork |
| `CHANGELOG.md` | Every merged change (Keep a Changelog) |

**Documented kata exceptions kept at root** (tools/platform expect them there, or
they are referenced by name from code):

- `LICENSE`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `.github/`
  — GitHub-recognized community/health files.
- `TELEMETRY.md` — a runtime CLI string prints "See TELEMETRY.md"; moving it
  would require a code change.
- `THIRD_PARTY_LICENSES.md` — kept next to `LICENSE` by attribution convention.
- `CONTRIBUTING_AGENT.md` — the AI-contribution charter, referenced from the PR
  template and multiple ADRs.
- `README_KO.md` — the Korean README, paired with `README.md` via the
  language-toggle badges.

**Deep-dive docs** live under `docs/`, indexed by [`docs/README.md`](docs/README.md).
Component docs live next to their code (`packages/*/README.md`, `clients/*/`,
`benchmark/*/README.md`). See [CLAUDE.md](CLAUDE.md) for the full kata rules and
the fork's conventions.

---

## Known documentation drift

Caught during the fork's documentation pass; code is the source of truth. Fixed
in this pass where cheap; the rest are tracked here so they aren't mistaken for
current fact.

**Fixed in this pass:**

- README "16 specialist agents" and the docker-socket sandbox description —
  corrected to the HTTP transport and the real roster.
- `docs/skillogy.md` pointer that led to a superseded design doc — repointed to
  `docs/design/skillogy-brain-redesign.md`.
- The dead `opencode-go/glm-5.x` model ids — retired everywhere.

**Tracked, not yet fixed** (code-internal or low-value churn):

- `packages/*/README.md`, `contracts/slots.py`, `agents/build.py`, and
  `plugins_api.py` still say "16 agent factories" / "11 middleware" / "9
  specialists". Verified reality: 25 factories, 16 middleware, 18 standard
  specialists.
- `docs/architecture.md` describes the retired docker-socket transport as
  current throughout — this file supersedes it; that doc needs a rewrite.
- `docs/knowledge-graph.md` lists `kg_create_node`/`kg_query_paths`-style tool
  names that don't match the shipped `kg_add_node`/`kg_query` API.
- `docs/superpowers/specs/2026-05-23-core-framework-sdk-split-design.md` is cited
  by all three package READMEs but does not exist in this checkout.
- `decepticon-sdk/__init__.py` calls the scaffolding CLI "deferred"; it is
  shipped.
- Root `CONTRIBUTING.md` and `docs/contributing.md` have diverged; README links
  only the latter.
- `.golangci.yml`, `.yamllint.yaml`, `.markdownlint.yaml*` at root are orphaned
  (no CI/pre-commit consumer).
- `clients/web/LICENSE` copyright drifted from root `LICENSE` (year + entity).

---

## See also

- [README.md](README.md) — what Decepticon is and how to run it.
- [CLAUDE.md](CLAUDE.md) — how we work in this fork (conventions, kata, GLM setup, upstream cherry-picks).
- [docs/README.md](docs/README.md) — the deep-dive index.
- [docs/security/decepticon-threat-model.md](docs/security/decepticon-threat-model.md) — the STRIDE threat model.
- [docs/adr/](docs/adr/) — architecture decision records.
- `CONTEXT/projects/decepticon-lessons.md` (private COWORK) — the VM-level ops runbook for this box.
