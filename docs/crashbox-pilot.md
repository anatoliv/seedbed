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
- Hosted rollback: the existing Seedbed hosted-Sentry DSN, retained separately
  as a protected mode-`0600` record. Its value must not coexist with the
  Crashbox input during any build.

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

Do not install or publish the Crashbox build until all of these are true:

1. the exact dSYM is privately stored and its two UUIDs match the bundle;
2. the one-event Crashbox test is durably queryable and its alert arrived;
3. the same bounded test through the protected hosted-Sentry fallback returns
   an accepted response and is visible there; and
4. the prior signed/notarized Seedbed release and hosted DSN remain available
   as the smallest rollback unit.

The estate's hosted-Sentry quota currently rejects new events, so item 3 is a
hard blocker. A local Crashbox canary can prove ingestion without changing the
installed application, but it is not a production cutover and cannot open the
one-hour observation window. After the fallback gate clears, release one
Crashbox build, observe it for one hour, and immediately restore the retained
hosted build on any ingest, alert, symbolication, privacy, or stability failure.
