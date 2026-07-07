# Publishing to AWS Marketplace

Release runbook for shipping this as a **CloudFormation-based AWS Marketplace
product** (the buyer launches our CFN template, which references our AMI). Buyer
docs live in [README.md](README.md); this file is the seller checklist.

## Artifacts

| Artifact | Source | Notes |
|---|---|---|
| AMI | `packer/` (`packer build`) | Ubuntu 24.04 + Docker + devbox image + auth proxy/sidecar baked in |
| CloudFormation template | `cloudformation/flyte-devbox.yaml` | the deployable product; resolves the AMI from SSM `/flyte-devbox/ami/latest`, or pin one with `AmiId` |
| Buyer docs | `README.md` | usage, modes, auth, cost |

## 1. Build + harden the AMI

```bash
cd packer && packer init .
# The build instance needs a public subnet (account-specific). Discover one:
SUBNET=$(aws ec2 describe-subnets --filters Name=map-public-ip-on-launch,Values=true --query 'Subnets[0].SubnetId' --output text)
VPC=$(aws ec2 describe-subnets --subnet-ids "$SUBNET" --query 'Subnets[0].VpcId' --output text)
packer build -var subnet_id="$SUBNET" -var vpc_id="$VPC" .
# Pin a specific devbox image with: -var devbox_image=<ref>  (default: cr.flyte.org/flyteorg/flyte-devbox:latest)
```
`provision.sh` already does the marketplace AMI hygiene: no baked credentials,
cleans apt lists, and clears machine-id / SSH host keys / cloud-init state / shell
history so every launched instance regenerates them. IMDSv2 is enforced on build.

**Do not encrypt the AMI** — Marketplace distributes unencrypted AMIs; the CFN
template encrypts the EBS volumes at launch instead.

## 1a. Automated builds — no PR per AMI

The Buildkite pipeline (`.buildkite/`) republishes the AMI on each devbox release
without a code change:

1. A **scheduled build** on `main` runs `check-and-build.sh`, comparing the current
   `cr.flyte.org/flyteorg/flyte-devbox:latest` digest to the one the last AMI was
   built from (SSM `/flyte-devbox/ami/source-digest`).
2. On a change it builds the AMI, runs the smoke test, and **only on success**
   writes the new AMI id to SSM `/flyte-devbox/ami/latest`.
3. The template's `AmiSsmParameter` resolves that value at deploy time, so new
   deploys (and `update-stack` with `AmiId=""`) pick it up automatically.

Force a rebuild any time with build env `FORCE_BUILD=true`; pin a specific AMI with
the `AmiId` parameter. The SSM parameters are **per-region** and must exist in any
region you deploy to (the pipeline maintains them; seed a new region with one build
there). For an AWS Marketplace listing, AWS versions the AMI for buyers separately —
this SSM flow is for self-managed deploys.

## 2. AWS self-service AMI scan

In the **AWS Marketplace Management Portal → Products → Server → AMIs**, share the
AMI with the Marketplace account and run the self-service scan. It checks ~30
items; the ones this build is built to pass:
- [ ] No hardcoded secrets / access keys (creds come from the instance profile)
- [ ] No `authorized_keys` / default passwords baked in
- [ ] SSH host keys + machine-id regenerated on boot (cleared in `provision.sh`)
- [ ] `cloud-init` + SSM agent present and enabled
- [ ] OS packages reasonably current (`apt-get update` at build)
- [ ] Root volume ≤ the listed size; no leftover build artifacts

## 3. Region replication

Marketplace requires the AMI in every region you list. Build once, copy out:
```bash
for r in us-east-1 us-west-2 eu-west-1; do
  aws ec2 copy-image --source-region us-east-1 --source-image-id "$AMI_ID" \
    --region "$r" --name "flyte-devbox-$(date +%Y%m%d)"
done
```
Publish each region's AMI id to that region's SSM `/flyte-devbox/ami/latest` (the
template resolves it via `AmiSsmParameter`). The pipeline does this per build.

## 4. CloudFormation product wiring

- The template resolves the AMI from the per-region SSM parameter
  `/flyte-devbox/ami/latest` (override with `AmiId`); no hardcoded id.
- Confirm no parameters expose secrets; `AllowedCidr` defaults to `0.0.0.0/0`
  (document tightening it).
- Validate with the Marketplace template requirements (IAM capabilities,
  parameter labels/groups via `AWS::CloudFormation::Interface`).

## 5. Listing (Marketplace Management Portal)

- [ ] Product title, short/long description, categories
- [ ] Pricing model (BYOL / hourly / free) + EULA
- [ ] Support details + refund policy
- [ ] Architecture diagram + usage instructions (link README)
- [ ] Submit for review (AWS review is typically several business days)

## Pre-submit gate

Run the full pipeline locally before submitting:
```bash
./scripts/validate.sh          # static gate (also the Buildkite per-PR step)
./scripts/smoke-test.sh        # deploy → flyte run → teardown (real AWS spend)
```
