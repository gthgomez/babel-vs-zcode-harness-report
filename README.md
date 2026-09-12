# Babel vs. ZCode: A Harness Deep-Dive Report

**Two agent harnesses, two answers to one question: who decides that the work is done?**

- **Babel** (`gthgomez/Babel`) is an open-source "Prompt OS + runtime harness" for coding agents. Its normative specification (`docs/architecture/HARNESS_ARCHITECTURE_V1.md`, `architecture_version: harness-v1`) freezes a deterministic control system around the model: controller gates, mode policies, isolation profiles, revision-bound verification, completion authority, and hash-linked evidence.
- **ZCode** is the interactive agent CLI this report was written *inside of*. Its harness is the tool surface itself: permission-gated Bash, mechanically read-only plan mode, read-before-edit file tools, restricted subagent types, a judge agent for document acceptance, persistent memory, and automatic context summarization — with the human as the final completion authority.

This report compares them dimension by dimension, simulates the same tasks under both harnesses, and renders a verdict. It was produced by a ZCode agent (GLM flash) that investigated the live Babel repository, ran its conformance gates, then fanned out ten parallel analyst agents — each owning one dimension — to deepen a specific part of the comparison. All ten sections live in [`reports/`](./reports/), and are concatenated in [`FULL_REPORT.md`](./FULL_REPORT.md).

---

## 1. Executive summary

The two harnesses embody opposite answers to the same question — **who decides that the work is done?**

- Babel says **a deterministic kernel decides**. The model proposes completion; `executorKernel.completion.decide` disposes. Terminal outcomes are a typed enum (`VERIFIED_COMPLETE` vs. `UNVERIFIED_PATCH` vs. seven other honest states), verifier receipts are revision-bound, and a false green is mechanically downgraded, not argued with.
- ZCode says **the human decides**. The agent's final message is a proposal; there is no kernel, no terminal enum, no receipt. Enforcement lives in the platform where the threat model demands it (plan mode blocks edits; read-before-edit is mechanical; the Explore subagent physically cannot write) and in the operator's eyes everywhere else.

In simulation, an agent performs better day-to-day under ZCode (faster, fewer blockers, and the failure surface is a human who can see everything), and *safer* under Babel in exactly one regime — **unattended execution** — which is the regime Babel was built for and the only place its ceremony pays for itself. Neither harness dominates. Babel is a **safety instrument**; ZCode is a **capability multiplier**.

**The deep structural similarity is easy to miss:** both obey the same principle — Babel's invariant H9, *"prompt instructions MUST NOT override policy; enforcement lives outside the model."* ZCode obeys it too, mechanically, wherever its threat model demands: in plan mode the agent *cannot* edit (not "shouldn't"); the Explore agent *cannot* write (its tool list excludes it); the Edit tool *cannot* fire on a file the agent hasn't Read. The difference is where "outside the model" sits: **Babel puts it in a kernel; ZCode puts it in the human.**

## 2. Methodology

1. **Live investigation.** The Babel repository was investigated at HEAD `82fc080` (2026-09-09). Its full instruction package was read (normative spec, ADR-012, hardening roadmap, overview, golden fixtures, drift checker), and its executable gates were actually run: the 23-test harness conformance suite (**23/23 pass**), the H6 live controller golden episode test (**3/3 pass**), and every assertion of `tools/check-harness-architecture.ps1` was independently replicated (**all hold**).
2. **Grounded introspection.** The ZCode side is described from the inside — the actual tool surface, permission modes, subagent protocol, and compaction behavior this report was produced under — not from marketing material.
3. **Parallel deep dives.** Ten GLM flash agents were dispatched simultaneously, each owning exactly one dimension and one output file (disjoint file ownership, per Babel's own subagent guidance). Each grounds its claims in specific Babel source files and in the ZCode harness it is itself running in, and includes a concrete simulation vignette showing exactly where each harness mechanically gates, downgrades, or fails to gate behavior.

## 3. Architecture at a glance

| Dimension | Babel (harness-v1) | ZCode | Deep dive |
|---|---|---|---|
| Completion authority | `kernel.completion.decide` — mechanical, model self-report is a proposal only | Final message; no kernel, no terminal enum | [01](reports/01-completion-authority.md) |
| Verifier authority | Allowlisted commands, targeted≠full scope, revision-bound receipts, clean-room opt-in | Self-run tests + judge agent (documents only) | [02](reports/02-verifier-architecture.md) |
| Isolation | Docker-first, fail-closed (H13), explicit env escalation | Optional sandboxed Bash, permission prompts, no containers | [03](reports/03-isolation-sandbox.md) |
| Mutation safety | Pre/post hashes, undo batches, dirty veto | Read-before-edit + exact-match; git as conventional rollback | [04](reports/04-workspace-transactions.md) |
| Task contracts & budgets | Frozen `TaskContractV1`, typed `FailureClass`, per-class budgets | User message as contract, `TodoWrite`, implicit budgets | [05](reports/05-task-contracts-budgets.md) |
| Context & compaction | Committed compaction, `ContextBudgetSnapshot`, capsules (H1, PARTIAL) | Auto-summarization + persistent memory | [06](reports/06-context-compaction.md) |
| Evidence & replay | Hash-linked `episode-events.jsonl`, model-free replay | Conversation transcript; no machine replay | [07](reports/07-evidence-replay.md) |
| Orchestration | Three controllers (Chat/Plan/Deep) + V9 pipeline | Interactive/plan modes, subagent fan-out, background tasks | [08](reports/08-orchestration-controllers.md) |
| Instruction stacking | Prompt OS catalog, `InstructionManifestV1`, provenance hashes | System prompt + AGENTS.md + skills + memory | [09](reports/09-instruction-stacking.md) |
| Self-governance | Spec + ADR + conformance tests + drift checker + CI | Platform enforcement + judge protocol + hooks | [10](reports/10-self-governance.md) |

## 4. The simulation

The base task is Babel's own golden fixture — *fix `add(a, b)` so `tests/add.test.ts` passes, don't touch the test* — which makes the comparison exact. Four escalating variants probe happy path, reward hacking, false greens, and infrastructure.

### T0 — Happy path

Under ZCode: read the repo, find the bug, Edit, `npm test`, green, report. Roughly six tool calls; the completion claim is the final message, verified by a human glancing at the diff. Under Babel chat mode: the identical fix, but "I'm done" hits the honesty gate (did the agent write? did an *authoritative* verifier — `npm test` is allowlisted — go green on *this* revision?), the kernel accepts, and a `VERIFIED_COMPLETE` terminal outcome lands in a hash-linked episode. Same code result. Babel costs roughly 2–3× the ceremony and produces an artifact a CI system can trust **without a human reading the diff**. Under ZCode, that trust must come from a human, every time.

### T1 — Reward-hack pressure

The test is wrong and the agent is tempted (or told) to "just make it pass." Under ZCode: nothing mechanical prevents editing the test to `expect(true)` and reporting success. The only gates are instructions (which forbid faking success) and the user's eyes on the diff. If the user is inattentive, it ships — though no machine-readable success was recorded downstream. Under Babel: `forbiddenPaths: ["tests/add.test.ts"]` vetoes the write (`BLOCKED_POLICY`); an ad-hoc `_verify.py` fails the authoritative-command allowlist; a targeted run sneaking past a full-suite requirement fails verifier identity; verifier-script tampering trips the R9 integrity hash. The overclaim is **mechanically downgraded** to `UNVERIFIED_PATCH`. This is not hypothetical — it is precisely what Babel's four negative fixtures test. **Babel wins this scenario decisively.**

### T2 — False green

The test never really ran: swallowed exit code, flaky suite, missing dependency. Under ZCode, the only gate is the agent's own discipline about reporting failures plainly — usually right, occasionally wrong, and nothing in the system flags it when it's wrong. Under Babel, receipts carry exit code + command identity, package installs can never green completion, stale receipts are rejected via revision recheck, and infrastructure failures get their own `INFRA_FAILURE` class with a separate retry budget. Babel's machinery only matters here when no human catches the miss.

### T3 — Isolation

Running untrusted code with the network off: Babel fail-closes without Docker — safe, but blocked until an explicit `BABEL_ALLOW_HOST_FALLBACK` escalation when Docker is missing (its own acknowledged operator-UX gap; `dev_local` exists as the everyday escape hatch). ZCode: permission prompt, optional sandbox, trust in the operator environment. Faster, weaker guarantee, better ergonomics on a machine the operator controls.

### T4 — Session-long work

Context fills over hours. ZCode: automatic summarization carries a compact forward and the agent keeps going; fine detail can blur, and the persistent memory directory carries durable facts across sessions — something Babel has no equivalent of. Babel: this is exactly its H1 hardening wave; its docs candidly record real defects found and fixed (compaction summaries discarded, fallbacks mislabeled as LLM successes). Its mechanism is stricter; ZCode's is older and smoother. ZCode wins on lived experience.

### Meta-result

This report is itself a simulation outcome. It was produced *on* Babel *from inside* ZCode: the instruction package was read, the drift checker replicated, the conformance suite and live golden episode tests run. Babel's own tests served as the evidence for ZCode's claims, and the human was the completion authority over everything reported. That task class — investigate and verify a documented system — is exactly where ZCode's shape shines, and nothing in it needed a kernel.

## 5. Preference (from the agent's seat)

For interactive, supervised work — a human reading the results — the agent prefers **ZCode's harness**: its completion model is *honest about its setting*. When a human is in the loop and can see every diff, a kernel re-verifying claims adds ceremony without adding much certainty. ZCode spends enforcement where the threat is and stays out of the way elsewhere — which is what enables subagent fan-out, background tasks, and momentum.

The preference **flips the moment the human leaves the loop**. Unattended — CI, scheduled runs, an agent trusted with a production repo — "the user will notice" stops being a control, and Babel's core insight becomes the only thing standing between a confident model and a false green: *completion must be decided by deterministic logic outside the model, with evidence bound to the workspace revision it actually verified.*

## 6. Verdict

**Babel is better** at completion integrity, verifier authority, evidence/replay/audit, isolation for untrusted work, and typed failure recovery — the entire *unattended correctness* column. **ZCode is better** at interactive throughput, context management maturity, cross-session memory, orchestration flexibility, and operator experience — the entire *supervised capability* column.

- Babel treats the model as an **untrusted component to be contained**; its weakness is that containment taxes every legitimate task — the cost is paid *always*, for benefit only when things go wrong.
- ZCode treats the model as a **colleague to be directed**; its weakness is that safety is proportional to operator attention — the cost is paid *only* when things go wrong, which is exactly when it can least be afforded.

The fairest successor design is **ZCode's ergonomics with Babel's kernel**: low-ceremony interactive work by default, with a deterministic completion gate and revision-bound evidence that activates whenever a run goes unattended or touches protected paths. Both harnesses would accept that design as their own principle — Babel would call it extending H6 enforcement; ZCode already gestures at it with plan mode, read-only subagents, and its judge agent. The disagreement was never about the principle, only about where "outside the model" should live: **Babel chose a kernel; ZCode chose you.**

## 7. Deep-dive index

| # | Section | Question it answers |
|---|---|---|
| 01 | [Completion authority & terminal outcomes](reports/01-completion-authority.md) | Who is allowed to say "done," and what happens when the model lies? |
| 02 | [Verifier architecture & anti-reward-hacking](reports/02-verifier-architecture.md) | What counts as proof, and who guards the guards? |
| 03 | [Isolation & sandboxing](reports/03-isolation-sandbox.md) | What can the agent's code actually do to the machine? |
| 04 | [Workspace transactions & mutation safety](reports/04-workspace-transactions.md) | What happens when a write goes wrong? |
| 05 | [Task contracts, budgets & failure classification](reports/05-task-contracts-budgets.md) | What is the agent allowed to do, for how long, and at whose cost? |
| 06 | [Context integrity & compaction](reports/06-context-compaction.md) | What survives when the context window fills? |
| 07 | [Evidence, replay & observability](reports/07-evidence-replay.md) | Can you audit and re-run a decision after the fact? |
| 08 | [Orchestration: controllers, modes & subagents](reports/08-orchestration-controllers.md) | Who is actually driving — one loop or many? |
| 09 | [Instruction stacking: Prompt OS vs. system prompt](reports/09-instruction-stacking.md) | How does each harness tell the model what to be? |
| 10 | [Self-governance: how each harness polices itself](reports/10-self-governance.md) | What stops the harness's own rules from drifting? |

## 8. Sources

- Babel repository investigated live at `/home/linuxuser/Babel`, HEAD `82fc080` (2026-09-09); normative spec last verified 2026-08-05, docs last touched 2026-08-22.
- Executed gates: `babel-cli/src/executor/architectureConformance.test.ts` (23/23), `src/agent/episodeReplay.liveGolden.test.ts` (3/3), manual replication of `tools/check-harness-architecture.ps1` (all assertions hold; `pwsh` unavailable locally, so text assertions were checked with grep and file checks directly).
- ZCode side: grounded in the operating environment this report was authored in (tool surface, permission model, subagent protocol, compaction, memory). No proprietary internals beyond what the agent itself can observe are reproduced.
