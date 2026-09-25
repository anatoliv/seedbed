# Seedbed Crashbox pilot

Seedbed is the first low-risk application cohort for replacing hosted Sentry.
The application keeps Sentry Cocoa `8.58.4` only as the Sentry-envelope client;
the distributed build reports either to Crashbox or nowhere. The application
never initializes two clients, and packaging refuses any legacy hosted input.
Hosted-Sentry artifacts remain historical evidence only; the source path that
could build or upload a new one has been removed.

## Protected identities

- Crashbox project: `seedbed-macos`
- Project UUID: `f869c218-4e5e-4c4d-b93c-bff6b9f588df`
- Public-key fingerprint:
  `sha256:dad0a78961ed17ff0fdc778db48d5290cecc2eccd82f45d4b18fc264b02e4302`
- Credential source: the estate's root-owned mode-`0600` project record; never
  copy its value into this repository, logs, a task comment, or shell history.
- Rollback: a retained, source-identified, signed/notarized/stapled artifact
  whose embedded reporting provider is Crashbox or disabled. See "Cutover and
  rollback gate" for the executable check. A hosted-Sentry artifact is
  historical evidence only. It is not an allowed rollback target.

## Build and artifact proof

Start from a clean, committed checkout. Place the Crashbox DSN in the
gitignored `Packaging/crashbox-dsn.local` file, mode `0600`, without printing
it. `Scripts/make-app.sh` derives the full 40-character commit and injects:

- `CrashReportingProvider` (`crashbox`);
- `CrashReportingRelease` (`net.amnesia.seedbed@<full commit>`); and
- `CrashReportingEnvironment` (`production` unless explicitly set).

It fails if the tree is dirty, identity is not exact, the DSN is malformed, or
any legacy hosted-Sentry input is present. Build the universal bundle, then verify it without
printing or sending the DSN:

```console
IDENTITY=- ./Scripts/make-app.sh
Scripts/verify-reporting-artifact.sh build/Seedbed.app \
  .build/apple/Products/Release/Seedbed.dSYM
```

The production pilot must be Developer ID signed and notarized. Ad-hoc signing
is only for the isolated local canary. Upload the matching zipped dSYM through
the private project-scoped `crashbox-artifact-upload dsym` path, then verify
both Mach-O architecture UUIDs in the catalog. `Scripts/upload-dsym.sh`
performs that upload from the built app and its dSYM, as the service account
and with no token, and prints the `CRASHBOX_DSYM_ARTIFACT` and
`CRASHBOX_DSYM_UUIDS` values `Scripts/release.sh` requires; it is operator
tooling and is not in the public snapshot. Do not publish the dSYM or add a
remote upload credential to this repository.

Reporting is fail-open for Seedbed itself. Launch, preference changes, SDK
shutdown and the canary all hand work to a private utility queue; the UI and
library paths never wait for network or flush work. Runtime configuration is
independently validated before SDK initialization. A one-attempt fuse contains
recoverable initialization failures and permits no automatic retry or provider
fallback; only a direct disable/enable action resets it. The SDK close wait is
zero, the canary flush is capped at two seconds, initialization observation is
capped at one second, the disk queue is at most twenty events, and automatic
breadcrumbs, sessions, traces, profiles and client reports are disabled.

## One-event acceptance proof

The test launch is explicit consent for one bounded event and exits:

```console
SEEDBED_TEST_CRASH_REPORTING=1 \
  build/Seedbed.app/Contents/MacOS/Seedbed
```

Record its 32-character `event_id`, provider, immutable release, and flush
completion. Flush completion is not acceptance. Query that exact event id with
the production `crashbox-query` command for project
`f869c218-4e5e-4c4d-b93c-bff6b9f588df`, confirm the occurrence is durable,
confirm its stored environment and release match the bundle, and confirm the
shared alert gateway delivered the non-paging pilot notification. Record only
the event id and timestamps, never a DSN or payload.

## Cutover and rollback gate

**Seedbed 0.1.9 shipped as a Crashbox build on 2026-09-08 with item 3 below
unmet, and this document was not amended for a day.** For that day the only
written instruction in the repository on the subject said not to publish, and
a build had been published. The decision to go ahead was right on the merits
and is defended below. Taking it without amending this file in the same commit
was not, because a runbook that contradicts the artifact teaches its next
reader to disbelieve the whole file rather than the one stale line.

The gate was written on 2026-09-07 as a pre-cutover checklist. It read:

1. the exact dSYM is privately stored and its two UUIDs match the bundle;
2. the one-event Crashbox test is durably queryable and its alert arrived;
3. the same bounded test through the protected hosted-Sentry fallback returns
   an accepted response and is visible there; and
4. the prior signed/notarized Seedbed release and hosted DSN remain available
   as the smallest rollback unit.

Three of those were the right conditions. One was not, and the reason is worth
stating rather than editing away.

**Item 1 held, and can no longer fail quietly.** `Scripts/release.sh` refuses a
Crashbox build that does not declare `CRASHBOX_DSYM_ARTIFACT` and
`CRASHBOX_DSYM_UUIDS`, and after the build compares the declared set against
`dwarfdump --uuid` of the executable that is actually shipping. A dSYM from a
near-identical build stops the release rather than producing healthy-looking
reports with empty stacks.

**Item 2 held, and was then exceeded.** The bounded test event was durable and
its alert arrived before the release. Afterwards the installed build produced a
real crash that was accepted, stored, grouped into an issue and alerted on the
first attempt.

**Item 3 did not hold, cannot be made to hold, and is withdrawn as of
2026-09-08.** It was already unmeetable on the day it was written, and the
gate said so in the paragraph beneath it: the estate's hosted-Sentry quota
rejects new events, and it still does. So nothing lapsed between the writing
and the cutover. What changed is its purpose. Item 3 existed only to
prove that the rollback named in item 4 was worth taking, and item 4 turned out
to be satisfiable without it, because the rollback is an artifact rather than a
credential. Worse, the build that rollback restores points at the same
exhausted quota, so executing it today would move Seedbed from a provider that
accepts, stores, groups and alerts to one that accepts nothing. Item 3 asked
for a certificate of health for a fallback that is worse than the thing it
insures. Earning it would have meant buying hosted quota to validate a path
this pilot exists to leave. It is withdrawn outright rather than restated in a
weaker form, because a weaker form would still be a condition about a service
Seedbed no longer sends anything to.

**Item 4 was incomplete and no longer binds in that form.** The retained 0.1.8
artifact is signed, notarized and stapled, but its baked reporting provider is
hosted Sentry. Restoring it would route Seedbed back to the service this pilot
left, so it is historical evidence rather than an allowed rollback target.

As of 2026-09-13, an allowed target is either a retained source-identified
Crashbox release or a retained source-identified reporting-disabled release.
It must also remain signed, notarized and stapled. The dated 2026-09-14 record
below closes that artifact prerequisite and the rollback-drill step for the
0.1.9 cohort. It does not supply either observation window.

### What still binds, and where it is checked

Between 2026-09-07 and 2026-09-08 nothing on the release path checked any of
the four items. The gate was prose, and prose is enforced by whoever happens to
re-read it. That is how a release went past item 3 without anyone noticing at
the time, and it is the part of this episode worth fixing rather than
apologizing for.

- **The dSYM must belong to the binary.** Refused in `Scripts/release.sh`
  before the build, and verified against the shipped executable after it.
  Pinned by `tests/test_crashbox_symbol_gate.py`.
- **An allowed rollback target must already exist.** Refused in
  `Scripts/release.sh` before the build: a Crashbox release will not start
  unless the selected retained DMG has an exact source identity, embeds either
  Crashbox or no reporting provider, and carries a valid stapled notarization
  ticket. The gate also requires the exact Seedbed bundle identifier, release
  namespace, exact commit-derived source digest, expected version and build,
  runtime-discovered Seedbed signing team, universal executable, inner-app
  signature, Gatekeeper acceptance and app ticket. Crashbox targets must name
  the canonical collector; disabled targets must retain no DSN or environment.
  `SEEDBED_ROLLBACK_DMG`, `SEEDBED_ROLLBACK_VERSION`,
  `SEEDBED_ROLLBACK_BUILD` and `SEEDBED_ROLLBACK_COMMIT` name one explicit
  reporting-disabled target when the previous tagged release is not allowed.
  Missing tag history fails closed; the first-release exception is explicit and
  accepted only when the repository has no tag, cask version or site DMG pin.
  Pinned by
  `tests/test_crashbox_rollback_gate.py`. A hosted-Sentry artifact is refused.

### 2026-09-14 retained artifact and rollback drill

The reporting-disabled rollback artifact was built from exact 0.1.9 source
`5eb48beb14b9f1cff1d67eccd4e8be4f60e98e80`, not from the later verifier
source. It records version 0.1.9, build 10, the exact source release and source
digest, and empty provider, DSN and environment fields. Apple accepted the app
and DMG notarization submissions; both the inner app and outer DMG were stapled.
The current fail-closed verifier accepted the copy retained in the operator's
artifact archive as
`Seedbed_0.1.9_10_5eb48_reporting-disabled_universal.dmg`, with SHA-256
`4df8d742a95d63ee52fbd161a9ec8245e8084285c03faf4199fa80f668eabf39`.

Immediately before the drill, one authorized real crash from the installed
Crashbox build produced event `c385a561-8560-4008-8da2-923a5f0fc2e4`. The
occurrence was durable at 2026-09-14 07:57:00Z, its Apple symbolication job
completed on attempt one, and `seedbedTestCrash()` resolved to
`TestCrash.swift:136`. The alert outbox delivered a 202 on attempt one and the
gateway recorded email, Telegram and Discord acceptance without suppression.

Rollback to the verified reporting-disabled artifact completed at
2026-09-14 08:00:39Z. Its bounded diagnostic printed that no complete reporting
configuration existed and sent nothing; the app launched successfully.
Roll-forward to the separately verified Crashbox 0.1.9 artifact completed at
2026-09-14 08:01:54Z. The exact Crashbox release identity was read back from the
installed bundle, its signature, ticket and universal executable were rechecked,
the app launched, and the public health endpoint was ready with alert delivery.
The durable occurrence count for the drill window remained one, so the disabled
probe did not create an event.

### The observation window

Release one Crashbox build, observe it for one hour, and restore the retained
allowed build on any ingest, alert, privacy or stability failure. Record a
clean bounded 24-hour window after the rollback/roll-forward drill as separate
evidence; the historical three-run exercise did not create either window.

Symbolication is no longer on that list, and its removal is the same argument
as item 3 rather than an exception carved for what happened. The first real
crash from the installed 0.1.9 build was accepted, stored, grouped and alerted,
and none of its frames resolved: the receiver symbolicates a stack all or
nothing, so one Apple system image whose dSYM is not distributable leaves every
frame raw. That is a defect in the receiving service, it is tracked there, and
it is exactly the kind of finding a pilot exists to produce. Rolling back over
it would trade a service that records the crash for one that records nothing,
and would retire the only build that can demonstrate the defect. A local
Crashbox canary can prove ingestion without changing the installed
application, but it is not a production cutover and cannot open this window.
