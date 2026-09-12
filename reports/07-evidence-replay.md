# 07 — Evidence, Replay & Observability

**Thesis:** Babel treats "what happened" as a versioned, hash-linked, replayable data subsystem — with an honest PARTIAL label on its consumer story — while ZCode treats the conversation transcript as the only evidence: always truthful and free to maintain, but unqueryable, unreplayable, integrity-unbound, and unable to hand a machine a terminal decision.

## Scope

This section audits whether a run's decisions can be reconstructed *after the fact*, by *someone who was not there*, without re-running the model. For Babel (read-only repo at `/home/linuxuser/Babel`): the multi-stream evidence architecture (harness-v1 §6.10, invariant H15), corrupt-stream quarantine and active/degraded persistence status, the H6 replay story (`episodeReplay.ts`, `runLiveControllerGoldenEpisode`), and the simulated-vs-live golden fixture discipline. For ZCode: the transcript-as-record model as directly observable from my own operating environment (I am running inside it). I ran Babel's live golden test as primary evidence. Excluded: completion-authority logic (section 01) and verifier internals (section 02) except where they emit evidence.

## How Babel does it

### Multi-stream evidence reality

Babel persists more than one evidence stream per run, on purpose (normative table in `docs/architecture/HARNESS_ARCHITECTURE_V1.md` §6.10):

| Stream | Surface | Owner |
|---|---|---|
| `thread_events.json` | Chat | `threadEventLog` |
| `session-events.jsonl` | Chat | `sessionEvents` |
| `episode-events.jsonl` | Chat + pipeline | `evidence/episodeStream.ts`, `pipeline/pipelineEpisodeSink.ts` |
| EvidenceBundle JSON | Pipeline (**authoritative**) | `evidence.ts` |
| Effect ledger | Mutations | `effectLedger` |

The canonical unit is `CanonicalExecutorEvent` (`babel-cli/src/executor/contracts.ts`): `schemaVersion`, `eventId`, `sessionId`, `turnId`, `seq`, `ts`, one of eight `kind` values (`session | turn | tool | mutation | progress | verifier | completion | recovery`), a `type`, and a payload. H15 ("Evidence schemas MUST be versioned") is labeled **IMPLEMENTED** — every event carries `schemaVersion: typeof EXECUTOR_EVENT_SCHEMA_VERSION`, so a consumer a year from now knows which contract it is reading. The episode layer extends this envelope with `prevHash` — the SHA-256 of the previous serialized JSON line (`episodeStream.ts`, `EpisodeEvent`) — a hash chain that makes silent mid-stream tampering detectable.

Degradation is a first-class state, not a silent failure. `PipelineEpisodeSink` exposes `status: 'active' | 'degraded'`; once an IO error flips it to `degraded`, further appends stop and a warning is written into the run's evidence as `episode_persistence_warning.json` with `status: 'degraded'`. On the read side, `loadOrQuarantineEpisodeLog` fail-closes: a corrupt or hash-invalid stream is renamed to `episode-events.corrupt.<timestamp>-<uuid>.jsonl` and resume is refused ("Episode stream was quarantined after validation failure; resume is fail-closed"). You get a typed error code (`invalid_chain`, `malformed`, `session_mismatch`) rather than a truncated log that looks fine.

### The H6 replay story — and its honest PARTIAL

`babel-cli/src/agent/episodeReplay.ts` implements the replay contract:

- `replayTerminalDecision(sessionLog)` re-derives the terminal outcome from durable session events only — no model call — via `projectLiveSession` + `reconstructTerminalFromSession`. The result carries `invented: false` and a `source` of `session_completion_decision` or `session_turn_ended`; if the events do not contain a terminal, it returns `null`. It never invents an outcome from absence.
- `projectCrossSurfaceFacts` builds the TUI, headless-JSON, persistence, and CLI-status projections from the same log and asserts they agree — the harness's own answer to "the UI said pass but the log said fail."
- `GoldenEpisodeArtifact` (`schema_version: 1`, `content_hash` = SHA-256 of the serialized events) has `live_runtime: input.live_runtime === true` — the flag is provably impossible to hard-code true; `validateGoldenEpisode` re-parses the events, re-hashes, re-replays, and fails on `content_hash_mismatch`, `terminal_mismatch`, or `replay_invented_events`.

The exit-gate path, `runLiveControllerGoldenEpisode`, is not a hand-built fixture restore: it constructs a real `ChatEngine`, runs `submitMessage` on a real temp workspace with a mock native-tools runner (no external API), asserts the events were *controller-produced* (`user_submitted`, `turn_ended`/`completion_decision`, `assistant_tool_calls`, `tool_result`), harvests a `live_runtime: true` golden, and replays it model-free to the same terminal decision plus cross-surface agreement.

**I ran it.** `cd babel-cli && npx tsx --test src/agent/episodeReplay.liveGolden.test.ts`:

```
✔ one command: ChatEngine + real workspace → live_runtime golden + model-free replay (3051ms)
✔ complete-only path still produces controller terminal events and valid golden (47ms)
✔ restores benchmark approval when initially absent or preconfigured (64ms)
tests 3 · pass 3 · fail 0 · duration_ms 5359
```

One command, ~3 seconds, and a real controller run is proven replayable. That is the strongest single artifact in this comparison.

The roadmap (`docs/architecture/HARNESS_HARDENING_ROADMAP_V1.md` wave H6) still labels this **PARTIAL**, and the labels are specific: cross-surface proof "is still projection-based rather than exercising every consumer" (the four views are projected from one log; the real TUI is not yet parsed against it); full TUI scrollback and indexed long-session loading are residual product UX; the EvidenceBundle remains authoritative on the pipeline when episode persistence degrades; phase instrumentation and offline integration still need release-gate verification. Roadmap discipline explicitly rejects "calling a simulated contract fixture an end-to-end runtime proof."

### Golden fixture discipline

`examples/golden-harness/README.md` is a case study in not lying with fixtures. The episode event sequence (`fixture/expected-events.jsonl`, from `TASK_CONTRACT_FROZEN` through `VERIFIED_COMPLETE`) is labeled **Simulated fixtures** — "not produced by a live controller run" — in an explicit table that marks only the kernel/honesty/isolation slices as **Live**. The README ends: "Do not point live product claims at simulated events without labeling them simulated." The distinction is enforced structurally: a simulated golden cannot claim `live_runtime: true`, because the builder defaults the flag false and only a real controller harvest path sets it.

## How ZCode does it

ZCode's durable record of a run is the conversation transcript itself. Everything I do — tool calls with their descriptions and results, file edits, my reasoning, my final report — exists as conversation turns that the user can scroll, read, and review. There is also `TodoWrite`, a live task list (content, `pending | in_progress | completed`, priority) rendered as a working plan; it is excellent for *progress* observability mid-run, but it is task status, not evidence — it records "what I claim I'm doing," not verified effects.

That is the entire evidence model. Concretely, from inside:

- **No hash-linked event stream.** Nothing binds turn N to turn N+1. Nothing can detect that a transcript was edited, truncated, or partially lost.
- **No machine-readable terminal outcome.** When I finish, the harness relays my final prose. There is no typed record distinguishing "verified by executing tests" from "I believe it works." The outcome exists only as English.
- **No model-free replay.** Re-deriving why I made a final decision requires re-reading the conversation with a model (or a human). You cannot reconstruct the decision from persisted events without the conversation itself.
- **Summarization is lossy by design.** Long transcripts are summarized to fit context. The summary is user-visible and honest about being a summary, but exact commands, outputs, and hashes are compressed into prose and then the detail is gone.
- **No downstream consumption path.** There is no schema for CI, compliance tooling, or a dashboard to assert against. Exit code and transcript are all a machine gets.

The strengths are real and worth stating fairly: the transcript is *always* the truth (it is the actual conversation, not a projection of it), it is immediately human-readable with zero tooling, it can never disagree with itself the way Babel's four surfaces theoretically could, and it costs zero schema maintenance — no versioning, no conformance tests, no quarantine logic to build. For a single engineer asking "what did the agent just do?", it is the fastest answer available.

## Head-to-head

| Dimension | Babel | ZCode |
|---|---|---|
| Primary record | `session-events.jsonl` + `thread_events.json` + `episode-events.jsonl` (+ pipeline EvidenceBundle, effect ledger) | Conversation transcript (+ TodoWrite task list) |
| Schema & versioning | Versioned (`CanonicalExecutorEvent.schemaVersion`, H15 IMPLEMENTED); change requires conformance tests | None; zero maintenance, zero guarantees |
| Integrity binding | `prevHash` chain; SHA-256 `content_hash` on golden artifact; corruption → typed quarantine file, fail-closed resume | None; edits/losses undetectable |
| Terminal decision as data | Yes — `completion_decision`/`turn_ended` events; `TerminalOutcome` taxonomy (`agentContracts.ts`) | No — outcome is prose in the final message |
| Model-free replay | Yes — `replayTerminalDecision` re-derives the terminal from events; proven live against a real ChatEngine (3/3 tests pass) | No — requires re-reading the conversation |
| Cross-surface consistency | Enforced in code (`projectCrossSurfaceFacts`), PARTIAL: projection-based, real TUI consumer unexercised | Trivially consistent — only one surface exists |
| Queryability | JSONL: "all verifier attempts in run X" is a filter | Grep at best; semantic questions need a model |
| Degradation visibility | Explicit `active \| degraded` status, quarantine artifacts, warnings written to evidence | N/A — summarization quietly (though visibly) drops detail |
| Human readability | Requires tooling to interpret streams | Best-in-class; readable by anyone immediately |
| Maturity honesty | Roadmap labels PARTIAL with named residuals | Unlabeled; the limits simply are |

The prose underneath the table: Babel's model is an *engineering subsystem* with its own invariants, tests, and failure modes; ZCode's is a *byproduct* that happens to be reviewable. Babel pays ongoing schema-maintenance and consistency costs and still has unfinished consumers; ZCode pays nothing and therefore has nothing — no audit, no gating, no compliance story beyond "read the chat log." Note the asymmetry in the integrity row: Babel can prove its golden episode was not altered (hash re-validation) and can prove replay did not invent events; ZCode cannot prove anything about its own record, including that it is complete.

## Simulation vignette

**Scenario:** An agent's merged PR caused a production regression. A week later you must reconstruct what the agent did and why it claimed success.

**With Babel.** You locate the run directory and read `session-events.jsonl` / `episode-events.jsonl`. The event kinds answer mechanical questions without any model: `tool_proposed` → `tool_started` → `tool_completed` gives the exact files touched and commands run with payloads; `mutation_batch` entries tie writes to the effect ledger and workspace revision identity; `verifier_attempt` gives the exact verifier command, its exit code, and (via H7/H8 revision binding) which revision it evaluated; `gate_decision` and `completion_decision` show what the model *proposed* and what the kernel *decided* — including the critical case where the model claimed done without a green verifier and the harness downgraded to `UNVERIFIED_PATCH`. You can run `replayTerminalDecision` over the persisted log and confirm the recorded outcome re-derives exactly, `invented: false`. If the stream is corrupt, you find `episode-events.corrupt.<ts>.jsonl` and a typed error — damaged evidence announces itself. Honest caveats from Babel's own labels: the pipeline run's authoritative artifact may be the EvidenceBundle rather than the episode stream (if the sink degraded, there is a `episode_persistence_warning.json` saying so); cross-surface agreement is projection-based; phase instrumentation is still awaiting release-gate verification. And note what this cannot do: it proves what the harness *verified*, not that the tests themselves were adequate — weak oracles get faithfully recorded as green.

**With ZCode.** You open the transcript. If the session was short, you can likely read the actual tool calls, see which files were edited, and find the command the agent ran and its output. That is genuinely useful and costs nothing. But three failure modes are structural. First, if the session was long, the early turns exist only as a summary — "ran the test suite, all green" — and the exact command, its scope (full suite vs. the one new test file?), and its output are unrecoverable. Second, "why it claimed success" has no data answer: the agent's final message asserting the fix works is indistinguishable, as a record, from one backed by executed verification; you audit prose with judgment, not evidence with code. Third, there is nothing to integrate: your incident-review tooling cannot enumerate the files touched across the agent's 50 runs last week, cannot assert in CI that agent PRs carry green verification records, and cannot demonstrate to a compliance reviewer that the record was not modified after the fact. Git tells you *what* changed in the repo; the transcript, at best, tells you *why* — but only as much of it as survived.

## Verdict

**Babel is better at the actual job of this section** — post-hoc re-derivation — and it is not close. The combination of versioned events (H15), a hash chain, quarantine-with-fail-closed, explicit degraded status, and a model-free replay that a real controller run demonstrably passes (I ran it: 3/3) makes "audit a decision a week later" a mechanical operation. Just as important, its honesty is verifiable: the PARTIAL labels name exactly which consumer promises are not yet kept, and the simulated/live fixture boundary is enforced by a flag that cannot be hard-coded true. The residual gap that matters most is that cross-surface replay is still projection-based — Babel proves four *projections* agree, not yet that the shipped TUI agrees with the log.

**ZCode's transcript is not worthless** — for immediate human review it is the best artifact in either harness, and it has no consistency or maintenance cost. But it loses nearly every use case where evidence must work *without a human reading it*: post-incident audit past the summarization horizon, CI gating, compliance-grade integrity, false-completion-rate measurement, and cross-run queryability. By not recording terminal decisions as data, ZCode makes "did the harness verify this?" permanently unanswerable except by asking the model that made the claim.

**What each should adopt:**

- **Babel:** finish H6 as written — exercise the real TUI/headless consumers against persisted logs rather than projections, ship indexed long-session loading, and get phase instrumentation through release-gate verification. Keep the EvidenceBundle-authoritative-on-degradation rule documented until episode replay is provably complete.
- **ZCode:** adopt the minimal Babel-shaped slice. Persist one machine-readable terminal record per run — typed outcome, verifier evidence references, workspace revision hash — under a versioned schema from day one (H15 costs nothing at v1 and everything retrofit). Hash-pin or hash-link the transcript so integrity is checkable. Keep summaries as additive overlays on retained raw events, never replacements. Any one of these would unlock CI gating and incident audit; the terminal-outcome record is the highest-leverage single change.

## Key sources

- `/home/linuxuser/Babel/docs/architecture/HARNESS_ARCHITECTURE_V1.md` — §6.10 evidence architecture (stream table, `CanonicalExecutorEvent` seq + schemaVersion, active/degraded, EvidenceBundle authority), §6.3 subsystem 9 maturity, invariant H15
- `/home/linuxuser/Babel/docs/architecture/HARNESS_HARDENING_ROADMAP_V1.md` — wave H6 (PARTIAL status, replay consumers, live golden episode, residuals and exit gates), §3 rejected-evidence rules
- `/home/linuxuser/Babel/examples/golden-harness/README.md` — simulated vs. live labeling table, "do not point live claims at simulated events"
- `/home/linuxuser/Babel/babel-cli/src/agent/episodeReplay.ts` — `replayTerminalDecision`, `projectCrossSurfaceFacts`, `GoldenEpisodeArtifact` (`live_runtime` never hard-coded), `runLiveControllerGoldenEpisode`
- `/home/linuxuser/Babel/babel-cli/src/agent/episodeReplay.liveGolden.test.ts` — the live golden test I executed (3 pass / 0 fail)
- `/home/linuxuser/Babel/babel-cli/src/evidence/episodeStream.ts` — hash-linked append, typed error codes, corrupt-stream quarantine, fail-closed resume
- `/home/linuxuser/Babel/babel-cli/src/executor/contracts.ts` — `CanonicalExecutorEvent`, `CompletionDecision`, `EXECUTOR_EVENT_SCHEMA_VERSION`
- `/home/linuxuser/Babel/babel-cli/src/pipeline/pipelineEpisodeSink.ts` and `pipelineEpisodeLifecycle.ts` — `'active' | 'degraded'` status, `episode_persistence_warning.json`
- ZCode side: direct observation of my own operating environment (transcript as durable record, TodoWrite task list, absence of event stream / terminal-outcome data / replay)
