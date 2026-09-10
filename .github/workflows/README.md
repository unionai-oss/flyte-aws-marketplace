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

1. `AWS_PROFILE=union-seller infra/seller-account-setup.sh` creates both roles
   (publishing + smoke). Idempotent — safe to re-run. The OIDC provider already
   exists.
2. Repo variables:
   - `AWS_PUBLISH_ROLE_ARN` — `github-actions-flyte-marketplace`.
   - `AWS_SMOKE_ROLE_ARN` — `github-actions-flyte-devbox-smoke`.
3. Environments:
   - `marketplace-publish` — put required reviewers on it. Submitting a version
     is irreversible and a rejection burns a chart tag.
   - `devbox-smoke` — gates real AWS spend, **and** is the only thing standing
     between a workflow file and a near-admin role. Required reviewers here are
     load-bearing, not decoration: the smoke role's trust policy names this
     environment as its sole subject.

Everything runs in the seller account (747712783559) — that is where Marketplace
requires the artifacts to live, so nothing here touches union-presales.

## The smoke test's domain

`devbox-ami.yml` keeps Buildkite's gate: the AMI id reaches SSM only after the
smoke test passes. The test deploys a real Prod-mode stack, which needs a public
Route 53 zone **in the account it deploys into** — the template discovers the
zone itself, walking parent domains most-specific-first.

So `mp.flytedemo.app` is a hosted zone in the seller account, delegated by an NS
record from the `flytedemo.app` zone in 371290552455. `smoke-test.sh` defaults to
`smoke.mp.flytedemo.app` inside it. The point is that CI has a namespace of its
own: no scheduled build ever creates records in, or takes a certificate for, a
personal demo domain. Override `DOMAIN` to run the script against a zone you own.

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

## Why two roles

The smoke test deploys a whole devbox stack — EC2, Aurora, ALB, Cognito, IAM —
which needs far broader rights than publishing does. Putting that on the
publishing role would mean every scheduled AMI build ran with near-admin
credentials, so it is a separate principal
(`github-actions-flyte-devbox-smoke`, `PowerUserAccess` + `IAMFullAccess`)
trusted **only** from the `devbox-smoke` environment.

Run with `skip_smoke: true` to bypass it — that publishes an unvalidated AMI to
SSM, which is exactly what the gate exists to prevent, so treat it as a
break-glass option rather than a convenience.
