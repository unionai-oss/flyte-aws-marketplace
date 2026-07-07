# flyte-aws-marketplace

Two AWS Marketplace products that deploy **Flyte 2** on AWS. They share a data +
auth substrate and differ only in compute:

| Product    | Compute                                              | Auth / ingress                                  |
|------------|------------------------------------------------------|-------------------------------------------------|
| **devbox** | a single EC2 running the flyte-devbox image (k3s-in-docker), behind an ALB; ships as a packer AMI | ALB-native Cognito (jwt-validation + authenticate-cognito listener rules) |
| **eks**    | Flyte on EKS via an EKS add-on                        | ALB-native Cognito (jwt-validation + authenticate-cognito listener rules)                 |

## Layout

```
common/cloudformation/         the shared substrate — one source of truth
  data.yaml                    S3 + Aurora Serverless v2 (scale-to-zero) + generated DB secret
  auth.yaml                    Cognito user pool + hosted UI + resource server + OAuth2 clients

devbox/                        the single-EC2 product
  cloudformation/root.yaml     network + IAM instance profile + SG + volume/backup + ECR;
                               nests common/{data,auth} (Prod mode) + templates/compute.yaml
  cloudformation/templates/compute.yaml   EC2 host + ALB (auth listener rules) + wake/stop lambdas
  packer/  scripts/            AMI build + validate/smoke

eks/                           the EKS product
  cloudformation/root.yaml     network + eks + IAM (Pod Identity) + ECR;
                               nests common/{data,auth} + templates/flyte.yaml
  cloudformation/templates/    network.yaml, eks.yaml, iam.yaml, flyte.yaml
  addon/  scripts/  versions.env           add-on package + validate/smoke

scripts/validate-all.sh        static validation for common + both products
.buildkite/                    one pipeline, path-filtered (see below)
```

## The design rule

`common/` holds only **genuinely identical** resources. Where the two products
differ on a value, it is a stack **Parameter** (or **Condition**) with a sensible
default, and each product's `root.yaml` passes its own value. There are **no
`if devbox / else eks` conditionals inside the shared files.** Things that are
legitimately different stay per-product and are *not* shared:

- **network** — devbox: 1 public subnet + EIP; eks: public/private subnets + NAT + k8s subnet tags
- **IAM binding** — devbox: EC2 instance profile; eks: EKS Pod Identity
- **compute** — devbox: AMI/EC2 + ALB listener rules + wake/stop lambdas + idle-agent; eks: cluster + add-on

The S3 bucket, Aurora cluster, and ECR repository are all **retained on teardown**
(they hold real data/images), so they share one lane and live in `common/data.yaml`;
each product just passes its own name.

### What each product passes to the shared stacks

| common param | devbox | eks |
|---|---|---|
| `data.NamePrefix` | `<stack>-flyte` | `flyte-<cluster>` |
| `data.SubnetIds` | the two public subnets | the private subnets |
| `data.ClientSecurityGroupId` | EC2 instance SG | EKS cluster SG |
| `data.EngineVersion` | `17.9` | `17.9` |
| `data.DBMaxCapacity` | `4` | `16` |
| `data.EcrRepositoryName` | `<stack>-flyte` | `<cluster>-flyte-tasks` |
| `auth.FlyteHost` | `<domain>` | `flyte.<domain>` |
| `auth.CliCallbackUrls` | `localhost:8089` (+8080, `<domain>`) | `localhost:53593` (SDK default) |
| `auth.ResourceServerIdentifier` / scope | `https://<domain>` / `access` | `https://flyte` / `all` |
| `auth.CreateM2MClient` | `true` (CI smoke) | `false` |

> The devbox CLI callback is **8089** on purpose — it is byte-matched by the
> native auth-discovery test and served by the wake lambda while the box sleeps.
> If you ever change it, change it in lockstep across the Cognito cli client,
> `render-override.sh` (`runs.authMetadata.redirectUri`), the wake lambda `_pcc`,
> and `devbox/scripts/validate.sh`'s byte-match.

## Validating

No AWS credentials required:

```bash
scripts/validate-all.sh      # common + devbox + eks
devbox/scripts/validate.sh   # devbox only (cfn-lint, packer, shellcheck, python, byte-match)
eks/scripts/validate.sh      # eks only (cfn-lint, helm lint/template, value-path assertions)
```

Full smoke tests cost real AWS money (and a ~30-min AMI build for the devbox) —
run them deliberately: `devbox/scripts/smoke-test.sh`, `eks/scripts/smoke-test.sh`.

## Deploying

Both roots use nested stacks, so deploy via `aws cloudformation package` (the
per-product `scripts/deploy.sh` / `smoke-test.sh` do this for you):

```bash
aws cloudformation package --template-file eks/cloudformation/root.yaml \
  --s3-bucket <staging-bucket> --output-template-file /tmp/packaged.yaml
aws cloudformation deploy --template-file /tmp/packaged.yaml --stack-name flyte \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND
```

## CI

`.buildkite/pipeline.yml` runs one generator (`generate.sh`) that path-filters:
a change under `common/**` re-validates **both** products; `devbox/**` or `eks/**`
validates that product. On `main` it also runs the devbox AMI release-check
(build → smoke → publish when a new devbox image ships).
