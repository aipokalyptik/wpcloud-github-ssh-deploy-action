# WP Cloud SSH Deploy Action

Deploy a repository snapshot to a WP Cloud or Pressable document root over SSH.

This action uploads your selected local source directory with `rsync`, stores it
as a release under the remote docroot, and promotes that release by updating
deployment-owned public symlinks. It is designed for WordPress sites where the
host owns parts of the tree and the app needs to deploy only the paths it owns.

## Quick Start

```yaml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Deploy to WP Cloud
        uses: aipokalyptik/wpcloud-github-ssh-deploy-action@v1
        with:
          host: ${{ secrets.WPCLOUD_SSH_HOST }}
          username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
          password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
          docroot: /srv/htdocs
```

By default, `source` is the checked-out repository root, common sensitive
dotfiles and dotdirs are excluded from upload, `docroot` is `/srv/htdocs`,
`port` is `22`, and `keep-releases` is `2`.

Atomic reclaim of existing public paths currently supports Linux amd64 remote
hosts with standard tools including `flock` and `mv -T`. Unsupported remote
CPU architectures or missing required tools fail clearly before deployment.

Script `--version` values are internal component markers for troubleshooting.
Customer workflows should pin the action with Git tags such as `@v1`.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `host` | Yes | | SSH host name. |
| `username` | Yes | | SSH username. |
| `password` | No | | SSH password. Mutually exclusive with `private-key`; masked in GitHub logs. |
| `private-key` | No | | OpenSSH private key content. Mutually exclusive with `password`; masked in GitHub logs. |
| `private-key-passphrase` | No | | Passphrase for an encrypted `private-key`. Masked in GitHub logs. |
| `port` | No | `22` | SSH port. Must be `1` through `65535`. |
| `docroot` | No | `/srv/htdocs` | Remote document root. Must not contain whitespace. |
| `source` | No | `.` | Local path to upload. A trailing slash is applied for rsync directory contents. |
| `exclude` | No | built-in list | Newline-delimited rsync exclude patterns. Omit for common dotfile defaults, provide a list to replace them, or set `none` to disable excludes. |
| `keep-releases` | No | `2` | Number of remote releases to keep for this deployment namespace. Must be positive. |
| `post-deploy` | No | | Newline-delimited Bash commands to run from the remote docroot after promotion. |
| `deployment-id` | No | normalized repository slug | Stable deployment namespace. Use this when multiple workflows deploy to the same site. |
| `known-hosts` | No | | Literal `known_hosts` content. If omitted, the action runs `ssh-keyscan`. |

Required secrets are normally `host`, `username`, and one authentication method:
either `password` or `private-key`. You can store them with any secret names you
prefer and map them into the action inputs. If the private key is encrypted,
also provide `private-key-passphrase`.

## Optional Examples

Use an explicit host key instead of `ssh-keyscan`:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
  known-hosts: ${{ secrets.WPCLOUD_KNOWN_HOSTS }}
```

Use an unencrypted private key instead of a password:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  private-key: ${{ secrets.WPCLOUD_SSH_PRIVATE_KEY }}
```

Use an encrypted private key:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  private-key: ${{ secrets.WPCLOUD_SSH_PRIVATE_KEY }}
  private-key-passphrase: ${{ secrets.WPCLOUD_SSH_PRIVATE_KEY_PASSPHRASE }}
```

Deploy a build output directory and keep five rollback candidates:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
  source: dist
  deployment-id: frontend-prod
  keep-releases: 5
```

Replace the default upload excludes:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
  exclude: |
    .git/
    .github/
    secrets/
    local-config.php
```

Disable upload excludes:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
  exclude: none
```

Run post-deploy commands after the new release is current:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
  password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
  post-deploy: |
    wp cache flush
    wp rewrite flush --hard
```

`post-deploy` runs with `bash -e` from `docroot`. If a command fails, the action
fails, but the promoted release is not automatically rolled back.

## Pressable and WP Cloud Notes

The default `docroot` is `/srv/htdocs`, which is the common WP Cloud runtime
document root. On some hosts this path is itself part of a symlinked or managed
filesystem. The action treats the configured `docroot` as the public path base
and creates deployment state below:

```text
/srv/htdocs/.github-ssh-deploy/deployments/<deployment-id>/
```

WP Cloud and Pressable environments often include host-managed files and
directories. The remote helper detects sticky-boundary directories and protected
anchors at deploy time:

- Sticky-boundary directories are root-owned or root-group-owned directories
  with the sticky bit set. Inside a boundary, claims are compressed to the next
  path segment, so a plugin deployment can claim `wp-content/plugins/my-plugin`
  instead of all of `wp-content`.
- Protected anchors are root-owned or root-group-owned paths that are not
  writable. If a release claim overlaps a protected anchor by equality,
  descendant, or ancestor containment, deployment stops before promotion.

This is intended to avoid replacing host-owned WordPress anchors while still
allowing deploys into writable application areas.

## How Deployments Work

Each deploy uploads the source tree to:

```text
<docroot>/.github-ssh-deploy/deployments/<deployment-id>/incoming/<release-id>/
```

The remote helper then moves it into `releases/<release-id>`, updates
`current` to point at that release, and reconciles public symlinks in `docroot`
for the release claims. Release IDs are generated from the UTC time plus the
GitHub SHA prefix unless an internal test override is set.

When a new wanted claim replaces an existing public file or directory, the
action uploads a small statically linked Linux amd64 helper that performs a
single `renameat2(RENAME_EXCHANGE)` swap. The public path is exchanged with the
deployment symlink instead of being removed first; the exchanged-away old content
is cleaned after `current` points at the new release.

Upload excludes are applied by `rsync` before the release reaches the remote
host. The built-in list excludes `.git/`, `.github/`, `.svn/`, `.hg/`, `.bzr/`,
`.aws/`, `.ssh/`, `.env`, `.env.*`, `.npmrc`, `.pypirc`, `.netrc`, and
`.DS_Store`. It intentionally does not exclude all dotfiles, so deployable
paths such as `.htaccess` and `.well-known/` are not blocked by default.

The action does not write a manifest. It recomputes claims from the current
release tree, the previous release tree, and deployment-owned symlinks already
materialized in the public docroot.

## Layered Deployments and Conflicts

Multiple deployment namespaces can share one docroot when they own different
paths. Set a stable `deployment-id` for each layer, such as `theme-prod`,
`plugin-foo-prod`, or `frontend-prod`.

The conflict rules are conservative:

- A deployment can replace its own symlinks.
- A deployment does not remove unmanaged real files when they are no longer in
  its release.
- A new wanted claim can reclaim and replace an unmanaged real file or directory
  at that public path. Treat broad claims as destructive to unmanaged content at
  the same path.
- A deployment refuses to claim a path, claim below an ancestor, or claim over a
  descendant symlink already owned by another deployment namespace.

If two layers need the same public path, split their sources or boundaries so
only one deployment owns that path.

## Rollback

Rollback is performed with the remote helper that the action uploads to the
deployment namespace. Run it over SSH with the same `docroot` and
`deployment-id`, choosing an existing release directory:

```bash
ssh user@example.com \
  'bash /srv/htdocs/.github-ssh-deploy/deployments/frontend-prod/remote-deploy.sh \
    --docroot /srv/htdocs \
    --deployment-id frontend-prod \
    --rollback-to 20260611010101-abcdef123456'
```

Rollback repoints `current` to the existing release and reconciles public
symlinks. It does not run `post-deploy`, and it fails if the target release was
pruned by `keep-releases` or would violate current protected anchors.

## Troubleshooting

`missing required input: host` or `username`
: Confirm the workflow maps all required connection inputs.

`either password or private-key is required`
: Provide exactly one authentication method.

`password and private-key are mutually exclusive`
: Remove one authentication method from the workflow.

`private-key-passphrase requires private-key`
: Provide `private-key` with the passphrase, or remove the passphrase input.

`sshpass is required for deployment`
: On GitHub-hosted Linux runners the action installs `sshpass` with `apt-get`.
  On other runners, install `sshpass` before invoking the action. This applies
  only to password authentication.

`ssh-agent` or `ssh-add` is required for encrypted private-key authentication
: Encrypted private keys are loaded into `ssh-agent` with an `SSH_ASKPASS`
  helper on the runner. Use a GitHub-hosted runner or install the missing
  runner-side OpenSSH tool.

`ssh-keyscan did not return a host key`
: Provide `known-hosts` explicitly, verify the SSH host and port, or confirm the
  host permits key scanning from the runner network.

`unsupported remote architecture for exchange helper`
: The remote host is not Linux amd64. The 1.0 helper currently ships only a
  statically linked amd64 binary.

`Host key verification failed`
: Refresh the `known-hosts` secret for the exact host and port, or remove it so
  the action can use `ssh-keyscan`.

`protected path: <path>`
: The release would replace a protected host-owned path. Change the deployment
  source or repository contents, adjust the claim boundary shape, or deploy to a
  writable child path.

`claim owned by another deployment: <path>`
: Another `deployment-id` owns that public symlink path or an ancestor. Move the
  conflicting files into one deployment, or change the layer split so ownership
  does not overlap.

`claim contains another deployment: <path>`
: Another `deployment-id` owns a descendant symlink inside the public directory
  this release wants to claim. Narrow the source or boundaries, or move the
  nested layer into the same deployment.

`release already exists`
: A release ID collision occurred. Normal GitHub runs generate timestamped IDs;
  rerun the workflow.

`rollback release does not exist`
: The release is not present under the deployment namespace, often because it
  was pruned by `keep-releases`.

`post-deploy` failed after the release became current
: Fix the command or site state, then rerun deployment or use rollback. The
  helper does not automatically undo a successful promotion after a hook failure.

## More Detail

- [Architecture](docs/architecture.md)
- [Testing](docs/testing.md)
