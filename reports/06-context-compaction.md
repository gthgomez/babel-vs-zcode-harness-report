# 06 — Context Integrity & Compaction

**Thesis:** Babel treats compaction as a correctness problem — a commit protocol with a durable capsule, a budget snapshot, and honest failure states (unit-proven, live-unproven) — while ZCode treats it as a usability problem — invisible auto-summarization plus a cross-session memory directory that is battle-tested but carries no survivability contract; Babel is the better memory *inside* a session, ZCode the better memory *across* them.

## Scope

What survives when the context window fills, and whether the agent can trust its own memory of the task. Babel side: the H1 hardening wave ("Context integrity and compaction correctness") from `docs/architecture/HARNESS_HARDENING_ROADMAP_V1.md`, subsystem 2 of `HARNESS_ARCHITECTURE_V1.md`, and the compaction code/tests under `babel-cli/src/agent/`. ZCode side: described from this analyst's own operating environment — automatic context summarization, the persistent memory directory, and the `ReadSessionContext` retrieval mechanism. Out of scope: verifier architecture (report 02), budgets as abort policy (report 05), episode replay (report 07).

## How Babel does it

### The pre-H1 story (the honesty baseline)

`HARNESS_HARDENING_ROADMAP_V1.md` (§H1, status **PARTIAL**) opens with the admission that the pre-H1 live path "could report successful compaction while losing the generated summary and leaving durable provider history unchanged." Six defects are listed as closed (each struck through in the doc, mapped to its fix):

1. **Summary discarded** — `LLMSummarizeCompaction`'s output was thrown away during `compactIfNeeded` reconstruction → fixed by `assembleCompactedConversation`, which preserves the `compaction_summary` message alongside the capsule (`babel-cli/src/agent/compactionCommit.ts`).
2. **Fake fallback** — an LLM failure returned a `compaction_fallback` message that blocked the manager's fallback chain → the strategy now rethrows; `CompactionManager.compactWithResult` advances to `heuristic-truncation` (`chatCompaction.ts`).
3. **No durable write** — compaction was memory-only; nothing was persisted → `commitCompaction` dual-writes a `compaction_capsule` thread event and a `compaction_created`/`compaction_committed` session event.
4. **Lying strategy label** — manager success was always labeled `llm` → `compactWithResult` returns the authoritative strategy id of the strategy that actually ran; `strategyToCompactMode` maps it.
5. **Wrong summarizer model** — the model *family* string was passed as an API model id → `resolveCompactionModelId` prefers explicit override / `BABEL_COMPACTION_MODEL` / provider model id, and never a bare family.
6. **Incomplete token contract** → `ContextBudgetSnapshot` plus an expanded deterministic `CompactionCapsule`.

### The current mechanism

Compaction is a two-layer design in `babel-cli/src/agent/chatCompaction.ts` and `compactionCommit.ts`:

- **Trigger and strategies.** `runChatEngineCompaction` fires when the token estimate crosses the model-aware threshold or `maxEstimatedTokens − reserve` (defaults: 128k budget, ~8k reserve, `config/chatEngineLimits.ts`; env-clamped 4k–200k). The `CompactionManager` tries `LLMSummarizeCompaction` (structured `KEY_DECISIONS / CODE_CHANGES / TOOLS_USED / UNRESOLVED / CONTEXT` summary from a cheap model, 30s timeout, circuit-breaker after 3 consecutive failures) and falls back to `HeuristicTruncationStrategy` (keep system prompt + last ~4 messages, preserve tool-call pairs at the boundary).
- **The commit protocol.** `commitCompaction` is the single recoverable operation. It builds the capsule, assembles the new conversation (base system → `compaction_summary` → `compaction_capsule` → working set), then writes: session events `compaction_started` / `compaction_summary` (with SHA-256 capsule digest and `rawObservationRefs`) / `compaction_committed`, the thread `compaction_capsule` event, and finally the checkpoint via a `persist` hook. Any persistence failure yields `degraded_persistence` or `blocked_persistence` — never silent divergence. The ChatEngine host passes `blockOnPersistFailure: true`, rolls back thread/session log appends, and throws `CompactionPersistenceError` on a non-committed result.
- **The capsule.** `buildCompactionCapsule` (`agent/providerCapabilities.ts`) is deterministic, not model-generated: task and task-acceptance id, current plan step, changed paths (≤64), unresolved failures, verifier summary *and freshness* (bound workspace revision or "unbound"), approvals, budget summary, workspace revision, evidence refs, last 8 tool results, and up to 32 content-hash `obs:` references to raw observations dropped from the window. `buildDurableCapsuleContent` embeds the LLM summary into the durable capsule text so live post-compaction and cold-resume provider messages are equivalent — this equivalence is asserted in `compactionCommit.test.ts` ("live≡rebuild"), along with repeated-commit latest-capsule-wins, degraded/blocked persistence, and tool-pairing checks.
- **The budget snapshot.** `ContextBudgetSnapshot` records next-request tokens, system/tool reserve, active window, canonical-state tokens, retrieved context, output reserve, and headroom against the model window — one object an operator can log and compare across turns.
- **The measurement hook.** `measureCriticalFactRetention` scores the fraction of required facts (literal substrings) present in compacted text — the H1 exit-gate metric for long-session fixtures.

Verified locally: `compactionCommit.test.ts` 17/17, `chatCompaction.test.ts` 66/66, `liveSession.failClosed.test.ts` 4/4 (strict authority load, all-or-nothing multi-artifact checkpoint with backup rollback, crash-boundary recovery).

### The residual, honestly labeled

The roadmap says it directly: **PARTIAL** — "multi-artifact atomic checkpoint unit-proven; live long-session evidence remains open." Exit gates like "critical-fact retention and token reduction are measured on long-session fixtures" are fixture-proven, not field-proven. The architecture doc's gap line for subsystem 2 ("full ChatEngine dual-write of every H2 budget event on all paths") is similarly candid. Underlying accepted principles (roadmap §3): *"The complete transcript belongs in durable storage; the model receives a curated working set plus canonical state"* and *"Exact path, symbol, command, hash, and event recovery precedes vector or semantic memory."* Babel deliberately ships no vector/semantic memory at all.

## How ZCode does it

ZCode's compaction is the opposite engineering posture: mature, invisible, and contract-free.

**Auto-summarization.** When the conversation grows long, the harness automatically summarizes some or all of the current context and carries the summary into the next context window; the agent keeps working instead of wrapping up early. From the agent's seat this is undetectable as an event: there is no capsule object, no `ContextBudgetSnapshot`, no compaction event, no degraded/blocked status, and no API through which the agent (or a test) can assert "this fact survived." Survival of any specific detail — a file path, an error string, a one-time constraint — is at the summarizer's discretion.

**Persistent memory directory.** ZCode maintains a memory directory across sessions: an index file loaded each session plus per-fact files. Anything written there is durable, agent-authored learning — constraints, project quirks, user preferences — re-presented at the start of every future session. This is a genuine cross-session learning loop.

**`ReadSessionContext`.** A tool that pulls context from prior persisted sessions by session id, with a focused natural-language query, a relevance-vs-handoff strategy, and a token cap. It makes past-session detail retrievable on demand — but only when the current agent knows to ask, and what comes back is retrieved prose, not a guaranteed-intact record.

**Real-world failure modes.** Because there is no contract, the characteristic ZCode failures are: (a) *lost fine detail* — exact error text, symbol names, or a file list from an hour ago gets compressed to a gist, and the agent re-reads and re-derives them (wasteful but usually self-healing, since the worktree is ground truth); (b) *drifted constraints* — a rule stated once early ("never touch the migration folder") softens into "careful around migrations" or vanishes; the agent then violates it silently; (c) *re-derived facts* — conclusions recomputed differently after compaction, occasionally contradicting the earlier derivation. Detection of all three is incidental: a diff review, a failing check, or a user noticing. The memory directory mitigates (b) *across* sessions if the constraint was ever written down — but within a single long session, the summary is the only mechanism, and nothing prompts the agent to persist a constraint at the moment it is stated.

## Head-to-head

| Dimension | Babel (H1) | ZCode |
|---|---|---|
| Trigger | Explicit token estimate vs clamped budget (`chatEngineLimits.ts`) | Opaque, automatic |
| What survives | LLM structured summary + deterministic capsule + working set | Free-form summary + working set |
| State fidelity | Capsule pins task/acceptance id, changed paths, verifier freshness, workspace revision, budget state | Summarizer's discretion |
| Durability contract | Dual-write thread + session events, capsule digest, `obs:` refs to dropped raw observations | None exposed |
| Failure behavior | `degraded_persistence` / `blocked_persistence`; ChatEngine throws and rolls back | Silent by design |
| Crash/cold-resume | live ≡ rebuild asserted in tests; durable capsule embedded with summary | Session transcripts persist, but no committed-compaction capsule to rebuild from |
| Loss detection | Explicit statuses + `measureCriticalFactRetention` (fixtures) | Incidental (diff review, user, failing checks) |
| Cross-session memory | None agent-written (project/task overlays are human-curated static markdown) | Memory directory (index + per-fact files) + `ReadSessionContext` |
| Maturity evidence | 87 unit tests green across three suites; live long-session exit gates **unproven** (self-labeled PARTIAL) | Field-tested at scale; zero formal guarantees |
| Auditability | Every compaction reconstructible from the event log with digests | Not reconstructible from within the agent's view |

Prose: Babel's design answers "can the agent trust its memory?" with *machinery* — a capsule whose fields are filled from harness state (git revision, verifier receipts, write counts), not from the summarizer's prose, so the claims most likely to drift are exactly the ones that cannot drift. ZCode answers with *ecology* — an always-on summarizer plus a memory layer that accumulates knowledge across sessions, which Babel simply does not have; Babel's nearest analog, `05_Project_Overlays/` and `06_Task_Overlays/`, is a library of example markdown a human curates, not something the agent learns into. The trade is symmetry itself: Babel can prove what the model knew and cannot learn across runs; ZCode can learn across runs and cannot prove what the model knew.

## Simulation vignette

A multi-hour refactor of a payments service. Early on the user says: "never touch the migration folder — the ORM owns it." Forty turns later the context fills.

**Babel.** `runChatEngineCompaction` triggers; the LLM summarizer compresses turns 1–36 into a structured summary; `commitCompaction` builds the capsule. What survives *by construction*: task identity, `changedPaths` (every file written this session — so if anything under `migrations/` was already touched, it is on the record), `workspaceRevision`, `verifierFreshness` (last green test bound to a revision), unresolved failures, and the last 8 tool results. What survives *probabilistically*: the constraint itself — it lives only if the summarizer captured it under `KEY_DECISIONS`/`UNRESOLVED`. Loss detection: the commit path is loud (persistence failure ⇒ `CompactionPersistenceError`, no silent divergence), and the capsule's exact fields let the agent re-derive ground truth (`git status`, re-grep the summary) against pinned claims. Critically, Babel offers a second line of defense outside memory: the same "never touch" rule belongs in protected-path policy, where H4 fails closed rather than hoping the summary remembers.

**ZCode.** The harness auto-summarizes. Likely outcome: the refactor gist, recent file edits, and current plan step survive; the migration-folder rule — stated once, ninety minutes ago, never repeated — has maybe a 50/50 chance of appearing in any form. The agent keeps working smoothly. If the constraint died, the failure surfaces much later: a diff review shows `migrations/0042_add_index.sql` modified, or CI fails on migration checksums. Detection is post-hoc and external. Mitigations that exist: the agent may have written the constraint to the memory directory when it was stated (then it is re-loaded next session — but does not protect *this* session's post-compaction turns), and `ReadSessionContext` can recover the original wording from the transcript if anyone thinks to query it after the damage.

Net: in Babel the loss, if it happens, is *detectable and bounded* (capsule + event log + policy layer); in ZCode it is *smooth and unbounded* (nothing breaks until the worktree does).

## Verdict

**Better inside a session: Babel.** Compaction-as-commit-protocol is the right shape for long autonomous runs: the deterministic capsule removes drift from exactly the claims (changed paths, revisions, verifier state) that matter for correctness; dual-write with digests makes every compaction auditable; fail-closed persistence converts "silent memory corruption" into a loud error. The six closed defects are a model of harness-hardening honesty — each fix unit-tested, and the residual (live long-session exit gates unproven) is printed on the label rather than discovered by the user.

**Better across sessions, and better today: ZCode.** The memory directory plus `ReadSessionContext` is a capability Babel entirely lacks — Babel's overlays are static prose, and its exact-recovery-first principle explicitly defers any learning layer. ZCode's invisible compaction is also field-proven at a scale Babel's fixture-proven commit path has not reached. Its weakness is the missing contract: nothing lets an agent or operator assert that a constraint must survive, and every failure mode (detail loss, constraint drift, re-derivation) is detected only by its consequences.

**Each should adopt:**
- *Babel from ZCode:* an agent-writable cross-session memory store (index + fact files), with capsule digests as the integrity mechanism — the natural fusion of its "exact recovery first" principle with ZCode's learning loop; plus actual live long-session evidence for the H1 exit gates (retention/token metrics on real runs, not fixtures).
- *ZCode from Babel:* a pinned-facts mechanism — let the agent mark constraints as must-survive and verify them post-compaction (Babel's `measureCriticalFactRetention` is the right primitive); an explicit compaction event with before/after tokens so loss is at least observable; and a deterministic state capsule (task identity, changed paths, workspace revision) so cold-resume and post-compaction context are provably equivalent rather than hopefully similar.

## Key sources

- `/home/linuxuser/Babel/docs/architecture/HARNESS_HARDENING_ROADMAP_V1.md` — wave H1 (status PARTIAL, six closed pre-H1 defects, exit gates), accepted principles §3
- `/home/linuxuser/Babel/docs/architecture/HARNESS_ARCHITECTURE_V1.md` — subsystem 2 "Context and Instruction Compiler"
- `/home/linuxuser/Babel/babel-cli/src/agent/compactionCommit.ts` — `commitCompaction`, `assembleCompactedConversation`, `runChatEngineCompaction`, `measureCriticalFactRetention`, `CompactionPersistenceError`
- `/home/linuxuser/Babel/babel-cli/src/agent/chatCompaction.ts` — `CompactionManager`, `LLMSummarizeCompaction`, `HeuristicTruncationStrategy`, `resolveCompactionModelId`
- `/home/linuxuser/Babel/babel-cli/src/agent/providerCapabilities.ts` — `CompactionCapsule`, `ContextBudgetSnapshot`, `computeContextBudget`
- `/home/linuxuser/Babel/babel-cli/src/config/chatEngineLimits.ts` — budget defaults and env clamps
- Tests: `/home/linuxuser/Babel/babel-cli/src/agent/compactionCommit.test.ts` (17 pass), `chatCompaction.test.ts` (66 pass), `liveSession.failClosed.test.ts` (4 pass) — all executed locally
- `/home/linuxuser/Babel/05_Project_Overlays/`, `/home/linuxuser/Babel/06_Task_Overlays/` — Babel's human-curated overlay analog
- ZCode side: this analyst's operating environment (auto-summarization, memory directory, `ReadSessionContext` tool)
