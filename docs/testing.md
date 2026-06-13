# Testing

The repository contains shell tests for action metadata, transport input
handling, remote layout, claim computation, public symlink reconciliation, and
rollback.

## Local Tests

Run the full local suite from the repository root:

```bash
tests/run.sh
```

The suite runs:

```text
tests/test_action_metadata.sh
tests/test_deploy_input_transport.sh
tests/test_remote_deploy_layout.sh
tests/test_remote_deploy_claims.sh
tests/test_remote_deploy_symlinks.sh
tests/test_remote_deploy_rollback.sh
scripts/check-exchange-helper.sh
```

It also runs `bash -n` over scripts. If `shellcheck` is installed, it lints the
scripts and tests; otherwise lint is skipped with a message.

Most remote-helper tests use temporary docroots and internal override files for
boundary and protected-anchor discovery. They do not require real SSH access.
The transport test uses `GITHUB_SSH_DEPLOY_DRY_RUN=1` to validate generated
commands and input handling without connecting to a host, including default,
replacement, and disabled upload excludes. It also covers `prepare-git`
behavior with fake Git commands: sparse checkout refusal, Git LFS preparation
and unresolved pointer failure, submodule initialization, and the
`prepare-git: false` escape hatch.

`scripts/check-exchange-helper.sh` rebuilds the Linux amd64 `exchange-rename`
helper from source, verifies the committed and rebuilt binaries are static ELF
artifacts, checks that the source uses `renameat2(RENAME_EXCHANGE)` directly,
and runs smoke tests for both helpers on Linux amd64 CI.

## GitHub CI

The repository includes a GitHub Actions workflow at `.github/workflows/ci.yml`.
CI should run `tests/run.sh` for pull requests and pushes so docs-only changes
still prove the action metadata and scripts were not accidentally broken.

## Private Testbed Plan

Before promoting a release tag, run an end-to-end deployment from a private
testbed repository into a non-production WP Cloud or Pressable site.

Use GitHub repository or environment secrets in the private testbed:

```text
WPCLOUD_SSH_HOST
WPCLOUD_SSH_USERNAME
WPCLOUD_SSH_PASSWORD
WPCLOUD_SSH_KEY_USERNAME
WPCLOUD_SSH_PRIVATE_KEY
WPCLOUD_SSH_ENCRYPTED_KEY_USERNAME
WPCLOUD_SSH_ENCRYPTED_PRIVATE_KEY
WPCLOUD_SSH_ENCRYPTED_PRIVATE_KEY_PASSPHRASE
WPCLOUD_KNOWN_HOSTS   optional but recommended
```

Do not commit secrets to this repository, the testbed repository, workflow
files, logs, or docs. If host keys are supplied, store the literal known_hosts
line in `WPCLOUD_KNOWN_HOSTS`.

Example private testbed workflow:

```yaml
name: E2E Deploy

on:
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: aipokalyptik/wpcloud-github-ssh-deploy-action@v1
        with:
          host: ${{ secrets.WPCLOUD_SSH_HOST }}
          username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
          password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
          known-hosts: ${{ secrets.WPCLOUD_KNOWN_HOSTS }}
          docroot: /srv/htdocs
          deployment-id: testbed-prod
          exclude: |
            .git
            .git/
            .gitignore
            .github/
            .env
            .env.*
          keep-releases: 3
```

Add parallel or matrix jobs for key authentication by replacing the auth inputs:

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_KEY_USERNAME }}
  private-key: ${{ secrets.WPCLOUD_SSH_PRIVATE_KEY }}
  known-hosts: ${{ secrets.WPCLOUD_KNOWN_HOSTS }}
  docroot: /srv/htdocs
  deployment-id: testbed-key
```

```yaml
with:
  host: ${{ secrets.WPCLOUD_SSH_HOST }}
  username: ${{ secrets.WPCLOUD_SSH_ENCRYPTED_KEY_USERNAME }}
  private-key: ${{ secrets.WPCLOUD_SSH_ENCRYPTED_PRIVATE_KEY }}
  private-key-passphrase: ${{ secrets.WPCLOUD_SSH_ENCRYPTED_PRIVATE_KEY_PASSPHRASE }}
  known-hosts: ${{ secrets.WPCLOUD_KNOWN_HOSTS }}
  docroot: /srv/htdocs
  deployment-id: testbed-encrypted-key
```

## E2E Scenarios

Run these against a disposable or non-production site:

1. First deploy creates `.github-ssh-deploy/deployments/<deployment-id>`,
   promotes a release, and exposes the expected public paths through symlinks.
2. Second deploy updates file contents through the same public symlinks and
   retains the configured number of releases.
3. Removing a file or directory from the source removes only this deployment's
   exact symlink claims, not unmanaged real files.
4. Adding a wanted claim can replace an unmanaged real file or directory at the
   same public path.
5. A `post-deploy` hook runs from `/srv/htdocs` after promotion and can access
   the new `current` release.
6. A failing `post-deploy` hook fails the workflow without automatically
   rolling back the already promoted release.
7. Two deployment IDs can own separate paths in the same docroot.
8. A deployment fails with `claim owned by another deployment` when it tries to
   claim a path owned by another deployment ID or a path below a symlink owned
   by another deployment ID.
9. A deployment fails with `claim contains another deployment` when it tries to
   replace a directory containing a descendant symlink owned by another
   deployment ID.
10. A deployment fails with `protected path` when it would replace a protected
   host-owned anchor.
11. Manual rollback with `remote-deploy.sh --rollback-to <release-id>` repoints
   `current`, reconciles public symlinks, and fails clearly for a missing or
   pruned release.
12. `known-hosts` succeeds with a pinned host key; omitting it falls back to
    `ssh-keyscan`.
13. Password auth, unencrypted private-key auth, and encrypted private-key auth
    all complete an end-to-end deployment.
14. Missing auth, conflicting password plus private key, and passphrase without
    a private key fail before upload.
15. Default upload excludes keep common VCS and secret dotfiles out of the
    release; a custom `exclude` list replaces the defaults; `exclude: none`
    disables upload excludes.
16. Reclaiming an existing public path uses the exchange helper rather than
    deleting the path first; cleanup failure after exchange leaves `current` and
    the public symlink on the promoted release while failing the workflow.

Record the workflow URL, release IDs, rollback command, and observed public
paths in the release checklist. Do not record passwords or private host details
in public issues or release notes.

## 1.0 Validation Evidence

Validation for the 1.0 release candidate was run on 2026-06-11:

- Local suite: `tests/run.sh` passed on `main`; `shellcheck` was skipped locally
  because it was not installed.
- Private E2E: `aipokalyptik/jippity-deploy-testbed` run `27385371204`
  completed successfully against the disposable WP Cloud/Pressable test site.
- Covered live scenarios: initialization, add, change, remove, protected-path
  rejection, layered theme/plugin deployments, and failing post-deploy hook
  semantics after promotion.
- Live E2E caught a remote `/dev/fd` process-substitution incompatibility. The
  fix removed process substitution from the uploaded remote helper and added a
  regression check in `tests/test_action_metadata.sh`.
