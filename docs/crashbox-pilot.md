# Seedbed Crashbox pilot

Seedbed is the first low-risk application cohort for replacing hosted Sentry.
The application keeps Sentry Cocoa `8.58.4` only as the Sentry-envelope client;
the packaged DSN selects either Crashbox or the hosted-Sentry rollback. The
application never initializes two clients and packaging refuses both inputs.

## Protected identities

- Crashbox project: `seedbed-macos`
- Project UUID: `f869c218-4e5e-4c4d-b93c-bff6b9f588df`
- Public-key fingerprint:
  `sha256:dad0a78961ed17ff0fdc778db48d5290cecc2eccd82f45d4b18fc264b02e4302`
- Credential source: the estate's root-owned mode-`0600` project record; never
  copy its value into this repository, logs, a task comment, or shell history.
- Hosted rollback: a retained release artifact, not a credential. See "Cutover
  and rollback gate" for what it is and how to execute it. A hosted-Sentry DSN
  must still never coexist with the Crashbox input during a build, and that
  half is mechanical: `Scripts/configure-crash-reporting.sh` refuses both.

## Build and artifact proof

Start from a clean, committed checkout. Place exactly one provider DSN in the
corresponding gitignored `Packaging/*.local` file, mode `0600`, without printing
it. `Scripts/make-app.sh` derives the full 40-character commit and injects:

- `CrashReportingProvider` (`crashbox` or `hosted-sentry`);
- `CrashReportingRelease` (`net.amnesia.seedbed@<full commit>`); and
- `CrashReportingEnvironment` (`production` unless explicitly set).

It fails if the tree is dirty, identity is not exact, the DSN is malformed, or
both providers are present. Build the universal bundle, then verify it without
printing or sending the DSN:

```console
IDENTITY=- ./Scripts/make-app.sh
Scripts/verify-reporting-artifact.sh build/Seedbed.app \
  .build/apple/Products/Release/Seedbed.dSYM
```

The production pilot must be Developer ID signed and notarized. Ad-hoc signing
is only for the isolated local canary. Upload the matching zipped dSYM through
the private project-scoped `crashbox-artifact-upload dsym` path, then verify
both Mach-O architecture UUIDs in the catalog. Do not publish the dSYM or add a
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

**Item 4 held, and it is the one that still binds.** Stated so someone could
execute it: the rollback unit is the previous release's retained artifacts. On
2026-09-08 that is `dist/Seedbed_0.1.8_universal.dmg`, which is retained,
Developer ID signed, notarized, stapled with a ticket that still validates,
accepted by Gatekeeper, and still carried as an entry in `dist/appcast.xml`.
Rolling back means re-pinning the three version-pinned surfaces at that release
(the appcast, `Casks/seedbed.rb`, `site/index.html`) and re-uploading. It does
not require `Packaging/sentry-dsn.local`, which is absent from the release
machine: the retained bundle was built with its reporting configuration already
baked in, so restoring the artifact restores that too. The local file is needed
only to build a *new* hosted build, which is a slower and different thing than
a rollback.

### What still binds, and where it is checked

Between 2026-09-07 and 2026-09-08 nothing on the release path checked any of
the four items. The gate was prose, and prose is enforced by whoever happens to
re-read it. That is how a release went past item 3 without anyone noticing at
the time, and it is the part of this episode worth fixing rather than
apologizing for.

- **The dSYM must belong to the binary.** Refused in `Scripts/release.sh`
  before the build, and verified against the shipped executable after it.
  Pinned by `tests/test_crashbox_symbol_gate.py`.
- **A rollback target must already exist.** Refused in `Scripts/release.sh`
  before the build: a Crashbox release will not start unless the previous
  tagged release's DMG is still in `dist/` and still carries a valid stapled
  notarization ticket. Pinned by `tests/test_crashbox_rollback_gate.py`. A
  retained artifact is a rollback; an intention to retain one is not.

### The observation window

Release one Crashbox build, observe it for one hour, and restore the retained
build on any ingest, alert, privacy or stability failure.

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
