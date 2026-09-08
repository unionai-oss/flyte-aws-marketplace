# flyte-eks-add-on — AWS Marketplace EKS add-on package

Wrapper chart submitted to AWS Marketplace as the Amazon EKS console add-on
delivery option. See [../../MARKETPLACE.md](../../MARKETPLACE.md) for the
release runbook.

`aws_mp_configuration_schema.json` at the top level is read by AWS at ingestion,
not by Helm. Its name is fixed by the add-on framework. EKS validates
`--configuration-values` against it, rejects non-conforming input, and renders
each property's `description` as a field label in the EKS console.

## Why there is no `aws_mp_addon_parameters.json`

That file declares Pod Identity compatibility and enables the **Add-on access**
section on the EKS console's *Add-on configuration settings* page, where a buyer
attaches an IAM role to the add-on's service account. We do not ship it, after
trying to.

It can list AWS *managed* policy ARNs to pre-populate for the service account.
Flyte's backend needs `s3:GetObject/PutObject/DeleteObject/ListBucket/
GetBucketLocation` scoped to the single bucket provisioned for that deployment —
see the `flyte-s3-access` inline policy in
[../../cloudformation/templates/iam.yaml](../../cloudformation/templates/iam.yaml).
That ARN is per-deployment and unknowable at publish time. The two ways to
encode it both fail:

- **Empty `managedPolicies: []`** — submitted in add-on version 0.1.1 and
  rejected: *"Invalid Helm Chart Addon Parameters — Invalid Permissions List
  provided."* The validator wants at least one ARN.
- **`arn:aws:iam::aws:policy/AmazonS3FullAccess`** — the only AWS-managed policy
  that functionally fits, since read-only cannot work. It grants account-wide
  S3, against the Marketplace requirement that products "only require least
  privileges to run", which AWS scans for.

So the file is omitted and the role comes from whichever install path is used:

- **CloudFormation (Artifact B)** creates the bucket-scoped role and the
  `AWS::EKS::PodIdentityAssociation` binding it to `flyte-backend`. Unaffected —
  this is the supported path.
- **EKS console / CLI** — the buyer supplies their own role via
  `--pod-identity-associations`; the usage instructions carry the policy
  document they need.

The cost is the console's Add-on access section. Pod Identity itself still
works. AWS's docs say an add-on needing AWS access "must" include this file, but
that reads as review guidance rather than a validator rule, and the published
error table has no code for its absence — so a reviewer may still raise it.
Worth settling with Marketplace Seller Operations, who can state the expected
shape for a bucket-scoped, caller-supplied role. If they give one, add the file
back and re-enable the check in `scripts/validate.sh` step 6a.
