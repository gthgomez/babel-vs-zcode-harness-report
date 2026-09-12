# Orchestration — Controllers, Modes & Subagents

**Thesis:** Babel runs three intentionally separate controllers over one shared executor contract and buys governance with orchestration weight; ZCode runs one agent loop whose modes are permission states and buys flexibility with soft coordination — and each has exactly the failure mode the other one engineered away.

## Scope

This section compares who is actually driving the agent: how many control loops exist, how mode boundaries (read-only vs mutating) are enforced, and how work is parallelized (pipeline stages vs subagent fan-out). Babel side is grounded in the read-only repo at `/home/linuxuser/Babel` (docs + `babel-cli/src`). ZCode side is grounded in the operating environment this analysis literally runs in: plan mode (mechanically read-only until the user approves a plan via `ExitPlanMode`), the interactive default and permission modes, the Agent tool (general-purpose, Explore, judge subagents), background tasks, `SendMessage`, Skill invocation, and the main-agent-only restriction on browser control. Completion authority, isolation, and evidence are covered by sibling sections; they appear here only where they gate orchestration.

## How Babel does it

**Three controllers, one substrate, by decision.** ADR-012 (`docs/adr/ADR-012-canonical-harness-architecture-v1.md`) explicitly evaluated and *rejected* "collapse Chat/Plan/Deep into one loop," because it "loses intentional policy differences (read-only plan, governed deep, interactive chat)." The normative topology (`docs/architecture/HARNESS_ARCHITECTURE_V1.md` §6.4) is:

```text
ChatEngine (chat)     Plan lane (plan)      V9 pipeline + Stage 4 (deep)
  mutation: normal      mutation: read_only   mutation: governed
  approval: interactive approval: handoff     approval: stage_gated
  completion: executor  completion: plan_artifact  completion: proof_carrying
        └──────────── shared executor contracts + kernel ────────────┘
```

The policies are code, not prose: `babel-cli/src/executor/contracts.ts` defines `ModePolicy` and a total function `modePolicyFor(mode)` returning the fixed triple per mode, plus `classifyToolEffect()` which buckets every tool into `read_only | idempotent | reconcilable_mutation | non_idempotent_local_effect | external_side_effect` before execution. Invariants H3/H4 make the split normative: controllers MUST share the executor contract boundary but MAY keep different orchestration. Conformance lives in `babel-cli/src/executor/architectureConformance.test.ts`.

**The mode parity matrix** (`docs/architecture/HARNESS_OVERVIEW.md`) makes the differences auditable per dimension — entry, engine, V9 orchestrator, QA stage, mutation policy, approval, completion policy, verification, stack, shared kernel. Enforcement points: `babel-cli/src/executor/modeController.ts` has `assertEffectAllowed()` (plan mode denies any non-read-only effect *before the tool reaches a mutating executor*) and `assertTerminalAllowed()` (plan may only emit `PLAN_COMPLETE`; executor modes may never emit it). This is how H1 ("plan MUST remain read-only") stays honest — it's a thrown exception, not a prompt.

**The V9 deep waterfall** (`babel-cli/src/pipeline.ts`): Stage 1 orchestrator produces an instruction stack → Stage 2 SWE planning → Stage 3 QA review looped at most `MAX_SWE_QA_LOOPS = 3` times (`babel-cli/src/pipeline/paths.ts`), with REJECT feedback fed back to the SWE agent and escalation to a stronger planner on repeated rejection tags (`services/plannerRouter.ts`); exhausting the loop terminates with `QA_REJECTED_MAX_LOOPS` and *zero mutations*. An optional adversarial QA gate (`pipeline/qaStage.ts`) re-reviews the plan with a *different* model; if the adversarial runner is unavailable the default (`BABEL_ADVERSARIAL_QA_FALLBACK=halt`) treats it as REJECT — fail-closed, not fail-open. Stage 4 (`pipeline/executorLoop.ts`) runs only when `effectiveMode === 'deep' && approvedPlan !== null`, behind a belt-and-suspenders activation gate (`assertBoundedPlanActivationContract`) that refuses executor start if plan write targets drift from the bounded target set, plus an interactive per-step checklist. Finalize applies the required-verifier contract, demoting COMPLETE when promised verifiers didn't run.

**Purpose-built subagent lanes, not generic ones.** Babel's parallelism primitives are narrow and contract-shaped: `agent/exploreFeederAgent.ts` (W2.2) runs a budget-capped read-only "evidence pack" loop (default 6 rounds / 12 tools, cannot write); `agent/implementWorktreeAgent.ts` (W2.1) spawns a mutation-capable child in an isolated git worktree with a *required disjoint path allowlist* (`write_scope`), hard-blocked in `agent/lanes/runMutationAgentLoop.ts` ("Write blocked: ... is outside write scope ... for agent X"); `agent/reviewOnDiffAgent.ts` (W2.3) reviews diff text only. Cross-agent collision safety also exists at plan level: `pipeline/workspaceLocks.ts` halts a plan whose mutating targets hold active locks from another agent/run. The router (`services/liteFullRouter.ts`) decides when daily traffic escalates to `deep_lane`.

**Honest gaps.** Babel labels its own maturity: subsystem 3 ("Risk Router and Controller") is IMPLEMENTED for the three controllers but "Full `ModeController.submit` adapters **partial**" — the `ModeController` interface (`executor/modeController.ts`) exists with `submit/cancel/resume`, yet production chat is still ChatEngine plus `kernel.decide`, not a full adapter per mode (HARNESS_OVERVIEW known gap #5). And there is a documented naming collision: product "Full orchestration / Spark" (`docs/architecture/BABEL_FULL_ORCHESTRATION.md`) can denote a *read-only multi-agent proof lane*, while pipeline `deep` **does mutate** in Stage 4. The docs themselves warn not to conflate them.

## How ZCode does it

ZCode is the opposite bet: **one loop, many permission states, generic subagents.**

**One agent loop.** There is a single driving loop (the one composing this analysis). There is no ChatEngine-vs-pipeline split and no controller class hierarchy; "mode" is a state of that loop, not a different engine:

- **Plan mode** is mechanically enforced read-only — the harness will not execute mutating tools until the agent presents a plan via the `ExitPlanMode` tool and the *user* approves. This is ZCode's analogue of Babel's H1/H2: read-only is enforced outside the model, and "plan approved" cannot be confused with "patch verified" because plan approval is a mode transition, not a completion claim.
- **Interactive default + permission modes** govern how much per-tool approval is required (prompt vs allow vs bypass), roughly Babel's `interactive` vs `normal` mutation policy, but as a dial on the same loop rather than a separate controller.

**Orchestration is a tool surface, not a pipeline.** Parallelism and delegation come from tools the main agent calls:

- **Agent tool** spawns subagents: `general-purpose` (all tools, can mutate), `Explore` (read-only, intended for fan-out search — the closest analogue to `exploreFeederAgent.ts`), and `judge` (visual acceptance of document deliverables). Subagents run with their own context windows and report back to the orchestrator.
- **Background tasks** (`run_in_background`) let Bash commands *and* subagents run concurrently; the orchestrator is re-invoked on completion, which is how a fan-out of N workers is collected without blocking.
- **SendMessage** passes messages between agents — coordination is conversational, not mediated by a lock table or evidence bundle.
- **Skills** package procedures the main agent can load (e.g., a browser-control skill).

**Role restriction exists but is the exception.** Browser-control work is hard-gated main-agent-only: subagents must not load the browser skill or drive the browser. Otherwise the model is: any subagent that can write, can write anywhere in the workspace. There is no `write_scope` allowlist, no worktree-per-agent, no lock registry consulted before edits. The harness's answer to concurrent mutation is *discipline*: the orchestrator is instructed to partition subagent work with disjoint file ownership, because concurrent agents editing the same file collide (last-write-wins at the tool layer). File-ownership is a convention the main agent must maintain, not a mechanism that fires.

**Completion honesty is delegated.** There is no kernel that deterministically downgrades a completion claim, no QA-loop bound, no verifier-contract demotion. Verification happens because the agent runs tests and reports; the user, plan approval, and permission prompts are the gates. That is honest about its mechanism — ZCode never claims stage-gated proof — but it means "the CI is green" is agent-reported, not harness-adjudicated.

## Head-to-head

| Dimension | Babel | ZCode |
|---|---|---|
| Driving loops | 3 product controllers (Chat/Plan/Deep) + shared kernel; collapse rejected in ADR-012 | 1 loop; modes are permission states of it |
| Read-only enforcement | `modePolicyFor` + `classifyToolEffect` + `assertEffectAllowed` throws pre-executor (H1) | Plan mode mechanically blocks mutation until `ExitPlanMode` approval |
| Mode→engine mapping | Mode *selects* a different controller/engine | Mode *configures* the same engine |
| Parallelism | Sequential stage waterfall; QA ≤3 loop; purpose-built lanes (explore/worktree/review-on-diff) | Generic subagent fan-out + background tasks + `SendMessage` |
| Subagent write safety | Hard: disjoint `write_scope` allowlist, worktree isolation, `workspaceLocks` conflict halt | Soft: orchestrator-enforced disjoint file ownership; no allowlist or locks |
| Completion authority | `kernel.decide` + honesty gate + verifier-contract demotion | Agent-reported; user/permission gates; no downgrade machinery |
| Failure taxonomy | `TerminalOutcome` enum incl. `BLOCKED_POLICY`, `BUDGET_EXHAUSTED`; the pipeline adds run statuses like `QA_REJECTED_MAX_LOOPS` | Task success/failure surfaces to orchestrator; no typed outcome ledger |
| Maturity (self-labeled) | IMPLEMENTED on controllers/mode policy; `ModeController` adapters PARTIAL; naming collision documented | Shipped product; enforcement simple enough to be uniformly real |

The prose version: Babel's mode boundary is honest because each mode is a *different program* sharing one decision kernel, and the kernel's decisions are exceptions and receipts, not prose. The cost is orchestration weight — three codebases of controller logic, a 3,400-line pipeline, and admitted seams (`ModeController` adapters PARTIAL, product-vs-pipeline naming drift). ZCode's model is honest in a different way: one loop means one thing to audit, and plan mode demonstrates you can get a hard read-only boundary without a second engine. The cost is that *everything past the approval gate* — parallelism safety, completion honesty — rides on model judgment and user attention.

## Simulation vignette

**Task: "Migrate 40 test files from Jest to Vitest and fix the CI."**

**Babel, `babel deep`:** Stage 1 compiles the instruction stack; Stage 2's SWE agent emits a plan whose `file_write` targets are a bounded set — all 40 test paths plus CI config. If the plan's targets drift from the bounded set, `assertBoundedPlanActivationContract` refuses activation (`ACTIVATION_REFUSED`) before Stage 4 ever starts. Stage 3's QA reviewer PASS/REJECTs the *plan* — wrong vitest config, missed `jest.mock` semantics — looping ≤3 times with feedback; an adversarial second model can reject it again; three strikes ends the run as `QA_REJECTED_MAX_LOOPS` with the repo untouched. On PASS, an interactive checklist approves the step set; Stage 4's executor loop mutates inside worktree safety with post-write verification, and finalize demotes COMPLETE unless the plan's required verifiers (the CI command) actually ran green. **Failure mode: QA-loop thrash** — a pedantic QA/adversarial model burns all 3 attempts on plan-text disagreements and the run terminates having done nothing, at the cost of four-plus model invocations per attempt. The mitigations are real (mutation only ever happens on an approved plan) but latency- and token-heavy.

**ZCode:** The main agent enters plan mode (read-only by construction), optionally fanning out `Explore` subagents to map the test suite, then presents a plan: "subagent A migrates `tests/a/` (10 files), B `tests/b/`, C `tests/c/`, D `tests/d/`; I own `vitest.config.ts`, `package.json`, and the CI workflow." On `ExitPlanMode` approval, it spawns A–D as background `general-purpose` subagents with disjoint directory ownership, collects them as background completions, then fixes the CI itself and runs it. Elapsed time is roughly one subagent's work plus merge-and-verify. **Failure mode: subagent merge collisions** — ownership is a convention; if subagent B edits a shared `tests/helpers.ts` that D also touches (or two agents both "fix" `package.json` scripts), writes collide with no lock, no allowlist, and no rollback ledger to reconstruct intent; the collision surfaces as a broken suite *after* the fan-out, and the main agent debugs it as new work. Secondary risk: "fix the CI" is done when the agent says so — nothing in the harness forces the CI run that would falsify the claim.

The symmetry is exact: Babel can fail by *not mutating when it should* (gate thrash); ZCode can fail by *mutating when it shouldn't* (unowned concurrent writes, unverified completion). Babel's gates sit before mutation; ZCode's sit before the whole task.

## Verdict

**For repeatable, governed mutation, Babel's model is stronger — on the strength of its gates, not its taxonomy.** The three-controller split would be over-engineering if the modes shared behavior, but they don't: read-only planning, interactive chat, and proof-carrying deep runs genuinely want different approval and completion policies, and `modePolicyFor` + the assert functions make those differences executable. Stage gates (bounded activation, QA ≤3, verifier demotion) convert "the model misbehaved" from silent corruption into typed, halt-able outcomes. The honest caveat is Babel's own: adapters are PARTIAL, and the system's weight is a real cost — most tasks don't need Stage-1-through-4 ceremony.

**For interactive and read-heavy work, ZCode's flat model wins.** One loop with a mechanically enforced plan mode covers 80% of what Babel's controller taxonomy protects, at a fraction of the code; Explore fan-out plus background tasks gives parallel discovery Babel only has inside its bespoke W2 lanes; and there is no naming-collision-class doc drift because there is one engine to describe.

**What each should adopt:**
- **ZCode from Babel:** per-subagent `write_scope` — a hard path allowlist checked at the tool layer, making disjoint file ownership a mechanism instead of a convention; and a cheap `kernel.decide` analogue that downgrades "done" to "claimed done" when the agent's completion claim isn't backed by a recorded verifier run.
- **Babel from ZCode:** general-purpose subagent fan-out as a first-class tool (its explore feeder is close but purpose-locked), so governed runs can parallelize discovery and mechanical per-file edits without writing a new lane each time; and ZCode's proof that a read-only mode can be a permission state — useful for shrinking the PARTIAL `ModeController` adapter surface rather than completing all of it.

Neither model "scales" universally: Babel scales to workloads where the cost of an undetected false completion exceeds the cost of ceremony (SWE-bench-style runs, CI-repair campaigns); ZCode scales to workloads where a human is in the loop anyway and throughput comes from parallel search. The interesting convergence is that both are converging on the same two primitives from opposite directions — Babel adding generic fan-out lanes, ZCode being asked for harder write scopes.

## Key sources

- `/home/linuxuser/Babel/docs/architecture/HARNESS_OVERVIEW.md` — mode parity matrix, call graphs, authority boundaries, known gap #5 (ModeController), Full-orchestration vs deep naming collision
- `/home/linuxuser/Babel/docs/architecture/HARNESS_ARCHITECTURE_V1.md` — §6.4 controller topology, §6.6 invariants H1–H4, subsystem 3 maturity ("adapters partial")
- `/home/linuxuser/Babel/docs/adr/ADR-012-canonical-harness-architecture-v1.md` — rejection of single collapsed controller
- `/home/linuxuser/Babel/babel-cli/src/executor/contracts.ts` — `ModePolicy`, `modePolicyFor`, `classifyToolEffect`
- `/home/linuxuser/Babel/babel-cli/src/executor/modeController.ts` — `ModeController` interface, `assertEffectAllowed`, `assertTerminalAllowed`
- `/home/linuxuser/Babel/babel-cli/src/executor/kernel.ts` — shared completion authority
- `/home/linuxuser/Babel/babel-cli/src/pipeline.ts` — V9 stage waterfall, QA ≤3 loop, `QA_REJECTED_MAX_LOOPS`, bounded activation gate, Stage 4 gating
- `/home/linuxuser/Babel/babel-cli/src/pipeline/paths.ts` — `MAX_SWE_QA_LOOPS = 3`
- `/home/linuxuser/Babel/babel-cli/src/pipeline/qaStage.ts` — adversarial QA gate, halt-default fallback
- `/home/linuxuser/Babel/babel-cli/src/pipeline/executorLoop.ts` — Stage 4 executor loop
- `/home/linuxuser/Babel/babel-cli/src/pipeline/workspaceLocks.ts` — cross-run workspace lock conflict halt
- `/home/linuxuser/Babel/babel-cli/src/agent/chatEngine.ts` — daily ChatEngine loop
- `/home/linuxuser/Babel/babel-cli/src/agent/exploreFeederAgent.ts`, `implementWorktreeAgent.ts`, `reviewOnDiffAgent.ts`, `lanes/runMutationAgentLoop.ts` — W2.2/W2.1/W2.3 subagent lanes and `write_scope` enforcement
- `/home/linuxuser/Babel/babel-cli/src/services/liteFullRouter.ts` — lite→deep lane routing
- ZCode operating environment (this session): plan mode/`ExitPlanMode`, permission modes, Agent tool (general-purpose/Explore/judge), background tasks, `SendMessage`, main-agent-only browser control
