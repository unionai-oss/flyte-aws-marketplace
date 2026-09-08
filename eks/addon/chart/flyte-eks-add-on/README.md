# flyte-eks — AWS Marketplace EKS add-on package

Wrapper chart submitted to AWS Marketplace as the Amazon EKS console add-on
delivery option. See [../../MARKETPLACE.md](../../MARKETPLACE.md) for the
release runbook.

Two files here are read by AWS at ingestion time, not by Helm. Their names are
fixed by the add-on framework and they must sit at the top level of the chart:

| file | what it does |
|---|---|
| `aws_mp_configuration_schema.json` | The buyer-facing configuration surface. EKS validates `--configuration-values` against it and rejects non-conforming input, and renders each property's `description` as a field label in the EKS console. |
| `aws_mp_addon_parameters.json` | Declares Pod Identity compatibility. This is what enables the **Add-on access** section on the console's *Add-on configuration settings* page, where a buyer attaches an IAM role to the add-on's service account. |

## Why `managedPolicies` is empty

`aws_mp_addon_parameters.json` can list AWS *managed* policy ARNs to pre-populate
for the service account. Flyte's backend needs `s3:GetObject/PutObject/
DeleteObject/ListBucket/GetBucketLocation` scoped to the single bucket
provisioned for that deployment — see the `flyte-s3-access` inline policy in
[../../cloudformation/templates/iam.yaml](../../cloudformation/templates/iam.yaml).
That ARN is per-deployment and unknowable at publish time, and the only managed
policy that would cover it (`AmazonS3FullAccess`) grants account-wide S3 access,
which conflicts with the Marketplace requirement that products "only require
least privileges to run."

So the file declares the service account and Pod Identity compatibility, and the
role itself comes from whichever install path is used:

- **CloudFormation (Artifact B)** creates the bucket-scoped role and the
  `AWS::EKS::PodIdentityAssociation` binding it to `flyte-backend`.
- **EKS console** — the buyer supplies their own role in the Add-on access
  section; the deployment guide documents the required policy document.

Confirm this shape with AWS Marketplace ops before submitting: an empty
`managedPolicies` array is the honest encoding of "bucket-scoped, caller
supplied", but it is not a case the published schema example covers.
