# CI

Validation stays on Buildkite (`.buildkite/`) — these workflows are the
**publishing** half, which needs to run in the AWS Marketplace seller account
(747712783559) where the artifacts have to live.

| workflow | trigger | what it does |
|---|---|---|
| `devbox-ami.yml` | daily + manual | Rebuilds the devbox AMI when a new `flyte-devbox` image ships, smoke-tests it, and writes the id to SSM. |
| `eks-addon.yml` | daily + manual | Bumps to a new upstream `flyte-binary` chart, validates, pushes the chart and images to the Marketplace ECR, and opens a PR. Submitting the version is a separate, manual job. |

## Setup

Both authenticate with OIDC — no long-lived AWS keys.

1. `AWS_PROFILE=union-seller infra/seller-account-setup.sh` creates the role.
   (The OIDC provider already exists.)
2. Repo variables:
   - `AWS_PUBLISH_ROLE_ARN` — the role from step 1.
   - `AWS_SMOKE_ROLE_ARN` — only for the devbox smoke job. Not created yet; see below.
3. Environments:
   - `marketplace-publish` — put required reviewers on it. Submitting a version
     is irreversible and a rejection burns a chart tag.
   - `devbox-smoke` — gates real AWS spend.

## Why submitting is manual

`eks-addon.yml` publishes artifacts automatically but stops short of the
Marketplace change request, because two things make a cron-fired submission a
bad idea:

- Marketplace ECR tags are immutable and sellers cannot delete them, so a
  rejected submission permanently consumes that add-on version. Getting version
  0.1.2 accepted took three burned versions.
- Marketplace refuses a new version while the previous one is still working its
  way into the EKS console, so back-to-back upstream releases would fail anyway.

Run it with `submit: true` once the previous version is live. If you'd rather it
fire automatically, drop the `if: inputs.submit` on the `submit` job — the
`marketplace-publish` environment still gates it.

## The smoke-test role

`devbox-ami.yml` keeps Buildkite's gate: the AMI id reaches SSM only after the
smoke test passes. But the smoke test deploys a whole devbox stack — EC2,
Aurora, ALB, Cognito, IAM — which needs far broader rights than publishing does,
so it is **not** in `github-actions-flyte-marketplace`. Either create a second
role and set `AWS_SMOKE_ROLE_ARN`, or run the workflow with `skip_smoke: true`
and accept that it publishes an unvalidated AMI.
