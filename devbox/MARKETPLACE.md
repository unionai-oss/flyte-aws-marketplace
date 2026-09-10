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
- [ ] No `authorized_keys` / default passwords baked in (the build keypair is
      removed from `/root` and `/home/*` in the final packer provisioner — a
      leftover one fails the scan's "Default authorized keys" check)
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

## 3a. Marketplace assets (template + diagram)

`scripts/package-marketplace.sh` builds the buyer-facing template and uploads it
with the architecture diagram to the seller account's asset bucket:

```bash
AWS_PROFILE=union-seller scripts/package-marketplace.sh
```

- Bucket: `s3://flyte-marketplace-assets-747712783559`, `devbox/*` is
  **public-read** by bucket policy (ACL public access stays blocked, and the
  bucket root is not listable). It has to be: buyers' CloudFormation fetches the
  nested stack templates from here at launch time.
- Submit the **versioned** template URL, not `flyte-devbox-latest.yaml` — a
  listing should not change underneath a version AWS has already reviewed.

### Why the listing template is not root.yaml

The script rewrites two things, both of which are cases where what the repo wants
for its own deploys is exactly what Marketplace rejects.

**1. `AmiSsmParameter` is stripped.**

```yaml
AmiSsmParameter:
  Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
  Default: /flyte-devbox/ami/latest
```

CloudFormation resolves SSM-parameter-typed parameters in the account running
the stack, referenced or not. Buyers have no `/flyte-devbox/ami/latest`, so every
launch would fail at parameter resolution — even though Marketplace populates
`AmiId` and the `HasAmiId` condition would have made the SSM value irrelevant.
`root.yaml` keeps it, because it is what lets the AMI pipeline publish a new
image with no template change. (`HasAmiId` is dropped from the variant too, since
with the SSM parameter gone it selects between nothing.)

**2. Nested `TemplateURL`s are rewritten to the `MPS3*` parameters.**

`root.yaml` uses relative paths so `aws cloudformation package` resolves them for
our own deploys — but package turns them into hardcoded S3 URLs, and Marketplace
rejects those. The URLs must be built from three parameters whose names AWS fixes:

```yaml
TemplateURL: !Sub https://${MPS3BucketName}.s3.${MPS3BucketRegion}.${AWS::URLSuffix}/${MPS3KeyPrefix}compute.yaml
```

AWS rewrites those defaults when it copies the nested templates into its own
bucket. So the script uploads the nested templates under **stable names** to
`devbox/templates/` and does the rewrite itself, rather than calling `package`.
The uploaded names must stay in step with the `NESTED` table in the script.

## 4. CloudFormation product wiring

These are the rules the CloudFormation review actually enforces — each one below
cost a rejected submission:

- **No default CIDR that opens remote access to the internet.** `AllowedCidr` has
  no `Default`; buyers must supply their range. Same rule covers database ports
  and default passwords.
- **No seller-hosted Lambda code.** Marketplace neither ingests nor scans objects
  in a seller bucket, so `Code:` pointing at a directory (which
  `cloudformation package` zips and uploads) counts as an external dependency.
  Every Lambda here is inline `ZipFile`. This is why the Cognito hosted-UI logo
  is gone: only the `SetUICustomization` API can set a logo, which needed a
  Lambda plus a 25 KB PNG, so `common/cloudformation/auth.yaml` uses the native
  CSS-only `UserPoolUICustomizationAttachment` instead.
- **Nested templates must be publicly readable** and referenced via `MPS3*` (see
  above). Check with an unauthenticated `curl` after uploading.
- The AMI comes from a template parameter (`AmiId`), never a hardcoded id or a
  community AMI.
- Parameters are grouped for the console with `AWS::CloudFormation::Interface`,
  which the variant adds.

## 5. Listing (Marketplace Management Portal)

- [ ] Product title, short/long description, categories
- [ ] Pricing model (BYOL / hourly / free) + EULA
- [ ] Support details + refund policy
- [ ] Architecture diagram (`docs/architecture.svg` -> `architecture.png`,
      uploaded by `scripts/package-marketplace.sh`) + usage instructions
- [ ] Submit for review (AWS review is typically several business days)

## Pre-submit gate

Run the full pipeline locally before submitting:
```bash
./scripts/validate.sh          # static gate (also the Buildkite per-PR step)
./scripts/smoke-test.sh        # deploy → flyte run → teardown (real AWS spend)
```
