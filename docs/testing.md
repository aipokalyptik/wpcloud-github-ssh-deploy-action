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
```

It also runs `bash -n` over scripts. If `shellcheck` is installed, it lints the
scripts and tests; otherwise lint is skipped with a message.

Most remote-helper tests use temporary docroots and internal override files for
boundary and protected-anchor discovery. They do not require real SSH access.
The transport test uses `GITHUB_SSH_DEPLOY_DRY_RUN=1` to validate generated
commands and input handling without connecting to a host.

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
      - uses: actions/checkout@v4
      - uses: apokalyptik/wpcloud-github-ssh-deploy-action@v1
        with:
          host: ${{ secrets.WPCLOUD_SSH_HOST }}
          username: ${{ secrets.WPCLOUD_SSH_USERNAME }}
          password: ${{ secrets.WPCLOUD_SSH_PASSWORD }}
          known-hosts: ${{ secrets.WPCLOUD_KNOWN_HOSTS }}
          docroot: /srv/htdocs
          deployment-id: testbed-prod
          keep-releases: 3
```

## E2E Scenarios

Run these against a disposable or non-production site:

1. First deploy creates `.github-ssh-deploy/deployments/<deployment-id>`,
   promotes a release, and exposes the expected public paths through symlinks.
2. Second deploy updates file contents through the same public symlinks and
   retains the configured number of releases.
3. Removing a file or directory from the source removes only this deployment's
   exact symlink claims, not unmanaged real files.
4. A `post-deploy` hook runs from `/srv/htdocs` after promotion and can access
   the new `current` release.
5. A failing `post-deploy` hook fails the workflow without automatically
   rolling back the already promoted release.
6. Two deployment IDs can own separate paths in the same docroot.
7. A deployment fails with `claim owned by another deployment` when it tries to
   claim a path or descendant owned by another deployment ID.
8. A deployment fails with `protected path` when it would replace a protected
   host-owned anchor.
9. Manual rollback with `remote-deploy.sh --rollback-to <release-id>` repoints
   `current`, reconciles public symlinks, and fails clearly for a missing or
   pruned release.
10. `known-hosts` succeeds with a pinned host key; omitting it falls back to
    `ssh-keyscan`.

Record the workflow URL, release IDs, rollback command, and observed public
paths in the release checklist. Do not record passwords or private host details
in public issues or release notes.
