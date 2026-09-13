# arm64 / Graviton support — plan

**Status:** deferred, 2026-09-13. Agreed to hold until the pending Marketplace
version lands, to keep one change in flight at a time. Nothing below is
implemented.

## Why

Graviton (m7g/m6g/g5g) is meaningfully cheaper than the m6i default for
equivalent work, and it is the only *large* cost lever left that is independent
of how the devbox is used — auto-stop and Spot both already exist, and the OS
choice is not a lever at all (standard Ubuntu Server carries no licence
surcharge, same as Amazon Linux; only RHEL/SUSE/Windows and Ubuntu **Pro** do).

## Upstream is not the blocker

Both tags publish `linux/arm64` alongside `linux/amd64` (checked 2026-09-13):

```
cr.flyte.org/flyteorg/flyte-devbox:latest      index sha256:c119ad4d6283…
  linux/arm64  sha256:6c0aeaf85685…
  linux/amd64  sha256:facab6270430…
cr.flyte.org/flyteorg/flyte-devbox:gpu-latest
  linux/arm64  sha256:1e596a35376d…
  linux/amd64  sha256:bcf16460fa51…
```

`gpu-latest` having arm64 matters: on Graviton the only NVIDIA family is **g5g**
(T4G), so GPU on arm64 is g5g-only. The PCI-vendor detection in user-data is
architecture-independent and stays dormant otherwise.

## Build changes (mechanical)

| where | change |
|---|---|
| `packer/provision.sh:16` | AWS CLI URL is pinned to `awscli-exe-linux-x86_64.zip`; select `-aarch64` by `uname -m` |
| `packer/provision.sh:55` | ecr-credential-provider pinned to `linux/amd64/…-linux-amd64`; select by arch |
| `packer/flyte-devbox.pkr.hcl:56` | source AMI filter pinned to `…-noble-24.04-amd64-server-*`; make the arch a variable |
| `packer/flyte-devbox.pkr.hcl` `instance_type` | needs an arm64 build host (e.g. `m7g.xlarge`) when building arm64 |
| `packer/flyte-devbox.pkr.hcl` `ami_name_prefix` | needs an arch suffix so both AMIs coexist |

`packer/files/gpu-setup.sh` needs checking too: `ubuntu-drivers install --gpgpu`
and the NVIDIA container-toolkit apt repo do publish arm64, but this is the part
most likely to behave differently and should be smoke-tested on a g5g before it
is claimed to work.

## Template / SSM changes

- `/flyte-devbox/ami/latest` is a single per-region pointer. Needs to become
  per-arch (e.g. add `/flyte-devbox/ami/arm64/latest`), maintained per region.
- `root.yaml` must choose. CloudFormation cannot derive an architecture from an
  `InstanceType` string, so this is either an explicit `Architecture` parameter
  or a mapping. **Note the trap:** `AWS::SSM::Parameter::Value<…>` parameters
  resolve in the deploying account whether or not they are referenced, so
  declaring both means both must exist in every region — the same behaviour that
  forces `package-marketplace.sh` to strip `AmiSsmParameter` for the listing.
- Both new parameters need grouping and labelling in the `Interface` block;
  `scripts/validate.sh` has no check for that, but the
  ungrouped/phantom/unlabelled assertions used during the launch-form work are
  worth re-running.

## CI changes

`devbox-ami.yml` builds one AMI. It needs a matrix over architectures, writing
each arch's id to its own SSM parameter, with the existing gate preserved: the
pointer is only written after that arch's smoke test passes.

## How other sellers do it (researched 2026-09-13)

The question is settled well enough to design against, and the answer is
**separate listings**.

- The CloudFormation delivery docs say a template "can be configured to deliver
  a **single** Amazon Machine Image (AMI)". A single-AMI solution may carry up to
  three CloudFormation templates, but those are alternative *topologies or
  configurations*, not architectures - the Catalog API separately requires that
  all delivery options in a version share one `AmiSource`.
- The architecture policy says AMIs "must use x86-64 **or** 64-bit ARM
  architecture" - one or the other, per AMI, and an AMI is single-architecture by
  construction.
- The Management Portal's add-version flow makes you pick an architecture
  (X64 vs ARM) and then give one AMI, with no way to attach a second AMI for a
  second architecture. Sellers have asked AWS for this directly and been left
  creating separate listings.
- What shipping products actually do: ARM builds appear as their own listings -
  "Rocky Linux 9 (ARM)", "Alma Linux 9 (ARM)" - sitting alongside their x86
  counterparts rather than inside them.

A second listing is affordable: the default cap is 75 public AMI listings per
seller. The cost is duplicated listing copy, pricing and support metadata, and a
second submission pipeline - `MARKETPLACE_PRODUCT_ID` would become per-arch, and
`submit-version.sh` would need to pick the right one alongside the right AMI.

Two adjacent findings worth keeping:

- **Test 'Add Version'** exists in the Management Portal: it runs the scan and
  returns consolidated feedback, typically within an hour, *before* a formal
  submission. Given how much of this has been learned by rejection, that is worth
  using on the first arm64 version.
- **Version archival**: a version restricted for over two years is archived, and
  an archived version unused for 13 months is permanently deleted. Relevant if an
  arm64 listing stays quiet.

## The remaining open question — Marketplace

Unresolved, and it decides whether arm64 can reach buyers at all:

> For AMI products, a version is made up of one or more delivery options. **All
> delivery options in the same version must have the same `AmiSource` object
> with the same details.**

Read alongside the `Duplicate AMI id` rejection (every version needs a distinct
AMI), that suggests **one AMI per version**, so a single version probably cannot
serve both architectures. `TemplateSources` being an array leaves room for the
opposite reading, but that is a guess about an API whose behaviour has
repeatedly differed from its documentation.

Cheap way to settle it definitively: build the arm64 AMI, then submit a change
set whose `TemplateSources` has two entries (`AmiId` → x86_64, `AmiIdArm64` →
arm64) with `Intent=VALIDATE` in **add** mode - add accepts Intent, so this costs
no version title. Everything above says it will be refused; do it anyway, because
this API has contradicted its own documentation repeatedly (see
`UpdateDeliveryOptions` accepting `Template` on paper and rejecting it in
practice), and a minute of validation beats reasoning from docs.

If it is one AMI per version, the options are two versions (buyer picks) or a
second listing; neither is obviously right, and that decision should be made
with the validation result in hand rather than in advance.

## Ordering

1. Land the pending Marketplace version first.
2. Build changes + arm64 AMI, smoke-tested (including g5g if GPU is claimed).
3. Per-arch SSM + template selection + CI matrix — self-managed deploys benefit
   immediately, with no Marketplace exposure.
4. Only then probe the Marketplace multi-arch question above.
