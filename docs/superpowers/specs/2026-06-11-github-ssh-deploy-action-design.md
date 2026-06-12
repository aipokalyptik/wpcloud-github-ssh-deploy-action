# GitHub SSH Deploy Action Design

Date: 2026-06-11

## Goal

Build a reusable GitHub Action that deploys files from a GitHub repository to a fixed SSH-only web docroot using either password or private-key SSH authentication while preserving atomic deploy behavior for managed paths.

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
      - uses: actions/checkout@v5

      - name: Deploy over SSH
        uses: aipokalyptik/wpcloud-github-ssh-deploy-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USERNAME }}
          password: ${{ secrets.SSH_PASSWORD }}
          docroot: /srv/htdocs
          source: .
          keep-releases: 2
          post-deploy: |
            wp cache flush
            echo "y" | wp edge-cache purge --domain
```

`keep-releases` defaults to `2`.

Authentication requires exactly one method: `password` or `private-key`.
Encrypted private keys also require `private-key-passphrase`.

`post-deploy` is optional. If omitted, no post-deploy commands run. If provided, the action runs exactly the listed commands in order.

`deployment-id` is optional. If omitted, the action derives it from the GitHub repository slug, normalized for safe path usage. Users can set `deployment-id` explicitly when they need a stable namespace across repository renames or when multiple workflows in one repository deploy independent layers.

The action deploys directly into `/srv/htdocs`. In the target environment, the user-visible `htdocs` path is a root-owned symlink:

```text
/home/151770228/htdocs -> /srv/htdocs
```

Because that symlink always points at `/srv/htdocs`, the action should use `/srv/htdocs` as the docroot input and deployment target. If a user supplies a symlinked docroot path anyway, the action may resolve it with `realpath`, but the primary documented path is `/srv/htdocs`.

## Remote Layout

The action stores release data inside a dotdir in the real docroot:

```text
/srv/htdocs/
  .github-ssh-deploy/
    deployments/
      apokalyptik-example-repo/
        current -> releases/20260611-203000-abcdef
        releases/
          20260611-203000-abcdef/
          20260610-191500-123456/
```

Public paths in the docroot become stable symlinks into the current release:

```text
/srv/htdocs/index.php -> .github-ssh-deploy/deployments/apokalyptik-example-repo/current/index.php
/srv/htdocs/assets -> .github-ssh-deploy/deployments/apokalyptik-example-repo/current/assets
/srv/htdocs/wp-content/plugins/foo -> ../../../.github-ssh-deploy/deployments/apokalyptik-example-repo/current/wp-content/plugins/foo
```

Direct HTTP requests to `/.github-ssh-deploy/...` are denied by the host, but requests through public symlinks resolve correctly.

The deployment namespace allows multiple repositories to deploy independent layers into the same site. Each layer owns its own release store and `current` symlink. Deployments may coexist as long as they do not claim the same public path.

## Atomicity Model

The action never rsyncs into live public files. It uploads a complete new release into:

```text
/srv/htdocs/.github-ssh-deploy/deployments/<deployment-id>/incoming/<release-id>/
```

The remote helper promotes the complete incoming tree to
`releases/<release-id>` before switching `current`.

Then it switches:

```text
/srv/htdocs/.github-ssh-deploy/deployments/<deployment-id>/current
```

to the new release using an atomic symlink replacement where supported.

Changed files become visible at the `current` flip. Added public symlinks are created before the flip. Removed public symlinks are cleaned after the flip.

A removed path may briefly be a broken symlink after the flip and before cleanup. That is acceptable because it is equivalent to the removed path not existing.

## Protection And Boundary Model

Before changing public paths, the action probes undeployable anchors from the real docroot:

```sh
find \( -uid 0 -or -gid 0 \) -and -not -writable
```

Any path equal to or below one of these anchors is protected. The action must not replace, delete, write through, or claim protected anchors. In practical terms, the action cannot deploy anything that matches this probe or descends from a path that matches this probe.

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

The action also probes dynamic boundary directories from the real docroot:

```sh
find -type d \( -uid 0 -or -gid 0 \) -and -perm -1000
```

Any directory matched by this probe is a boundary for claim compression. The action must not compress a repo path into a claim that would replace the sticky directory itself. Instead, paths below a sticky boundary are claimed at the next path segment below the deepest matching boundary.

Example dynamic boundaries:

```text
.
./wp-content
./wp-content/plugins
./wp-content/mu-plugins
./wp-content/themes
```

If `wp-content/plugins` is a dynamic boundary, `wp-content/plugins/foo/foo.php` claims `wp-content/plugins/foo`, not `wp-content` or `wp-content/plugins`. If `wp-content` is a dynamic boundary and no deeper boundary matches a repo path, `wp-content/uploads/a.jpg` claims `wp-content/uploads`.

## Claim Rules

The action compresses repo files into the fewest safe public symlink claims.

For unlisted paths, the default claim is the top-level path:

```text
index.php              -> index.php
assets/app.css         -> assets
includes/bootstrap.php -> includes
```

For dynamic or configured boundary paths, the action claims at the configured or implied depth:

```text
wp-content/plugins/foo/foo.php   -> wp-content/plugins/foo
wp-content/themes/site/style.css -> wp-content/themes/site
```

This avoids creating one symlink per file and prevents the action from claiming overly broad paths like all of `wp-content`.

Configured boundary rules are an advanced portability option for hosts that do not mark dynamic boundaries with sticky-bit directories:

```text
wp-content/plugins depth=1
wp-content/themes depth=1
```

These rules should not appear in the primary workflow example because the default behavior is to infer boundaries from the host. Unlisted directories are given free rein at their top-level claim unless blocked by the protected probe or interrupted by a dynamic sticky-bit boundary.

## Add, Change, And Remove Behavior

For each deploy:

1. Compute `old_claims` from the current release tree, if `current` exists.
2. Compute `new_claims` from the new release tree.
3. Create or reclaim all `new_claims` that are not protected.
4. Flip `current` to the new release.
5. Remove stale public symlinks only when all are true:
   - the path is a symlink,
   - the symlink target points into `.github-ssh-deploy/deployments/<deployment-id>/current`,
   - the claim does not exist in the new release.

The action does not use an ownership manifest for v1. State is reconstructed from:

- the new release tree,
- the previous release tree,
- live public symlinks pointing into `.github-ssh-deploy/deployments/<deployment-id>/current`,
- the protected-anchor probe.

Manual symlink tampering is corrected on the next deploy if the repo currently wants that path and the path is not protected.

## Post-Deploy Commands

The action supports optional post-deploy commands that run after the atomic `current` flip and stale symlink cleanup.

There are no hidden default post-deploy commands. If `post-deploy` is omitted, no post-deploy commands run. If `post-deploy` is provided, the action runs exactly the listed commands in order.

A WordPress-oriented workflow can include:

```sh
wp cache flush
echo "y" | wp edge-cache purge --domain
```

Commands run on the remote host from the real docroot.

If a post-deploy command fails, the action fails the GitHub workflow but does not automatically roll back. The new release remains active because cache flush and purge commands are operational side effects, not proof that the release files are invalid.

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

V1 should use a readable Bash remote script with newline-delimited claim files and standard Unix set operations. It should not require Perl, PHP, Python, a daemon, a database, or a custom sync protocol on the remote host.

A future Go helper is acceptable if claim planning becomes too complex, but v1 should avoid that dependency for remote claim logic.

## Deploy Flow

1. Establish SSH using the configured username and selected authentication method.
2. Acquire a remote deploy lock with `flock`.
3. Use the configured docroot path as the deployment base.
4. Create `.github-ssh-deploy/deployments/<deployment-id>/incoming/<release-id>`.
5. Upload the repository snapshot with `rsync`.
6. Promote the incoming tree to `releases/<release-id>`.
7. Compute old and new compressed claim sets.
8. Probe protected anchors and dynamic sticky-bit boundaries.
9. Create or reclaim public symlinks for new claims.
10. Atomically switch `.github-ssh-deploy/deployments/<deployment-id>/current` to the new release.
11. Remove stale action-managed public symlinks that no longer exist in the new release.
12. Run post-deploy commands.
13. Prune old releases, keeping the configured count.
14. Release the lock.

## Rollback

Rollback selects an older release, recomputes claims from that release, creates or reclaims required public symlinks, flips `current`, and removes stale action-managed symlinks using the same conservative deletion rule.

Rollback does not require a manifest.

## Failure Behavior

If upload, validation, or symlink preparation fails before the `current` flip, the old release remains active.

If cleanup fails after the flip, the new release remains active and stale public symlinks can be retried on the next deploy.

If a post-deploy command fails after the flip, the new release remains active and the GitHub workflow reports failure. The action does not automatically roll back.

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
- configured docroot usage,
- atomic symlink flip command probing,
- rollback claim reconciliation.
