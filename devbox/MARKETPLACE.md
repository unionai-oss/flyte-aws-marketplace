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

## 3c. Where cluster state actually lives

k3s state is the `flyte-k3s-data` **named docker volume**, which sits under
docker's `data-root`. The user-data moves that root onto the EBS data volume at
first boot (one-time `tar` copy, then `data-root` in `daemon.json`). Before that
fix it sat on the instance root volume - `DeleteOnTermination: true`, and not the
volume `BackupSelection` tags - so the nightly snapshot captured `storage/` and
nothing else, and any instance replacement silently discarded the cluster.

If you change the data-volume mount, the docker migration or the `flyte-k3s-data`
mount, check all three together. Two comments in the templates claimed this
arrangement long before it was true.

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
- Parameters are grouped for the console with `AWS::CloudFormation::Interface`.
  That block lives in `root.yaml` (our own console deploys want the same
  ordering); the variant only *patches* it — the "AMI source" group becomes
  the "AWS Marketplace" group, `AmiSsmParameter` drops out of it, and the three
  `MPS3*` parameters drop in. The group stays **last** so a buyer reads the
  deployment route, network access and sizing before reaching a group whose
  label tells them not to touch it. The `MPS3*` fields cannot be hidden —
  CloudFormation has no hidden-parameter mechanism and `NoEcho` only masks the
  value — so their descriptions say plainly that AWS owns them.
- If a buyer sees `flyte-marketplace-assets-*` as the `MPS3BucketName` default,
  they launched our seller-bucket URL directly rather than the ingested
  Marketplace version; AWS rewrites that default to its own bucket on ingestion.

### A note on template size

`validate-template --template-body` caps at **51,200 bytes**. `compute.yaml`
crossed that when Spot landed (it is now ~55 KB), which failed the packaging step
with a `Member must have length less than or equal to 51200` constraint error
rather than anything that mentioned size limits.

`package-marketplace.sh` now picks the validation method by file size: under the
cap it validates inline, over it stages the file to `<prefix>.staging/` and
validates by URL. The staging copy is never promoted to the name buyers' nested
`TemplateURL`s resolve to - the real upload happens afterwards, only once
validation passes. Staging objects are left in place and overwritten each run;
deleting them would need `s3:DeleteObject`, which the publishing role does not
have and does not need.

The separate 1 MB ceiling on S3-hosted templates is far away, and the 16 KB
base64 cap on EC2 user-data is checked by `scripts/validate.sh`.

## 3b. Submitting the version

`scripts/submit-version.sh` builds the `AddDeliveryOptions` change set and sends
it through the Catalog API, so a release is reviewed in a PR instead of retyped
into the portal at 11pm:

```bash
scripts/package-marketplace.sh        # uploads template + diagram, writes the manifest
VALIDATE_ONLY=1 scripts/submit-version.sh   # AWS's own checks, creates nothing
scripts/submit-version.sh                   # validate, then submit for real
```

Or from CI: run the **devbox AMI** workflow with `submit: true` (and
`validate_only: true` for a rehearsal). That job sits behind the
`marketplace-publish` environment. **`submit: true` forces an AMI build**, because
a template change cannot ship any other way — see below.

The devbox is an `AmiProduct@1.0` with a **CloudFormation delivery option**, so
the details key is `DeploymentTemplateDeliveryOptionDetails` — not the
`CloudFormation*` name the field naming would suggest. A version is
(AMI + template + copy) submitted together; delivery options cannot be added to
an existing version afterwards.

Set `MARKETPLACE_PRODUCT_ID` in `versions.env` (and the repo variable
`DEVBOX_MARKETPLACE_PRODUCT_ID` for CI) to the `prod-...` id from the portal URL.

### Two modes, because every version needs its own AMI

AWS requires each **version** of an AMI product to carry a **distinct AMI id**.
Submitting a new version against an AMI an existing version already uses is
rejected with *"Duplicate AMI id - The AMI Id must be different from AMI Id used
in other versions of this product"*. So a template- or copy-only change **cannot
be a new version**:

| change | mode | change type |
|---|---|---|
| anything touching the TEMPLATE, or a new AMI | `MODE=add` | `AddDeliveryOptions` |
| listing copy only (titles, descriptions, usage instructions) | `MODE=update` | `UpdateDeliveryOptions` |
| let it work that out | `MODE=auto` (default) | either |

**A template change cannot be shipped as an update.** The API rejects `Template`
on `UpdateDeliveryOptions` -

```
DeploymentTemplateDeliveryOptionDetails has properties which are not
allowed: ['Template']
```

- despite the docs listing it as updatable. That is consistent with how versions
work: the template was reviewed as part of a version, so changing what buyers
deploy under an already-reviewed version is not on offer. Combined with the
distinct-AMI rule, shipping a template change means **a new AMI and a new
version**, even when the devbox image itself has not moved. Force one with the
workflow's `force: true` input, or build locally and pass `AMI_ID=`.

So `MODE=update` is for listing copy only, and says so when it runs.

```bash
VALIDATE_ONLY=1 scripts/submit-version.sh    # auto-resolves, validates, creates nothing
scripts/submit-version.sh                    # auto-resolves and submits
```

`auto` is not a heuristic - AWS decides it. If the AMI we would submit is already
on a version, `add` is not a choice that exists (it is rejected as a duplicate),
so updating that version is the only legal action; if the AMI is new to the
listing, `add` is correct. `scripts/describe-entity.py` reads the versions off
the listing and picks. It **refuses rather than defaults** when it cannot tell -
if `DescribeEntity` returns no AMI ids, "add" might be a duplicate and "update"
might target the wrong version, so it stops and asks for an explicit `MODE`.

The duplicate check spans every AMI on the listing, not just the ones on
CloudFormation delivery options: AWS scopes the rule to the product, so an AMI
used by any other kind of option collides too. The update *target*, though, can
only be a CloudFormation option.

Update mode edits an existing version in place. It sends no `TemplateSources`
(the AMI is exactly what must not change) and no `VersionTitle`, so it consumes
no version title and a rejection can simply be corrected and resubmitted. It
finds the version and delivery option via `DescribeEntity` and prints what it
found; override with `ENTITY_IDENTIFIER=<prod-id>@<version>` and
`DELIVERY_OPTION_ID=` if the discovery picks the wrong one.

Note the two change types put `DeliveryOptionTitle` in **different places** - at
the delivery-option level for Add, inside
`DeploymentTemplateDeliveryOptionDetails` for Update. The script handles that;
mention it only because hand-editing a payload gets it wrong.

**`VALIDATE_ONLY` only works in add mode.** AWS accepts `Intent` per change
type, and rejects it outright for `UpdateDeliveryOptions` on `AmiProduct@1.0`
(*"Intent not supported for change type"*), so update has no server-side
rehearsal. Use `DRY_RUN=1` there to inspect the change set without sending it.
That asymmetry is survivable because the risk is asymmetric too: update consumes
no version title, so a rejection can be corrected and resubmitted against the
same version, while a rejected *add* spends its title permanently.

**Validation gates the submission.** In add mode the script submits
`Intent=VALIDATE`, waits for that change set to reach a terminal state, and only
applies if it came back `SUCCEEDED`. A failed validation exits non-zero having
applied nothing and consumed no version title. It then waits on the real
submission too, so the job's exit status reflects what AWS actually did rather
than what was accepted for processing. Tune with `VALIDATE_TIMEOUT` (default
1800s) and `APPLY_TIMEOUT` (default 3600s); timing out is reported separately
from failing, and does not fail the job, because the change set is submitted and
in AWS's hands either way.

`VALIDATE_ONLY=1` stops after a successful validation. It submits under `Intent=VALIDATE`, which
runs the same server-side checks without creating a version. Version titles must
be unique across the product's history and a *rejected* submission still consumes
one, so a rehearsal costs a minute and saves a burned title. The script also
refuses to submit the `flyte-devbox-latest.yaml` alias, checks for an in-flight
change set, and verifies the AMI is owned by this account in us-east-1 (the only
region the Catalog API ingests from).

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
