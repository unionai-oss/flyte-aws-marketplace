# AWS Marketplace publishing

This offering is **two Marketplace products** that work together.

## Artifact A — Flyte EKS add-on (container product)

An [EKS add-on](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
that installs the Flyte 2 backend into a cluster. Add-ons deploy **in-cluster
resources only** — they cannot create Aurora/S3/IAM, which is why Artifact B
exists.

- **Package**: `addon/chart/flyte-eks-add-on` (wrapper over flyte-binary
  `v2.0.27`), vendored self-contained by `scripts/vendor-chart.sh`.
- **Config surface**: `addon/chart/flyte-eks-add-on/aws_mp_configuration_schema.json`
  — the knobs EKS merges into the chart via `AWS::EKS::Addon`
  `ConfigurationValues`.
- **Build/publish**: `scripts/build-addon.sh` relocates every image into the
  Marketplace ECR and pushes the chart as an OCI artifact; the version is then
  added in the portal.
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

> `ADDON_PRODUCT_NAME` in [versions.env](versions.env) is still a **placeholder**.
> AWS derives the catalog name by prefixing the add-on name with the seller
> name, so it will be something like `union-ai_flyte-eks-add-on`. Until it is
> corrected, `addon_version_is_published()` never matches and the resolver stays
> on the helm fallback forever. Read the real value off the published listing and
> set it.

## How the packaging rules shaped this chart

Marketplace rejects EKS add-on submissions for a specific set of reasons. Each
one is encoded in `scripts/validate.sh` step 6 so it fails locally rather than
in a review cycle. The non-obvious ones:

| Rule | What we do |
|---|---|
| Every image must come from the Marketplace ECR, **including OSS dependencies** | All four images (backend, console, connectors, and the `postgres` init container) are relocated. `INVALID_HELM_CHART_IMAGES` otherwise. |
| Image references defined **only** in `values.yaml`, with explicit tags | The wrapper's `values.yaml` overrides `repository`/`tag` for all four. `flyteconsole-v2` floats `latest` upstream, so it is pinned to the commit tag `latest` resolved to — a floating tag is `MISSING_IMAGE_TAG`. |
| Both AMD64 and ARM64 | All four upstream images are already multi-arch. `build-addon.sh` copies exactly those two platforms, which also strips the in-toto attestation manifests (`unknown/unknown`) that the security scan rejects as unsupported architectures. |
| Configuration parameters must be **camelCase** | The `flyte-binary` subchart is aliased to `flyteBinary` in `Chart.yaml`. The alias renames `.Chart.Name` inside the subchart, so `values.yaml` sets `nameOverride: flyte-binary` to keep every rendered name (`flyte-flyte-binary-http`, …) byte-identical — `flyte-flyteBinary-http` is not a valid DNS-1123 name. |
| Config schema must not collect secrets | `passwordPath` and the Cognito/ACM ARNs are deliberately **not** declared in the schema. The DB password is mounted from the `flyte-db-credentials` Secret that Artifact B creates. `INVALID_HELM_SENSITIVE_CONFIG` otherwise. |
| Dependencies must live inside the chart | `Chart.yaml` uses `repository: "file://charts/flyte-binary"` and `vendor-chart.sh` unpacks the dependency there. An `https://` repository is `INVALID_DEPENDENT_HELM_CHARTS` even when the tarball is vendored. |
| Chart must contain a Deployment or DaemonSet | It does; the framework tracks add-on rollout through it. |
| `helm lint` / `helm template` must pass at **helm 3.19** | `HELM_MIN_VERSION` in `versions.env`; `build-addon.sh` refuses to publish below it and `validate.sh` warns. |

Two things are **not** settled and need a human before submission:

1. **Add-on category.** Marketplace restricts EKS add-ons to a fixed list
   (gitops, monitoring, logging, cert-management, policy-management,
   cost-management, autoscaling, storage, kubernetes-management, service-mesh,
   etcd-backup, ingress, load-balancer, local-registry, networking, security,
   backup, observability) "or operational software that will enhance Kubernetes
   or Amazon EKS". Flyte is a workflow orchestrator — an application, not a
   cluster component. `addon/metadata.yaml` provisionally sets
   `kubernetes-management`. Confirm with Marketplace ops before submitting.
2. **`aws_mp_addon_parameters.json` `managedPolicies` is empty.** See
   [addon/chart/flyte-eks-add-on/README.md](addon/chart/flyte-eks-add-on/README.md)
   for why (the S3 policy is bucket-scoped and per-deployment; the only managed
   policy that would cover it grants account-wide S3).

Also note: BYOL pricing is not supported for EKS add-on delivery, and the
container product must already be published before the add-on delivery option
can go live.

## Release checklist (per version)

1. Bump `ADDON_VERSION` (+ `FLYTE_CHART_VERSION` / the `MP_IMAGES` pins if
   upgrading Flyte) in [versions.env](versions.env), and the mirrored `version:`
   in `addon/chart/flyte-eks-add-on/Chart.yaml` and `addon/metadata.yaml`.
2. `scripts/validate.sh` (offline lint/template/packaging checks).
3. Deploy to a scratch cluster via the helm fallback; `scripts/smoke-test.sh`.
4. `AWS_REGION=us-east-1 scripts/build-addon.sh` — relocates images, pushes the
   chart, and prints the exact values to enter in the portal.
5. Portal → *Server products → this product → Request changes → Add new version*,
   delivery option **Amazon EKS console add-on**:
   - **Helm chart**: `709825985650.dkr.ecr.us-east-1.amazonaws.com/union-ai/flyte-eks-add-on:0.1.0`
   - **Container images**: all four URIs from `addon/metadata.yaml` `images[]`.
     Omitting one fails with `INVALID_HELM_UNDECLARED_IMAGES`.
   - **Add-on version**: `0.1.0` — `major.minor.patch`, no leading `v` (note
     `versions.env` carries `v0.1.0`).
   - **Namespace**: `flyte`. **Architecture**: AMD64 + ARM64.
     **Visibility**: Limited.
6. Once ACTIVE in the catalog, set the real `ADDON_PRODUCT_NAME` and the
   resolver flips to the add-on path.

> Only one EKS add-on delivery option is allowed per version, and you cannot add
> a new version until the current one is published in the EKS console. Get 0.1.0
> right.

## Pushing by hand

`build-addon.sh` does all of this, but for reference:

```bash
aws ecr get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin 709825985650.dkr.ecr.us-east-1.amazonaws.com

# images — crane, because a docker pull/push round-trip flattens multi-arch
crane copy ghcr.io/flyteorg/flyte-connectors:py3.12-v2.3.6 \
  709825985650.dkr.ecr.us-east-1.amazonaws.com/union-ai/flyte-eks-add-on:flyte-connectors-py3.12-v2.3.6
crane index filter <that same ref> --platform linux/amd64 --platform linux/arm64 -t <that same ref>

# chart — helm push appends <chart name>:<version>, so the target is the
# seller namespace, not the repository
helm push dist/flyte-eks-add-on-0.1.0.tgz oci://709825985650.dkr.ecr.us-east-1.amazonaws.com/union-ai
```
