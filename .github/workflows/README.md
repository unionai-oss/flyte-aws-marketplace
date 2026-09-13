# CI

Validation stays on Buildkite (`.buildkite/`) — these workflows are the
**publishing** half, which needs to run in the AWS Marketplace seller account
(747712783559) where the artifacts have to live.

| workflow | trigger | what it does |
|---|---|---|
| `devbox-ami.yml` | daily + manual | Rebuilds the devbox AMI when a new `flyte-devbox` image ships, smoke-tests it, and writes the id to SSM. With `submit: true`, forces a build and submits the result to AWS Marketplace as a new version. |
| `eks-addon.yml` | daily + manual | Bumps to a new upstream `flyte-binary` chart, validates, pushes the chart and images to the Marketplace ECR, and opens a PR. Submitting the version is a separate, manual job. |

## Setup

Both authenticate with OIDC — no long-lived AWS keys.

1. `AWS_PROFILE=union-seller infra/seller-account-setup.sh` creates both roles
   (publishing + smoke). Idempotent — safe to re-run. The OIDC provider already
   exists.
2. Repo variables:
   - `AWS_PUBLISH_ROLE_ARN` — `github-actions-flyte-marketplace`.
   - `AWS_SMOKE_ROLE_ARN` — `github-actions-flyte-devbox-smoke`.
   - `DEVBOX_MARKETPLACE_PRODUCT_ID` — the devbox listing's `prod-...` id, used
     by `devbox-ami.yml`'s `submit` job. The EKS equivalent lives in
     `eks/versions.env` because that product id is not a secret either; this one
     is a repo variable only so the workflow does not need a repo edit to move
     between a limited and a public listing.
3. Environments:
   - `marketplace-publish` and `devbox-smoke` — both exist so the workflow can
     reference them. Whether they carry required reviewers is a judgement call;
     see **Unattended runs** below.

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

`devbox-ami.yml` splits the same way and for a similar reason: publishing an AMI
id to SSM is reversible (the next build overwrites it), but a Marketplace version
is not — a rejection permanently consumes the version title.

**`submit: true` forces an AMI build.** A Marketplace version is (AMI + template +
copy) reviewed as a unit: the template of a published version cannot be changed,
and a new version cannot reuse an AMI. So shipping any template change needs a
fresh AMI even when the devbox image has not moved, and there is no such thing as
a template-only version. The `submit` job therefore uses ordinary `needs`
gating — build, smoke and publish must all have succeeded — rather than the
`always()` bypass an earlier version needed.

Both products support `validate_only`, which submits under `Intent=VALIDATE` and
creates nothing; use it as a rehearsal before spending a version title.

## Why two roles

The smoke test deploys a whole devbox stack — EC2, Aurora, ALB, Cognito, IAM —
which needs far broader rights than publishing does. Putting that on the
publishing role would mean every scheduled AMI build ran with those credentials,
so it is a separate principal (`github-actions-flyte-devbox-smoke`) trusted
**only** from the `devbox-smoke` environment.

## Unattended runs

The smoke role used to carry `PowerUserAccess` **+ `IAMFullAccess`**, and a
required reviewer on `devbox-smoke` was the only thing between a workflow file
and a credential that could mint an admin role. That gate was load-bearing
because the role was over-powered — so the role got fixed instead.

It now has `PowerUserAccess` plus a scoped grant. CloudFormation auto-names the
stack's IAM objects from the stack name, so the IAM permissions are limited to
`flyte-devbox-smoke-*` and nothing else, and a deny-list keeps it away from the
things whose loss would actually hurt:

| denied | why |
|---|---|
| attaching `AdministratorAccess` / `IAMFullAccess` / `PowerUserAccess` | closes the escalate-then-pass route |
| any `iam:*` on the two CI roles, the ingestion role, the OIDC provider | it cannot rewrite the identities that trust it |
| writes/deletes on `flyte-marketplace-assets-*` | listing artifacts are not its business |
| `ssm:PutParameter`/`DeleteParameter` on `/flyte-devbox/*` | only the publish job moves the AMI pointer |
| `aws-marketplace:*` | it cannot submit, restrict or alter a listing |
| any region but `us-east-1` | bounds a runaway to one region |

With that in place the reviewer on `devbox-smoke` is a spend control rather than
a security control, and removing it is a reasonable trade for unattended runs.
`marketplace-publish` is likewise less load-bearing than it was: the submit
script now waits for `Intent=VALIDATE` to come back `SUCCEEDED` before it applies
anything, so a bad payload is caught before a version exists.

**Order matters.** Re-run `infra/seller-account-setup.sh` (it detaches
`IAMFullAccess` and installs the guardrails) *before* removing the reviewer from
`devbox-smoke`. Removing the gate first leaves the old, over-powered role
ungated.

What a reviewer still buys you: the smoke test spends real money (Aurora, an ALB,
an EC2, ~30 minutes), and nothing here caps that.

Run with `skip_smoke: true` to bypass it — that publishes an unvalidated AMI to
SSM, which is exactly what the smoke test exists to prevent, so treat it as a
break-glass option rather than a convenience.
