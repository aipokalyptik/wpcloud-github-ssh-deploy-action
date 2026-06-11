# GitHub SSH Deploy Action Design

Date: 2026-06-11

## Goal

Build a reusable GitHub Action that deploys files from a GitHub repository to a fixed SSH-only web docroot using username/password authentication while preserving atomic deploy behavior for managed paths.

The target environment has these constraints:

- The web docroot cannot be changed.
- The docroot can contain unmanaged files that the action must not destroy.
- Some host-managed paths are owned by root or a root-owned group and are not writable by the site user.
- Some root-owned parent directories are writable by the site user, such as `wp-content/plugins`, and should allow managed children.
- Symlinks inside the docroot are followed by HTTP requests.
- Direct HTTP requests to dotdirs are denied, but public symlinks can point into dotdirs successfully.

The action should make deploys simple for users while avoiding direct, partial rsync into live files.

## Core Design Principle

Write as little custom code as possible, but as much as necessary for readability and correctness.

The action should lean on standard host tools for work they already do well: `rsync` for transfer, `find` for discovery, `flock` for locking, `realpath` and `readlink` for path resolution, and `mv` for atomic replacement. Custom logic should be limited to the deploy-specific decisions those tools do not provide: claim compression, protection checks, symlink reconciliation, rollback selection, and GitHub Action input handling.

Small, readable Bash functions are preferred over clever one-liners. A helper binary or additional runtime should only be introduced if the Bash implementation becomes harder to verify than the dependency it replaces.

## Collaboration Principle

Implementation work must not silently choose between meaningful alternatives. When a decision affects behavior, compatibility, security, data loss risk, user experience, or implementation complexity, Codex should present the realistic options with trade-offs and wait for the user to choose.

This does not apply to mechanical details that are already implied by the approved design, such as formatting a script consistently or using an existing standard tool exactly as specified. It does apply to deploy semantics, fallback behavior, defaults, destructive operations, compatibility trade-offs, and packaging choices.

## User Experience

A repository can deploy with a workflow like this:

```yaml
name: Deploy

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Deploy over SSH
        uses: apokalyptik/github-ssh-deploy-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USERNAME }}
          password: ${{ secrets.SSH_PASSWORD }}
          docroot: /home/151770228/htdocs
          source: .
          boundary-rules: |
            wp-content/plugins depth=1
            wp-content/themes depth=1
          keep-releases: 5
```

The action resolves `docroot` to its real path before deployment. For example:

```text
/home/151770228/htdocs -> /srv/htdocs
```

In that case, `/home/151770228/htdocs` is the configured docroot path, but all public symlink creation, release storage, and protection checks operate against the resolved real docroot path, `/srv/htdocs`. The root-owned docroot symlink itself is not the deployment target.

## Remote Layout

The action stores release data inside a dotdir in the real docroot:

```text
/srv/htdocs/
  .github-ssh-deploy/
    current -> releases/20260611-203000-abcdef
    releases/
      20260611-203000-abcdef/
      20260610-191500-123456/
```

Public paths in the docroot become stable symlinks into the current release:

```text
/srv/htdocs/index.php -> .github-ssh-deploy/current/index.php
/srv/htdocs/assets -> .github-ssh-deploy/current/assets
/srv/htdocs/wp-content/plugins/foo -> ../../../.github-ssh-deploy/current/wp-content/plugins/foo
```

Direct HTTP requests to `/.github-ssh-deploy/...` are denied by the host, but requests through public symlinks resolve correctly.

## Atomicity Model

The action never rsyncs into live public files. It uploads a complete new release into:

```text
/srv/htdocs/.github-ssh-deploy/releases/<release-id>/
```

Then it switches:

```text
/srv/htdocs/.github-ssh-deploy/current
```

to the new release using an atomic symlink replacement where supported.

Changed files become visible at the `current` flip. Added public symlinks are created before the flip. Removed public symlinks are cleaned after the flip.

A removed path may briefly be a broken symlink after the flip and before cleanup. That is acceptable because it is equivalent to the removed path not existing.

## Protection Model

Before changing public paths, the action probes protected anchors from the real docroot:

```sh
find \( -uid 0 -or -gid 0 \) -and -not -writable
```

Any path equal to or below one of these anchors is protected. The action must not replace, delete, or write through protected anchors.

Example protected anchors:

```text
./wp-content/plugins/akismet
./wp-content/plugins/jetpack
./wp-content/advanced-cache.php
./wp-content/object-cache.php
./__wp__
./wp-load.php
```

This allows writable children under root-owned parents while still blocking host-managed children.

## Claim Rules

The action compresses repo files into the fewest safe public symlink claims.

For unlisted paths, the default claim is the top-level path:

```text
index.php              -> index.php
assets/app.css         -> assets
includes/bootstrap.php -> includes
```

For configured boundary paths, the action claims at the configured depth:

```text
wp-content/plugins/foo/foo.php   -> wp-content/plugins/foo
wp-content/themes/site/style.css -> wp-content/themes/site
```

This avoids creating one symlink per file and prevents the action from claiming overly broad paths like all of `wp-content`.

Boundary rules are intentionally small:

```text
wp-content/plugins depth=1
wp-content/themes depth=1
```

Unlisted directories are given free rein at their top-level claim unless blocked by the protected probe.

## Add, Change, And Remove Behavior

For each deploy:

1. Compute `old_claims` from the current release tree, if `current` exists.
2. Compute `new_claims` from the new release tree.
3. Create or reclaim all `new_claims` that are not protected.
4. Flip `current` to the new release.
5. Remove stale public symlinks only when all are true:
   - the path is a symlink,
   - the symlink target points into `.github-ssh-deploy/current`,
   - the claim does not exist in the new release.

The action does not use an ownership manifest for v1. State is reconstructed from:

- the new release tree,
- the previous release tree,
- live public symlinks pointing into `.github-ssh-deploy/current`,
- the protected-anchor probe.

Manual symlink tampering is corrected on the next deploy if the repo currently wants that path and the path is not protected.

## Remote Tooling

The remote host has enough standard tooling for a lightweight implementation:

- `bash`
- `rsync`
- `find`
- `realpath`
- `readlink`
- `flock`
- `mv`
- `sort`
- `comm`
- `sed`
- `dirname`
- `mkdir`
- `rm`
- `logger`

V1 should use a readable Bash remote script with newline-delimited claim files and standard Unix set operations. It should not require Perl, PHP, Python, Go, a daemon, a database, or a custom sync protocol.

A future Go helper is acceptable if claim planning becomes too complex, but v1 should avoid that dependency.

## Deploy Flow

1. Establish SSH using the configured username and password.
2. Acquire a remote deploy lock with `flock`.
3. Resolve the real docroot path.
4. Create `.github-ssh-deploy/releases/<release-id>`.
5. Upload the repository snapshot with `rsync`.
6. Compute old and new compressed claim sets.
7. Probe protected anchors.
8. Create or reclaim public symlinks for new claims.
9. Atomically switch `.github-ssh-deploy/current` to the new release.
10. Remove stale action-managed public symlinks that no longer exist in the new release.
11. Prune old releases, keeping the configured count.
12. Release the lock.

## Rollback

Rollback selects an older release, recomputes claims from that release, creates or reclaims required public symlinks, flips `current`, and removes stale action-managed symlinks using the same conservative deletion rule.

Rollback does not require a manifest.

## Failure Behavior

If upload, validation, or symlink preparation fails before the `current` flip, the old release remains active.

If cleanup fails after the flip, the new release remains active and stale public symlinks can be retried on the next deploy.

If a requested claim is protected, deployment fails before the flip.

If `mv -T` is unavailable, the script should probe and use the best safe fallback supported by the host. The fallback must be documented as weaker if it cannot provide the same atomic symlink replacement guarantee.

## Non-Goals

- No full-site ownership of the docroot.
- No deletion of unmanaged real files or directories on removal.
- No manifest-driven ownership database in v1.
- No direct patching of live files as the default deploy method.
- No assumption that CLI PHP, Python, Perl, or Go is available remotely.

## Test Coverage

Tests should cover:

- claim compression for unlisted paths,
- boundary claim depth,
- protected-anchor blocking,
- writable children under root-owned writable parents,
- add/change/remove reconciliation,
- stale symlink cleanup after flip,
- refusal to remove unmanaged real files,
- tampered symlink reclaim for wanted claims,
- real docroot resolution,
- atomic symlink flip command probing,
- rollback claim reconciliation.
