# AWS Marketplace publishing

This offering is **two Marketplace products** that work together.

## Artifact A — Flyte EKS add-on (container product)

An [EKS add-on](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
that installs the Flyte 2 backend into a cluster. Add-ons deploy **in-cluster
resources only** — they cannot create Aurora/S3/IAM, which is why Artifact B
exists.

- **Package**: `addon/chart/flyte-eks` (wrapper over flyte-binary `v2.0.27`),
  vendored self-contained by `scripts/vendor-chart.sh`.
- **Config surface**: `addon/addon-configuration-schema.json` — the knobs EKS
  merges into the chart via `AWS::EKS::Addon` `ConfigurationValues`.
- **Build/publish**: `scripts/build-addon.sh` mirrors images into the
  Marketplace-provisioned ECR, pushes the chart as an OCI artifact, then the
  version is submitted in the portal for **Conformitron** validation
  (see the [Addons Transformer](https://github.com/aws-samples/addons-transformer-for-amazon-eks)).
- **IAM**: uses **EKS Pod Identity** (`serviceAccount: flyte-backend`,
  `namespace: flyte`). The role is created by Artifact B and attached via
  `--pod-identity-associations` / `AWS::EKS::PodIdentityAssociation`.

## Artifact B — CloudFormation full-stack (Phase 2)

Provisions VPC, EKS, Aurora Serverless v2, S3, IAM, Cognito/ALB/ACM/Route53,
then installs Flyte via the resolver (add-on when published, helm otherwise).

## The publish-vs-validate gap (why the resolver exists)

You must be able to validate an unpublished add-on version. The resolver
([scripts/resolve-install.sh](scripts/resolve-install.sh)) checks whether
`ADDON_VERSION` is live in the catalog:

- **published** → `aws eks create-addon` (real add-on path)
- **not yet** → `helm upgrade --install` of the *same* vendored chart + config

So the pipeline can build/submit the add-on while every dev deploy still runs
the exact same software immediately via helm. When the version clears review,
the identical stack silently switches to the add-on path — no template change.

## Release checklist (per version)

1. Bump `ADDON_VERSION` (+ `FLYTE_CHART_VERSION` if upgrading Flyte) in
   [versions.env](versions.env), and the mirrored `version:` in
   `addon/chart/flyte-eks/Chart.yaml` and `addon/metadata.yaml`.
2. `scripts/validate.sh` (offline lint/template/drift checks).
3. Deploy to a scratch cluster via the helm fallback; `scripts/smoke-test.sh`.
4. `scripts/build-addon.sh`; submit the version; pass Conformitron.
5. Once ACTIVE in the catalog, the resolver flips to the add-on path.
