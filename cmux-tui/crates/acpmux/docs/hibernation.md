# Idle harness retirement

Leo, verbatim:

> An idle Claude/Codex session (no turn running, nothing queued) hibernates after 2 minutes. Its process and its MCP sidecars exit, its state is checkpointed, and it wakes on the next prompt or click within about 1 s. Sessions waiting on a person stay cheap too: they keep only the question.

This foundation supplies safe retirement; the independent scheduling/app change
sets two-minute defaults, pressure policy, click wake and combined loading. The
session record and conversation ID survive. Send resumes/loads and replays config
before delivery. One-second wake remains a measurement target, not a guarantee.

Retirement sends TERM, then KILL after 300 ms only to the same held, unreaped
harness child. It never scans, signals a group or kills descendants. Both exit
watchers spare the group; explicit Stop keeps its separate cleanup. Detached work
that escaped, including setsid servers, is out of scope and receives no signal.

Running turns, queues, permissions/secret questions, in-flight requests, reported
background tasks/subagents veto retirement. Older/unknown hosts, opaque harnesses,
lost links and Windows jobs stay awake. Session leases and activity generations
fence wake/spawn against retirement. A holder capability reports its generation;
the child owner rechecks before signaling. An uncertain timeout requires an ordered
holder query or terminal exit before reuse. Only the held child owner can signal.

MCP launch specs are not handles. Harness-launched servers observe stdio EOF;
the cmux MCP broker drops its owned upstream Child handles on EOF. No sidecar PID
is guessed, and opaque third-party MCP exit is not bounded by this foundation.
Real-harness RSS measurement must account for any remaining sidecars. Keeping only
a person's question requires a separate resumable permission protocol.

Timers and cleanup:

- The existing single hub idle task ends when shutdown wakes it or the hub drops.
- Query/retirement enqueue and reply share a five-second budget; a guard removes
  pending replies on answer, timeout and caller cancellation.
- Retirement expiry is fixed before enqueue. The child owner has at most 100 ms
  of that remaining budget to commit; expired frames never signal after a wake.
  The 500 ms acknowledgement bound does not authorize reuse after uncertainty.
- Exit cancels the child owner's 300 ms grace timer; it reaps before releasing the
  handle, preventing a delayed KILL of a reused PID. Host shutdown lets grace finish.
- The existing two-second pipe drain bounds output held by surviving work. The
  controller waits for terminal exit for at most five seconds; timeout never falls
  back to group/tree killing and must be reconciled before the child is reused.
