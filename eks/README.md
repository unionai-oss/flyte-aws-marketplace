# Flyte 2 on Amazon EKS — AWS Marketplace

Turnkey, production deployment of **Flyte 2** on Amazon EKS, published to AWS
Marketplace. One CloudFormation stack provisions the full stack and installs
the Flyte backend as an **Amazon EKS add-on**.

```
┌──────────────────────────────────────────────────────────────────┐
│  Artifact B — CloudFormation full-stack product (cloudformation/) │
│                                                                    │
│   VPC ─► EKS cluster ─► managed nodegroup                          │
│    ├─ Aurora Serverless v2 (PostgreSQL, scale-to-zero)             │
│    ├─ S3 bucket (Flyte metadata + user data)                       │
│    ├─ IAM role + AWS::EKS::PodIdentityAssociation ──────► S3        │
│    ├─ Cognito + ALB + ACM + Route 53 (OAuth2 auth, HTTPS)          │
│    └─ Flyte install  ─── resolver picks one of: ───────────────┐   │
│         • AWS::EKS::Addon        (Artifact A, when published)   │   │
│         • helm install fallback  (same chart, unpublished dev)  │   │
└────────────────────────────────────────────────────────────────┼───┘
                                                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  Artifact A — Flyte EKS add-on (addon/)                            │
│   flyte-binary v2 chart + images → Marketplace ECR                 │
│   configurationSchema exposes: database, S3, pod-identity, ingress │
└──────────────────────────────────────────────────────────────────┘
```

## Why two artifacts

An EKS add-on can only deploy **in-cluster** Kubernetes resources — it cannot
provision Aurora, S3, or IAM. So the external AWS resources are provisioned by
CloudFormation, and Flyte itself ships as an add-on that CloudFormation invokes
with the infra outputs (`AWS::EKS::Addon` `ConfigurationValues`).

## Dual-mode install (build once, run before publishing)

The add-on is the end state, but you must be able to validate unpublished
changes immediately. The **resolver** ([scripts/resolve-install.sh](scripts/resolve-install.sh))
decides at deploy time:

| Condition | Install path |
|---|---|
| Required `ADDON_VERSION` is live in the EKS add-on catalog for this account/region | `AWS::EKS::Addon` |
| Not yet published (dev / pre-review) | `helm install` of the **same** pinned chart + **same** rendered values |

Both paths render values from one template ([addon/values/flyte-values.yaml.tpl](addon/values/flyte-values.yaml.tpl))
and one schema ([addon/addon-configuration-schema.json](addon/addon-configuration-schema.json)),
so they stay equivalent.

## Layout

| Path | Purpose |
|---|---|
| [versions.env](versions.env) | Single source of truth for pinned versions |
| [addon/](addon/) | Artifact A — the Flyte EKS add-on package |
| [cloudformation/](cloudformation/) | Artifact B — full-stack template (Phase 2) |
| [scripts/](scripts/) | vendor / render / resolve / build / validate |
| [.buildkite/](.buildkite/) | CI: build + publish add-on, deploy test (Phase 3) |

## Deploying (before Marketplace publish)

The product is a **single deployment**: VPC → EKS → Aurora/S3/IAM, then a
CodeBuild-run [bootstrap](scripts/bootstrap.sh) installs Flyte through the
resolver (helm today, add-on once published) with Cognito + ALB + ACM +
Route 53 auth.

```bash
STAGING_BUCKET=my-cfn-staging AWS_REGION=us-east-1 scripts/deploy.sh flyte-prod \
  DomainName=example.com HostedZoneId=Z123 CognitoDomainPrefix=my-flyte
```

**No-ingress test config (not a product tier):** omitting `DomainName` skips
Cognito/ALB/ACM/Route 53 and leaves Flyte reachable only via `kubectl
port-forward`. It stands up the *same* EKS + Aurora + S3 stack, so it is not a
cheaper tier — it exists only to validate the infra + Flyte install in CI
without needing a domain. Real deployments always set a domain.

See [MARKETPLACE.md](MARKETPLACE.md).

## Status

- [x] Phase 1 — add-on package: vendoring, values template, config schema, resolver (offline-validated)
- [x] Phase 2 — CloudFormation full-stack (network/eks/data/iam/auth/flyte + bootstrap); cfn-lint + shellcheck clean
- [x] **Phase 2 validated live** on a real EKS deploy (us-east-2) — see below
- [ ] Phase 2 gap — **Cognito auth is not yet wired** (endpoint deploys open). Needs the ALB `authenticate-oidc` listener action + Flyte OIDC config from the `auth.yaml` Cognito outputs.
- [ ] Phase 2 confirmation — a single unattended one-click deploy (bugs were fixed incrementally against a persistent cluster; each step is proven, the full sequence in one CodeBuild run is not yet)
- [ ] Phase 3 — BuildKite pipeline + Marketplace onboarding (Conformitron)
- [ ] Phase 4 — docs + end-to-end smoke harness

### Live validation results (2026-07-06, acct 371290552455 / us-east-2)

Deployed the full stack and drove every layer by hand:

| Check | Result |
|---|---|
| VPC / EKS / nodegroup / Aurora Serverless v2 / S3 / IAM | ✅ provisioned |
| Flyte `flyte-binary v2.0.27` install on **external Aurora** | ✅ migrated (10 tables) |
| Backend pods | ✅ `1/1`, 0 restarts |
| **Pod Identity → S3** (assume `flyte-s3` role, PUT/GET/DELETE) | ✅ works, no static keys |
| Flyte 2 Connect API via public **HTTPS** (`ProjectService/ListProjects`) | ✅ 200, returns `flytesnacks` |
| Console via HTTPS (`/v2`) | ✅ 200 |
| ALB + ACM + Route 53 | ✅ both target groups healthy |

Five deploy bugs found and fixed during validation (all pushed): missing
`iam:PassRole`; ALB-controller cold-start race; WaitCondition never signalling
failure; `log()` polluting a captured `CERT_ARN` + duplicate `ingress:` key;
console ALB health-check path (`/v2`, not `/healthz`).

See [MARKETPLACE.md](MARKETPLACE.md) for the listing/publishing details.
