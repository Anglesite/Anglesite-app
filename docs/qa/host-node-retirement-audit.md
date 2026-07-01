# Host Node Retirement Audit

**Issues:** [#59](https://github.com/Anglesite/Anglesite-app/issues/59), [#70](https://github.com/Anglesite/Anglesite-app/issues/70)  
**Scope:** Phase 4 pre-retirement checklist for the embedded host Node path.

## Purpose

The app still needs the host subprocess runtime until the local and remote container runtimes are
proven end to end. This audit keeps that transitional surface visible so #70 can become a mechanical
cleanup instead of a treasure hunt.

Run:

```sh
scripts/audit-host-node-retirement.sh
```

Expected today:

- The command exits 0.
- It lists the remaining host-side Node dependencies, including vendor scripts, Node entitlements,
  Xcode build phases, `NodeRuntime`, `LocalSiteRuntime`, `InProcessBackend`, and the MCP stdio spawn
  path.

## Retirement Gate

After #66 and #69 have live end-to-end coverage and no platform depends on `LocalSiteRuntime`, run:

```sh
scripts/audit-host-node-retirement.sh --expect-retired
```

Expected after #70 cleanup:

- The command exits 0.
- It prints `No tracked host-side Node dependencies remain.`

Fail if `--expect-retired` exits 0 before container runtimes are the only execution paths, or if it
still reports tracked dependencies after #70 cleanup.

## Evidence To Record On #70

- Commit or PR that removes each tracked dependency.
- Output of `scripts/audit-host-node-retirement.sh --expect-retired`.
- Confirmation that the app build no longer runs the Node vendor/re-sign phases.
- Confirmation that app entitlements no longer carry host-Node-only JIT carve-outs.
