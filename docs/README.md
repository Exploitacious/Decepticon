# Documentation index

> The map of `docs/`. Every deep-dive lives here; the four canonical docs live at
> the repo root. Start with [`/README.md`](../README.md) (what Decepticon is),
> [`/ARCHITECTURE.md`](../ARCHITECTURE.md) (how it works), and
> [`/CLAUDE.md`](../CLAUDE.md) (how we work in this fork).

---

## How this directory is organized

Docs are grouped by **content type**, not filename prefix:

| Category | What it is |
|---|---|
| Runbook | Things an operator does on demand (setup, CLI, running an engagement) |
| Lifecycle deep-dive | End-to-end explanation of a subsystem — read once, reference later |
| One-time playbook | A procedure for a single event (a migration, a cleanup) |
| Backlog / proposal | Planned directions and not-yet-accepted designs |

The six kata rules that govern this repo's docs are in
[`/CLAUDE.md` § The project kata](../CLAUDE.md#the-project-kata). When you add a
doc: put it here (or next to its code if component-specific), add a row to this
index, and give it an opening "what this is" line and a "see also" footer.

---

## Runbooks

| Doc | What it covers |
|---|---|
| [getting-started.md](getting-started.md) | Prerequisites + first engagement |
| [setup-guide.md](setup-guide.md) | Full install / auth / provider / config reference |
| [cli-reference.md](cli-reference.md) | All CLI commands and shortcuts |
| [makefile-reference.md](makefile-reference.md) | All `make` targets |
| [engagement-workflow.md](engagement-workflow.md) | Planning → execution flow for an engagement |
| [contributing.md](contributing.md) | Contributor dev setup + quality gates |
| [mcp.md](mcp.md) | Attaching external MCP tool servers |
| [web-dashboard.md](web-dashboard.md) | Running/using the web dashboard |
| [update-channels.md](update-channels.md) | `stable` / `latest` release channels |
| [release.md](release.md) | Versioning + release process (moved from root RELEASE.md) |
| [e2e-testing-guide.md](e2e-testing-guide.md) | Manual E2E procedures for the LLM gateway |

## Lifecycle deep-dives

| Doc | What it covers |
|---|---|
| [architecture.md](architecture.md) | System architecture overview — **superseded by [/ARCHITECTURE.md](../ARCHITECTURE.md)** for transport detail |
| [agents.md](agents.md) | Agent roster + kill-chain organization |
| [agent-file-conventions.md](agent-file-conventions.md) | How agents write to disk / hand off / report |
| [agent-file-mapping.md](agent-file-mapping.md) | Which agent/skill writes which file |
| [knowledge-graph.md](knowledge-graph.md) | Neo4j attack-graph model |
| [models.md](models.md) | LiteLLM routing + fallback chains |
| [skills.md](skills.md) | Legacy text-matching skill system |
| [skillogy.md](skillogy.md) | Skillogy overview (current design: [design/skillogy-brain-redesign.md](design/skillogy-brain-redesign.md)) |
| [skill-schema.md](skill-schema.md) | Canonical `SKILL.md` schema (CI-enforced) |
| [contributor-architecture.md](contributor-architecture.md) | Package-split architecture for contributors |
| [library-usage.md](library-usage.md), [library-consumer-guide.md](library-consumer-guide.md), [plugin-author-guide.md](plugin-author-guide.md) | Using Decepticon as a library / building plugins |
| [QUALITY_BAR.md](QUALITY_BAR.md) | The AI-contribution quality contract |
| [COWORK.md](COWORK.md) | Upstream's internal collaboration / branch strategy |
| [engineering/ci-arsenal.md](engineering/ci-arsenal.md) | CI/CD pipeline reference |
| [integrations/](integrations/) | CI-CD, GitHub Actions, external-agent (MCP) integration |
| [tools/open-web.md](tools/open-web.md) | `web_search` / `web_fetch` tools |
| [features/blue-cell.md](features/blue-cell.md) | Blue Cell defensive agent |
| [security/](security/) | Runtime security control reference set (threat model, RoE, HITL, sandbox, Neo4j hardening, …) |
| [red-team/](red-team/) | Red-team domain knowledge (several docs in Korean) |
| [architecture/](architecture/) | Context-engineering + red-team-infra design notes (Korean) |
| [design/](design/) | Dated design docs and RFCs (mixed maturity) |
| [adr/](adr/) | Architecture Decision Records (numbered, append-only) |

## One-time playbooks

| Doc | What it covers |
|---|---|
| [migration/from-0.0.x.md](migration/from-0.0.x.md) | `decepticon` 0.0.x → core/framework/sdk split |
| [skill-cleanup-process.md](skill-cleanup-process.md) | Phase-0 SKILL.md corpus normalization (process) |
| [skill-cleanup-progress.md](skill-cleanup-progress.md) | Phase-0 cleanup progress log (COMPLETE 2026-06-03) |

## Backlog / proposals

| Doc | What it covers |
|---|---|
| [offensive-vaccine.md](offensive-vaccine.md) | Planned attack → defend → verify direction (not yet implemented) |
| [pypi-distribution-strategy.md](pypi-distribution-strategy.md) | Strategic analysis of PyPI publishing |
| [benchmark-comparison.md](benchmark-comparison.md) | Cross-project pentest-agent leaderboard |
| [proposals/](proposals/) | Draft compose-architecture + Redamon integration proposals |
| [superpowers/](superpowers/) | Agentic-worker plans/specs (ATT&CK registry, APT coverage) |

---

## See also

- [/README.md](../README.md) — what Decepticon is and how to run it.
- [/ARCHITECTURE.md](../ARCHITECTURE.md) — how the harness works, end to end (the current source of truth).
- [/CLAUDE.md](../CLAUDE.md) — how we work in this fork + the six kata rules.
