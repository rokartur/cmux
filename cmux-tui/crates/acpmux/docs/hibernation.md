# Idle harness retirement

Leo, verbatim:

> An idle Claude/Codex session (no turn running, nothing queued) hibernates after 2 minutes. Its process and its MCP sidecars exit, its state is checkpointed, and it wakes on the next prompt or click within about 1 s. Sessions waiting on a person stay cheap too: they keep only the question.

This foundation supplies safe process retirement. The independent scheduling/app
change sets the two-minute default, pressure thresholds, click wake and combined
loading state. Session records and harness conversation IDs survive retirement;
the existing send path records a prompt, resumes/loads the conversation and
replays configuration before delivering it. Resume time depends on the harness;
the one-second target requires measurement and is not a guaranteed deadline.

Retirement signals only a held harness child: TERM, up to 300 ms grace, then KILL
that same unreaped child if needed. It never signals a process group, enumerates
processes or kills descendants. Both leader-exit watchers skip group cleanup for
this path. Explicit Stop retains its separate cleanup behavior.

Detached work that escaped (including setsid servers) is out of scope by design.
It survives because retirement never signals it. Reported background tasks and
subagents veto retirement. A running turn, queued prompt, pending permission or
secret question, and an in-flight request also keep the harness awake. Keeping
only a person's question requires a separate resumable permission protocol; this
foundation preserves existing pending requests.

The daemon has harness launch specifications, not handles for MCP servers the
harness launches. Those servers observe their stdio connection closing; the cmux
MCP broker owns its upstream Child handles and drops them on EOF. This foundation
signals no guessed sidecar PID and promises no bounded exit for an opaque third
party MCP. Sidecar exit must be included in the real-harness RSS measurement.

Host QueryReply optionally advertises an idle activity generation only when its
Claude/Codex translator can report background work. An absent capability, unknown
harness, Windows job, lost link or older host keeps the session awake. Session
turn/request/spawn leases stay held until terminal exit. Activity generations are
checked immediately before signaling; a new request waits and resumes afterward.
The host child owner also fences the requested generation and rejects an expired
retirement. Once committed, the host accepts no new harness lines.

Timers and cleanup:

- The existing single hub idle task ends when the hub drops or shutdown wakes
  it; no new polling task. Ineligible candidates restart their idle deadline.
- Each host query/retirement exchange includes queue insertion and reply under
  its bounded query budget; every outcome removes its pending reply entry.
- A host retirement request expires after 100 ms if its child owner cannot
  commit it. Its acknowledgement has a 500 ms bound; the channel closes on host
  exit. No request can signal after expiration.
- The child owner cancels its 300 ms grace timer when exit wins and reaps before
  releasing its handle. No delayed KILL uses a reaped PID. The existing two-second
  pipe drain bounds completion if surviving work retains stdout/stderr.
- The controller's terminal-exit wait ends on the exit notification or after
  five seconds; timeout never falls back to a group/tree kill.
