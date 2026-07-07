# flyte-devbox-aws-marketplace

A single-EC2 deployment of the [Flyte 2 devbox](https://www.union.ai/docs/v2/union/user-guide/run-modes/running-devbox/)
packaged for AWS. One self-contained CloudFormation template, no build step — edit
the YAML, deploy the YAML. The EC2 user-data, the idle-polling agent, both lambdas,
and the auth sidecar are all embedded inline.

It auto-stops the EC2 when no Flyte executions have run for `IdleThresholdMinutes`,
so you only pay for compute while you're actually using it.

## Two deployment modes

The mode is chosen by **whether you set `Domain`** at deploy time.

### Dev mode — ephemeral, IP-locked (no `Domain`)
The fastest way to stand up a throwaway devbox. Everything is **in-cluster**:
rustfs (an S3-compatible object store) and embedded PostgreSQL, both on a
snapshotted EBS volume. **No auth** — access is locked to your IP via `AllowedCidr`
on the security group, reached over plain HTTP on the instance's Elastic IP. Auto-stops
when idle; restart with `aws ec2 start-instances`.

*Use it for:* quick evals, experiments, demos you'll tear down — a disposable box
gated to your network, nothing external to manage.

### Prod mode — durable, authenticated (`Domain` set)
A persistent, shareable single-node deployment. Adds:
- **External, durable backends** — S3 object store + **Aurora Serverless v2**
  (PostgreSQL, scale-to-zero) + ECR, all auto-wired into Flyte at boot. Data
  survives instance replacement.
- **AWS Cognito auth** (OAuth2) — browser SSO, native CLI PKCE for humans,
  client-credentials (M2M) for CI. No static secrets in client config.
- **ALB + ACM HTTPS + Route 53** at your domain, with auth-gated auto-wake (a
  stopped box wakes on an authenticated request).

*Use it for:* a long-lived devbox a team can sign into over HTTPS.

### Beyond a single node
This stack is intentionally **single-EC2** — simple, cheap, auto-stopping. For
multi-node / HA / heavy concurrent use, that's the boundary: move to **EKS + the
Flyte Helm chart** (or [Union](https://www.union.ai/) for a managed control plane).
This template is the "one box, get going" option, not a cluster.

## Deploy

The instance launches from a **prebuilt AMI** (Docker + the devbox image + the
auth proxy/sidecar baked in — see `packer/`), so boot is fast and self-contained.
The template resolves the AMI from the per-region SSM parameter
`/flyte-devbox/ami/latest` (kept current by the build pipeline); pass `AmiId=ami-…`
to pin a specific one. It creates its own VPC + two public subnets — no networking params to
plumb in. (Don't pick a `VpcCidr` overlapping `10.42.0.0/16` / `10.43.0.0/16` —
the k3s pod/service CIDRs — or in-cluster DNS breaks.) GPU is auto-detected: pick a
GPU instance type and the devbox starts with `--gpus all`; no flag to set.

> The template is >51 KB, so the `aws cloudformation deploy` CLI needs an S3
> staging bucket: add `--s3-bucket <bucket>` (any bucket you own). The console /
> Marketplace launch path handles this for you.

**Dev mode:**
```bash
aws cloudformation deploy \
  --stack-name flyte-devbox-dev \
  --template-file cloudformation/flyte-devbox.yaml \
  --capabilities CAPABILITY_IAM \
  --s3-bucket <your-bucket> \
  --parameter-overrides \
      AllowedCidr=$(curl -s -4 ifconfig.me)/32 \
      IdleThresholdMinutes=30
```

**Prod mode** (add a domain you control in Route 53 — its hosted zone is found
automatically, so there's no zone id to look up):
```bash
aws cloudformation deploy \
  --stack-name flyte-devbox-prod \
  --template-file cloudformation/flyte-devbox.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --s3-bucket <your-bucket> \
  --parameter-overrides \
      Domain=flyte.example.com \
      AllowedCidr=0.0.0.0/0
```

Key parameters: `InstanceType` (default `m6i.2xlarge`), `DataVolumeSizeGb` (50),
`AutoStop` (`Yes`), `StableIp` (`Yes`), `IdleThresholdMinutes` (30),
`NoPublicIngress` (`No`), `AmiId` (blank = use the SSM-published latest AMI). First deploy is ~3–6 min
(fast boot from the AMI; Prod also creates Cognito + Aurora).

After deploy, check `Outputs`:
```bash
aws cloudformation describe-stacks --stack-name <stack> \
  --query 'Stacks[0].Outputs' --output table
```
Prod surfaces `ClientConfigProd` (the CLI config command), `CognitoUserPoolId`,
`CognitoM2MClientId`, plus `ProdDbEndpoint` / `BucketName` / `InstanceId`.

## Auth (Prod mode)

Prod authenticates with **AWS Cognito**. Cognito proves *who you are* — there's no
per-user RBAC, so every authenticated principal has full control-plane access
(Fine grained RBAC is feature of [Union](https://www.union.ai/)).

**Humans — CLI (PKCE):**
```bash
flyte create config --endpoint dns:///flyte.example.com:443 --auth-type pkce --project flytesnacks --domain development
flyte run hello.py main
```
The first call opens a browser for Cognito login, then caches the token.

**Browser — UI:** open `https://flyte.example.com/v2` → Cognito login → console.

**CI — M2M (no browser):**
```bash
DOMAIN=https://<stack>-<account>.auth.<region>.amazoncognito.com
TOK=$(curl -s -X POST "$DOMAIN/oauth2/token" \
  -u "$M2M_CLIENT_ID:$M2M_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=https://flyte.example.com/access" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
```
Pass it via `authType: ExternalCommand`, `command: [sh, -c, "echo $FLYTE_TOKEN"]`.
`CognitoM2MClientId` is a stack output; the secret is on that Cognito client.

**Manage users:** the pool starts empty —
```bash
aws cognito-idp admin-create-user --user-pool-id <CognitoUserPoolId> \
  --username you@example.com \
  --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true \
  --temporary-password '<TempPass#1>' --message-action SUPPRESS --region <region>
```

**How it works:** auth is enforced entirely at the **ALB** — no on-box proxy.
Listener rules validate against Cognito before forwarding to the devbox:
`authenticate-cognito` gives the browser console cookie SSO; a `jwt-validation`
rule validates the Cognito bearer on Bearer-carrying `flyteidl2.*` API calls
(CLI/CI); an unauthenticated discovery rule passes the OAuth metadata paths
through. The devbox serves those discovery RPCs **natively** (`runs.authMetadata`);
the **wake Lambda** also serves them, so the CLI can log in even while the box is
asleep. The box itself runs unauthenticated and is reachable only from the ALB.

## Cost (us-east-1, on-demand estimates)

Both modes **auto-stop the EC2** when idle, and Prod's Aurora **scales to zero**
(auto-pauses after ~5 min idle, resumes in ~15 s), so an idle stack costs almost
nothing for compute + DB.

EC2 is **`m6i.2xlarge`** by default (8 vCPU / 32 GB) @ **~$0.384/hr** when running —
~$68/mo at 8 h/day, ~$280/mo if left on 24×7. Shrink `InstanceType` (e.g.
`m6i.xlarge`) to halve active-hour cost if the workload fits.

| | Dev mode | Prod mode |
|---|---|---|
| **Idle** (EC2 stopped) | EIP + EBS ≈ **~$10/mo** | ALB ~$20 + EBS/EIP ~$13 + Aurora ~$0 (paused) ≈ **~$35/mo** |
| **+ Active compute** | + EC2 hours @ $0.384/hr | + EC2 hours @ $0.384/hr + Aurora ACUs while querying (~$0.06–0.24/hr) |

So a lightly-used Prod stack lands around **$50–80/mo**; Dev, **$10–40/mo**. The
fixed costs are the ALB (~$20/mo, inherent to HTTPS/domain) and public IPv4
addresses (~$3.60/mo each). No NAT gateways (public subnets only).

## Auto-stop / wake

- **Run a workflow** → idle metric stays at 0. **Stop everything** → it ticks up
  1/min. At `IdleThresholdMinutes` → alarm → stop Lambda → listener flips to the
  wake target → EC2 stops (Prod), Aurora pauses.
- **Prod:** the next request hits the wake Lambda, which authenticates (browser via
  Cognito, or CLI via discovery + bearer), starts the EC2 (~2 min boot, devbox
  already in the Docker volume — no re-pull), then flips traffic back. Set
  `AutoStop=No` for an always-on box.
- **Dev:** no ALB/wake path — restart with `aws ec2 start-instances --instance-ids <id>`.

## Tear down

```bash
aws cloudformation delete-stack --stack-name <stack>
```
The **S3 bucket**, **EBS data volume**, and **Aurora cluster** are `Retain` /
`Snapshot` on delete — remove leftover snapshots/buckets manually once the stack is
gone. (Running two stacks? Each has its own EC2 + EIP + EBS; Prod adds ALB +
Aurora. Delete the one you don't need to stop paying for it.)

## Building & development

The runtime is baked into an AMI by Packer; `packer/files/` is the single source
of truth for the on-box scripts + systemd units, and the CloudFormation user-data
only does per-instance wiring.

```bash
scripts/validate.sh                      # static gate (cfn-lint, packer, shellcheck,
                                         #   py-compile, user-data size)
cd packer && packer build .              # build a new AMI (needs AWS creds)
scripts/dev-sync.sh <stack> idle-agent.py     # hot-patch a baked file on a running
                                         #   box + restart its service (no rebuild)
scripts/smoke-test.sh                    # deploy → flyte run → teardown (real AWS spend)
```

- CI: `.buildkite/pipeline.yml` runs `validate.sh` on every commit. On `main` (incl.
  a scheduled build) it detects a new devbox release and builds → smoke-tests →
  publishes the AMI to SSM `/flyte-devbox/ami/latest` — no per-AMI code change.
- Releasing to AWS Marketplace: see [MARKETPLACE.md](MARKETPLACE.md).

## What's intentionally _not_ here

- **Per-user RBAC** — Cognito authenticates; it doesn't authorize per user (Union).
- **Multi-region AMIs** — the SSM AMI parameter is currently seeded for `us-east-1`;
  add regions on release (`aws ec2 copy-image` + publish each region's SSM param,
  see MARKETPLACE.md).
