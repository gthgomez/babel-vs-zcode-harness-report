# Instruction Stacking: Compiled Provenance vs. Convention and Precedence

**Thesis:** Babel treats instructions as versioned data — a catalog-resolved, hash-bound manifest that can be frozen, restored, and audited — while ZCode treats instructions as curated text that reaches the model by convention, precedence, and on-demand skill loading; Babel pays a heavy maintenance tax for guarantees ZCode simply does not offer, and ZCode's speed and low friction come from having no answers to provenance, conflict, and delivery-verification questions at all.

## Scope

This section covers how each harness decides *what the model is told to be* on a given task: the identity of instruction sources, the mechanism that assembles them into context, what happens to them across compaction and resume, and how drift or conflict is (or is not) detected. It does not cover completion authority, isolation, or evidence streams (see sibling sections). "Instruction stacking" here means the full feedforward surface: system-level identity, per-repo instruction files, domain/skill layers, and on-demand instruction packages.

## How Babel does it

Babel's Prompt OS is a layered instruction library with a compiler in front of it. The design separates *what the model knows* from *how it behaves*: a Behavioral OS layer (always loaded, currently `OLS-v11-Core-Unified.md` / `behavioral_core_v11`) sits above Domain Architects, Skills, Model Adapters, Project Overlays, and Task Overlays, with a fixed precedence (Behavioral OS > Domain > Skills > Adapter; Project > Task). Two infrastructure layers — `00_System_Router/` and `04_Meta_Tools/` — author and select but are not themselves in the runtime stack (`docs/architecture/ARCHITECTURE.md`).

Three mechanisms make this more than a folder of prompts:

1. **Catalog authority.** `prompt_catalog.yaml` (3,415 lines, version 3) is the single source of truth: every routable file must be registered with `id`, `layer`, `path`, `status` (active/deprecated), `dependencies`, `conflicts`, `token_budget`, and `default_skill_ids`. The invariant is explicit: *no prompt file is canonical unless listed in the catalog*. A versioning policy table governs filename and ID conventions per layer, and `load_position` disambiguates intra-layer ordering for the ~44 entries where it matters. `tools/validate-catalog.ps1` enforces structural integrity.

2. **Typed routing + deterministic resolution.** In deep/governed mode, the OLS-v9 orchestrator (`00_System_Router/OLS-v9-Orchestrator.md`) does not pick files — it emits a typed JSON manifest of layer *IDs* (`instruction_stack` + `resolution_policy`, including `strict_conflict_mode: "error"`). The resolver (`babel-cli/src/control-plane/stackResolver.ts`, ~1,258 lines) owns path resolution, dependency expansion, conflict checks, budget-aware pruning, and token accounting, producing `compiled_artifacts`. Daily chat uses a deliberately slim compiler instead: `babel-cli/src/agent/chatStackCompile.ts` builds the smallest stack (identity from `AGENTS.md`/`CLAUDE.md`, closest project instructions, a regex-inferred domain/skill hint, plus builtin safety/provider/verifier snippets) under hard budgets (12k chars interactive, 24k SWE-class).

3. **Provenance manifests (H2).** `babel-cli/src/agent/instructionManifest.ts` evolves the path-list into `InstructionManifestV1`: every fragment carries `rule_id`, `source`, `source_hash` (sha256 of authoritative content), `precedence`, `scope` (`session`/`turn`/`plan_step`/`tool`/`global`), `selection_reason`, optional `plan_step_id`, and a `policy_class` (`mechanical`/`verifier`/`advisory`). The aggregate `manifest_hash` yields a `manifest_id` (`im1:<hash>`); `validateInstructionManifestV1` recomputes and fails closed on mismatch. The ChatEngine freezes the manifest plus `TaskContractV1` at construction (`initLiveAuthorityOnEngine` in `chatEngineLiveSession.ts`), persists it under the session run dir, and restore (`loadLiveSessionAuthorityStrict` in `liveSessionBridge.ts`) fails closed. `bindFragmentToPlanStep` binds rules to plan steps. The roadmap exit gate (`docs/architecture/HARNESS_HARDENING_ROADMAP_V1.md`, H2): *policy fragments cannot disappear through compaction, failover, subagent handoff, or resume*.

Two honest caveats. First, maturity: HARNESS_ARCHITECTURE_V1.md labels subsystem 2 **IMPLEMENTED** for the catalog path, the chat slim stack, and `InstructionManifestV1`, but lists open gaps — fragment utility measurement, conflict reports, and "full ChatEngine dual-write of every H2 budget event on all paths." H2 itself is **PARTIAL** (budget/idempotency reconstruction is Chat-only). Second, the chat-side `manifest_hash` in `chatStackCompile.ts` hashes sorted *ids + layers + paths*, not file content — it detects selection drift but not content drift; only the InstructionManifestV1 wrapper adds content hashes, and whether every chat path builds one is exactly the kind of gap the PARTIAL labels flag.

Finally, the cost. Catalog maintenance is manual and visible: the YAML header records ~39 curation "passes." And `CLAUDE.md` invariant 6 mandates co-evolution: *if `babel-cli/src/schemas/agentContracts.ts` or any `build*Task` function in `pipeline.ts` changes, the corresponding prompt file must be updated in the same change set*. This is a process rule enforced by review and drift checkers (`tools/check-harness-architecture.ps1`), not a compiler — the same discipline Babel demands of its instructions is enforced on Babel's own docs only procedurally.

## How ZCode does it

ZCode — the harness this analysis was written inside — stacks instructions with no compile step and no catalog, using four convention-driven surfaces:

1. **A fixed system prompt.** Identity, tool contract, communication rules, memory instructions, and context-management policy are baked into the runtime. It is not user-authored, not per-task selected, and exposes no version or hash to the agent. Everything layered on top must be consistent with it; the system prompt wins by definition, not by declared precedence.

2. **Repo instruction files.** `AGENTS.md` / `CLAUDE.md` in the working directory are auto-loaded at session start, with an index of additional context files. This is per-repo instruction injection: a project rule placed there reaches the model on every task in that repo, by convention. There is no registry of these files, no declared precedence between them beyond convention (CLAUDE.md/AGENTS.md layering), and no schema.

3. **Skills.** User-invocable markdown instruction packages (e.g. document creation, browser control, configuration diagnostics) listed in a system reminder with their descriptions; the model loads one on demand via a Skill tool. Crucially, a skill is a *capability bundle*: instruction text plus executable scripts that arrive together, so "how to do X" and "the tool that does X" ship as one unit. Selection is trigger-by-description — if the task phrasing doesn't match the frontmatter description, the skill never loads. Plugins provide additional skills from a cache directory.

4. **Persistent memory.** A `MEMORY.md` index plus per-fact files that survive sessions — effectively *learned instructions*. Rules the agent extracted in a previous session can re-enter context later, with no binding to a repo, no scope declaration, and no conflict arbitration against `AGENTS.md`.

What convention buys: zero compile latency (the stack is static plus on-demand loads); near-zero authoring friction (edit a markdown file, done); capability bundling (skill + scripts); and progressive disclosure (the base prompt stays small; detail arrives only when a skill triggers). What it risks: **no provenance** — nothing can answer "which file produced the rule the model just followed"; **silent conflicts** — no `conflicts` field and no resolver, so `AGENTS.md`, memory, and a skill can contradict and whichever text the model saw last or weighted higher wins without a signal; **no delivery verification** — nothing checks that an instruction actually entered context (an untriggered skill is a silently undelivered instruction); and **no drift detection** — editing `SKILL.md` or `AGENTS.md` mid-project changes behavior with no hash change observable to any component, and a resumed session cannot detect that its instructions were rewritten underneath it.

## Head-to-head

| Dimension | Babel | ZCode |
|---|---|---|
| Authority model | Catalog is single source of truth; unlisted files non-canonical | Convention: system prompt > repo files > skills/memory, undeclared |
| Versioning | Catalog IDs, per-layer version policy, active/deprecated status | None exposed (file mtime at best) |
| Assembly | Deterministic resolver/compiler (deep) or slim compiler (chat) | Static system prompt + auto-loaded repo files + on-demand skills |
| Provenance | `rule_id` + `source_hash` + `selection_reason` per fragment | None |
| Conflict handling | `conflicts` field, `strict_conflict_mode: error`, layer precedence | Informal precedence; conflicts surface only as model behavior |
| Budget control | Per-entry `token_budget`, budget-aware pruning, 12k/24k chat budgets | Fixed prompt; skills load whole (markdown-sized) |
| Compaction/resume survival | Manifest frozen at start, restored fail-closed (H2, PARTIAL) | Whatever context policy retains; no rule identity carried forward |
| Enforcement separation | H9 + `policy_class` (mechanical/verifier/advisory) explicit | Implicit at best — skill scripts approximate mechanical enforcement |
| Drift detection | Manifest/source hashes; `validate-catalog.ps1`, `check-harness-architecture.ps1` | None |
| Authoring cost | High: catalog registration, layer specs, co-evolution invariant | Low: edit markdown |
| Latency | Compile step; deep mode adds a routing model call | Zero |
| Capability bundling | Prompt files only (meta tools author them separately) | Skills ship instruction + scripts as one unit |

The prose version: Babel makes instructions *queryable state*; ZCode keeps them as *ambient text*. Babel can prove what the model was told, re-freeze it across a crash, and detect when a source file changed. ZCode can deliver an instruction faster, cheaper, and bundled with the script that enforces it — but if you ask "was the rule in context on turn 40?" or "did anyone change the rule since turn 1?", ZCode's honest answer is "no idea."

Note that this is a spectrum, not a dichotomy: Babel itself ships `AGENTS.md`/`CLAUDE.md` and `.agents/rules/` + `.agents/skills/` — the same convention layer ZCode uses — and its chat compiler loads those files directly. The catalog/manifest machinery is the governed superset, not a replacement.

## Simulation vignette

Scenario: a project rule — **"never use lodash; use native ES2023+"** — must reach the model on every relevant task and survive a long, compaction-heavy session.

**Babel (deep mode):** The rule is project-specific, so it belongs in a Project Overlay (`05_Project_Overlays/`), registered in `prompt_catalog.yaml` with an ID and `status: active` (validated by `tools/validate-catalog.ps1`). The V9 orchestrator routes the task to the project; the stackResolver resolves the overlay into `compiled_artifacts`. `buildInstructionManifestV1` hashes the file content into a fragment (`source_hash`, `policy_class: advisory` — the roadmap is explicit that *acknowledging a rule in model text does not make it enforced*), and `bindFragmentToPlanStep` can pin it to the refactor steps it governs. At compaction, H1's commit path writes a capsule whose operational fields include task/plan state, and the H2 exit gate says the fragment cannot silently vanish; at crash-restore, `validateInstructionManifestV1` recomputes hashes and fails closed on mismatch. Drift is detectable two ways: the fragment `source_hash` changes if anyone edits the overlay, and the restored manifest no longer matches disk. Degradation modes: H2 is PARTIAL (cross-surface guarantees are Chat-only per the roadmap), the rule is advisory — if the model imports lodash anyway, only an external verifier catches it, which is exactly the H9 division of labor. And if the rule were instead parked in `PROJECT_CONTEXT.md` and reached chat mode via `compileChatStack`, a long file plus the 24k budget-trim (which slices `system_context` from the end and appends `/* chat stack budget trim */`) could truncate the rule out of the actual prompt while the entry record still claims it was selected — a real failure mode Babel's own chat manifest hash (ids+paths only) would not see.

**ZCode:** The rule goes in `AGENTS.md`, which is auto-loaded at session start — delivery on task one is essentially guaranteed by convention. On task forty, after hours of context churn, the guarantee has decayed to *whatever the context-management policy retained*. No capsule preserves the rule by identity; nothing re-injects it; if it scrolls out, the model may import lodash with no harness-level signal. The mitigations are all manual: restate the rule in the prompt, or package it as a skill — but skill loading is trigger-by-description, so "clean up these helper functions" may not fire a skill described as "dependency conventions." A third option, memory, persists the rule across sessions but unbinds it from the repo and can silently contradict `AGENTS.md` after the file is edited. Drift detection is nil: someone deletes the rule from `AGENTS.md` mid-project and no hash changes, no validation runs, and a resumed session cannot tell. The only detector is the model's own output — the exact thing Babel's H9 declares untrustworthy. The strongest ZCode-native mitigation is the skill's *script* side: a lint rule shipped alongside the instruction converts the rule from advisory text into a mechanical check, achieving by bundling what Babel achieves by policy classification plus verifier contracts.

Net: Babel guarantees delivery-at-session-start and provable persistence-with-caveats; ZCode guarantees delivery-at-session-start by convention and offers nothing after that except the model's compliance.

## Verdict

**Babel is better where instruction identity matters.** For governed, long-running, auditable work, compiled provenance is the correct design: rule IDs and source hashes make "what was the model told" a checkable fact rather than a memory; fail-closed manifest restore closes the silent-divergence class of failure; the catalog's `conflicts` field and strict mode catch contradictions the ZCode stack would resolve silently and wrongly. This is worth its cost *for Babel's stated mission* — but the cost is real: a 3,415-line hand-curated YAML, dozens of documented curation passes, and a co-evolution invariant that is enforced by discipline rather than tooling. Babel's own PARTIAL labels are the right honesty marker: the manifest machinery exists and is unit-proven, but uniform cross-surface coverage is not yet demonstrated.

**ZCode is better where iteration speed and capability bundling matter.** Skills that arrive with their own scripts are a genuinely good idea — instruction and enforcement shipped as one sandboxed unit — and the zero-compile surface makes instruction authoring nearly free. Memory-as-learned-instructions is a Babel gap in spirit, though Babel's chat stack has a `project:memory` injection slot, so the gap is narrowing.

**What each should adopt:**
- **ZCode from Babel:** a lightweight instruction manifest — snapshot rule IDs + content hashes of `AGENTS.md`/loaded skills at session start, verify on resume, and surface a warning when sources changed underneath the session; a declared precedence/conflict note for repo files vs. memory vs. skills; and a delivery signal distinguishing "instruction is in context" from "instruction exists on disk."
- **Babel from ZCode:** bundle executable checks with instruction fragments (its `policy_class: mechanical` fragments should point at a script, not just a label), and drop the friction of contributing convention-level rules — its `.agents/rules/` convention layer shows it already agrees.
- **Babel for itself:** extend the chat-side `manifest_hash` to cover file content, and close the H2 cross-surface gap it already lists — otherwise the vignette's chat-mode truncation failure remains live.

## Key sources

- `/home/linuxuser/Babel/docs/architecture/ARCHITECTURE.md` — six runtime layers, catalog fields, V9 routing, layer precedence
- `/home/linuxuser/Babel/docs/architecture/HARNESS_ARCHITECTURE_V1.md` — subsystem 2 (Context and Instruction Compiler), invariant H9, maturity labels
- `/home/linuxuser/Babel/docs/architecture/HARNESS_HARDENING_ROADMAP_V1.md` — H1/H2 waves, InstructionManifestV1, "policy fragments cannot disappear" exit gate
- `/home/linuxuser/Babel/prompt_catalog.yaml` — catalog authority, versioning policy, load-position policy
- `/home/linuxuser/Babel/00_System_Router/OLS-v9-Orchestrator.md` — typed routing manifest (IDs, not paths)
- `/home/linuxuser/Babel/babel-cli/src/agent/chatStackCompile.ts` — chat slim stack, 12k/24k budgets, selection-only manifest hash, budget-trim behavior
- `/home/linuxuser/Babel/babel-cli/src/agent/instructionManifest.ts` — InstructionManifestV1 fragments, hashes, plan-step binding, validation
- `/home/linuxuser/Babel/babel-cli/src/control-plane/stackResolver.ts` — catalog resolution, conflict mode, budget-aware pruning
- `/home/linuxuser/Babel/babel-cli/src/agent/chatEngineLiveSession.ts`, `babel-cli/src/agent/liveSessionBridge.ts` — authority freeze/persist/restore, fail-closed load
- `/home/linuxuser/Babel/CLAUDE.md` — invariant 6 (prompt/runtime co-evolution), invariant 5 (catalog authority)
- `/home/linuxuser/Babel/.agents/rules/`, `/home/linuxuser/Babel/.agents/skills/`, `/home/linuxuser/Babel/AGENTS.md` — Babel's own convention layer
- `/home/linuxuser/Babel/tools/validate-catalog.ps1`, `/home/linuxuser/Babel/tools/check-harness-architecture.ps1` — drift detection tooling
