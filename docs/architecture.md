# Architecture

The action is a composite Bash action. `action.yml` maps inputs into environment
variables and runs `scripts/deploy.sh`. The transport script validates inputs,
prepares host key checking, uploads the source tree with `rsync`, applies
configured upload excludes with `--exclude-from`, uploads
`scripts/remote-deploy.sh`, uploads the static exchange helper, optionally
uploads a post-deploy hook, and invokes the remote helper over password SSH.

SSH key authentication is not implemented. The transport uses `sshpass` with the
`password` input.

## Remote Layout

For a deployment namespace, all remote state lives below:

```text
<docroot>/.github-ssh-deploy/deployments/<deployment-id>/
```

`docroot` must not contain whitespace. The transport treats that as an explicit
input constraint because rsync remote destinations are passed through the
remote shell.

Important paths:

```text
incoming/<release-id>/       uploaded release before promotion
releases/<release-id>/       promoted immutable release tree
current                      symlink to releases/<release-id>
deploy.lock                  flock lock for promotion and rollback
remote-deploy.sh             helper used by deploy and manual rollback
exchange-rename              static linux-amd64 renameat2 exchange helper
post-deploy/<release-id>.sh  optional uploaded hook
```

The public docroot contains symlinks for claimed paths. A top-level claim such
as `assets` points to:

```text
.github-ssh-deploy/deployments/<deployment-id>/current/assets
```

Nested claims use relative symlink targets with the right number of `../`
segments.

## Atomic Symlink Overlay

Promotion is an overlay operation, not a wholesale docroot replacement.

The helper moves the uploaded release from `incoming` to `releases`, creates or
updates public symlinks for the release claims, switches `current` with a
temporary symlink plus `mv -T`, and then removes stale deployment-owned
symlinks. The `current` pointer is the release selector for all public symlinks
owned by that deployment.

When reclaiming an existing public file or directory, the helper creates the new
symlink in the same parent directory and swaps it with the existing path using a
static helper that calls `renameat2(RENAME_EXCHANGE)`. The old public content is
then left at the temporary path and removed after `current` points at the new
release. If that cleanup fails, the deploy reports failure after the new release
is active; a later deploy can retry cleanup.

Deploy and rollback are serialized with `flock` on the namespace lock file.

## Dynamic Sticky Boundaries

Claims are computed from files and symlinks in the release tree. Common VCS and
secret dotfiles are excluded during upload by default; if callers replace or
disable those excludes, uploaded files are treated like normal release content.

By default, the helper discovers sticky boundaries with:

```text
find <docroot> -type d \( -uid 0 -or -gid 0 \) -and -perm -1000
```

Within the deepest matching boundary, the claim is compressed to the next path
segment. For example, with `wp-content` and `wp-content/plugins` as boundaries,
`wp-content/plugins/foo/foo.php` claims `wp-content/plugins/foo`.

Tests can override discovered boundaries with
`GITHUB_SSH_DEPLOY_BOUNDARIES_FILE`; that is an internal test hook, not a public
action input.

## Protected Anchors

By default, protected anchors are root-owned or root-group-owned paths under the
docroot that are not writable:

```text
find <docroot> \( -uid 0 -or -gid 0 \) -and -not -writable
```

Before promotion or rollback, every new claim is checked against the protected
anchor set. If a claim overlaps a protected anchor by equality, descendant, or
ancestor containment, the helper fails with `protected path: <claim>` before
switching `current`.

Tests can override protected anchors with
`GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE`; that is also an internal test hook.

## Claim Compression

The helper computes claim sets in a per-run scratch directory under the
deployment namespace while holding the deployment lock. These scratch files are
removed after the run and are not a deployment manifest.

There is intentionally no manifest. The helper recomputes claims from:

- the current release tree, if `current` exists;
- deployment-owned public symlinks already present in the docroot;
- the incoming or rollback target release tree.

This allows rollback and cleanup to reason from actual remote state instead of
trusting a stale manifest.

The only durable cleanup state is `exchanged_paths`. It is written when an
existing public path has been atomically exchanged with a deployment symlink.
If cleanup of the exchanged-away path fails after `current` is promoted, the
next deploy or rollback retries that cleanup before proceeding.

## Removal Behavior

When a path existed in the previous claim set but not in the new claim set, it
is considered removed. The helper removes only exact symlinks that still point
to this deployment's expected public target.

Important consequences:

- Unmanaged real files are not deleted just because an old release used to own
  that path.
- Symlinks owned by another deployment namespace are not deleted.
- If claim granularity changes, overlapping stale symlinks are cleaned before
  or after reconciliation so parent and child claims do not block each other.

Removal behavior is different from wanted-claim reclaim. When a new release
wants a public claim, the helper may replace an unmanaged real file or directory
at that exact public path with the deployment symlink. Existing paths are
exchanged atomically where the uploaded Linux amd64 helper can run; unsupported
remote architectures fail before invoking the remote deploy. Operators should
narrow the source tree or boundary shape when unmanaged content must remain at
that path.

## Layered Deployments

Layered deployments are supported by using different `deployment-id` values for
different source trees in the same docroot.

The helper detects ownership by reading symlink targets that contain:

```text
.github-ssh-deploy/deployments/<deployment-id>/current
```

A deployment may replace its own symlink claims. It refuses to claim a path
already owned by another namespace, refuses to claim below an ancestor symlink
owned by another namespace, and refuses to replace a directory that contains a
descendant symlink owned by another namespace. Same-deployment descendant
symlinks are allowed so parent and child claim transitions can be reclaimed by
the owning deployment. This keeps independent layers from silently taking each
other's public paths.

## Rollback

Rollback uses the same remote helper:

```bash
bash <docroot>/.github-ssh-deploy/deployments/<deployment-id>/remote-deploy.sh \
  --docroot <docroot> \
  --deployment-id <deployment-id> \
  --rollback-to <release-id>
```

Rollback requires the release directory to still exist, recomputes claims,
checks protected anchors, reconciles public symlinks, and switches `current`.
It does not run post-deploy hooks and does not prune releases.
