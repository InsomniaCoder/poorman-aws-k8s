# poorman-k8s

> Kubernetes on AWS for the price of a Netflix subscription.

Run a real Kubernetes cluster on AWS for **~$24–32/mo** — roughly 90% cheaper than a standard EKS stack — by combining K3S, Graviton SPOT instances, and open-source alternatives to expensive managed services.

No EKS control plane fee. No NAT Gateway. No Network Load Balancer.

> **This is a personal cluster that accepts downtime.** All compute runs on AWS SPOT instances — AWS can reclaim them at any time. Recovery is automatic (typically 1–2 minutes) but not instant. See [Downtime risks and expected recovery times](#downtime-risks-and-expected-recovery-times) for the full breakdown. If you need higher availability, switch to on-demand instances — no other changes are required.

---

## Philosophy

Every line item on a typical EKS bill has a cheaper open-source substitute — the goal is to substitute all of them without sacrificing a working Kubernetes cluster:

- **K3S instead of EKS** — K3S is a fully conformant, single-binary Kubernetes distribution. The control plane runs as a process on an EC2 instance you already pay for, so there is no $72/mo managed control plane fee on top of your compute costs.
- **Graviton SPOT instead of x86 on-demand** — ARM64 instances are 20–30% cheaper than equivalent x86, and SPOT pricing is 60–70% off on-demand. The ASG replaces interrupted instances automatically.
- **[fck-NAT](https://github.com/AndrewGuenther/fck-nat) instead of NAT Gateway** — a t4g.nano SPOT instance running NAT masquerade costs ~$3/mo vs $33/mo for a managed NAT Gateway.
- **ServiceLB instead of NLB** — K3S ships with a built-in load balancer (klipper-lb) that claims HostPort 80/443 directly on the node. Combined with an Elastic IP, no Network Load Balancer is needed.

## Cost

| Component | poorman-k8s | Full EKS stack |
| --- | --- | --- |
| Control plane | $0 (bundled with server EC2) | $72/mo (managed EKS fee) |
| Server / master compute | ~$12–18/mo (m7g.large SPOT) | $140–200/mo (2× m5.large on-demand) |
| Worker compute | ~$3–5/mo (t4g.small SPOT) | $70–100/mo (m5.large on-demand per node) |
| NAT | ~$3/mo (fck-NAT t4g.nano) | ~$33/mo (Managed NAT Gateway) |
| Load balancer | $0 (ServiceLB HostPort) | ~$16–32/mo (NLB) |
| EBS volumes | ~$6.40/mo (2× 30 GB + 1× 20 GB gp3) | ~$8/mo |
| EIP × 2 | $0 (free when attached) | $0 |
| Terraform state (S3) | ~$0.02/mo | ~$0.02/mo |
| **Total** | **~$24–32/mo** | **~$340–445/mo** |
| **Savings** | **~90–93%** | — |

> EKS comparison assumes: 1× EKS cluster, 1× m5.large on-demand master + 2× m5.large on-demand workers, 1× NAT Gateway, 1× NLB, no savings plans applied.

---

## Architecture

```text
AWS eu-south-2 (single AZ — eu-south-2a)

VPC 10.0.0.0/16
├── Public subnet  10.0.1.0/24
│   ├── K3S server   m7g.large SPOT   EIP ──► :80/:443 (Traefik ingress)
│   └── fck-NAT      t4g.nano  SPOT   EIP ──► outbound NAT for private subnet
└── Private subnet 10.0.2.0/24
    └── K3S worker   t4g.small SPOT        ──► egress via fck-NAT

Ingress traffic path:
  DNS A record → EIP → EC2 :80/:443
    → ServiceLB (klipper-lb iptables DNAT)
      → Traefik ingress controller
        → your pods
```

**Key design decisions:**

- **Single AZ** — eliminates cross-AZ data transfer costs and simplifies the EBS attachment model for K3S state persistence.
- **Graviton (ARM64) only** — t4g/m7g instances are 20–30% cheaper than equivalent x86. Fallback chain: `m7g.large → m6g.large → t4g.large → t4g.medium`.
- **m7g.large for the server** — the server node runs the K3S control plane, Traefik ingress controller, and cert-manager. Workloads run on worker nodes. 8 GB RAM and non-burstable CPU avoids throttling under sustained load.
- **SPOT with 1:1 ASG** — on interruption the ASG launches a replacement; server user-data re-attaches the EBS data volume (preserving all K3S state) and re-associates the EIP; worker user-data reads SSM to rejoin the cluster. fck-NAT also runs behind an ASG (`ha_mode = true`) so NAT recovers automatically without manual intervention.
- **SSM Parameter Store** — server writes K3S token and private IP to SSM after install; worker reads them at boot. No manual secret passing. Workers are in the private subnet — they need fck-NAT running to reach SSM during boot. If both are replaced simultaneously, fck-NAT recovers first (~45s) and the worker retries SSM for up to 5 minutes, so the sequence resolves on its own.
- **`--advertise-address` on the server** — k3s is started with `--advertise-address=$PRIVATE_IP`. Without this, `--node-external-ip` causes k3s to register the EIP as the `kubernetes` service endpoint; pods on the server trying to reach `10.43.0.1` (ClusterIP) get DNAT'd to the EIP, which AWS drops on hairpin. Advertising the private IP keeps all in-cluster API traffic inside the VPC.
- **SG-reference inter-node model** — the server and worker security groups grant each other full bidirectional access using SG-reference rules (not CIDR+port enumeration). The meaningful security boundary is the internet edge. Server↔worker is a trusted cluster-internal zone — enumerating ports would add operational friction with no real security benefit, and would require a Terraform change every time Kubernetes opens a new port internally.
- **No NLB** — K3S's built-in ServiceLB claims HostPort 80/443 on the node. The EIP points directly to the instance. cert-manager handles TLS via Let's Encrypt.
- **S3 native state locking** — Terraform 1.10+ `use_lockfile = true` replaces DynamoDB for state locking.
- **Packer AMI** — K3S binary and install script are pre-baked into a custom AMI. Boot time drops from ~3–5 min (downloading ~60 MB from GitHub on every launch) to ~45–90 sec. See [Packer AMI](#packer-ami) below.

---

## Design principles

- **Graviton first and only** — no x86-64 instances anywhere in the stack
- **SPOT first** — all compute uses SPOT; fallback chain stays within the same ARM64 architecture
- **Single AZ always** — no multi-AZ resources
- **Logic in `.tf`, not `.hcl`** — Terragrunt `.hcl` files are thin wrappers (inputs + include only); all infrastructure logic lives in Terraform modules
- **S3 native locking** — `use_lockfile = true`, no DynamoDB

---

## Project structure

```text
poorman-k8s/
├── root.hcl                          # Terragrunt root: remote_state + provider generate
├── packer/
│   └── k3s.pkr.hcl                   # Packer template — builds the custom K3S AMI
├── modules/
│   ├── bootstrap/                    # S3 state bucket (bootstrapped once, local backend)
│   ├── vpc/                          # VPC, subnets, IGW, route tables, S3 Gateway endpoint
│   ├── fck-nat/                      # fck-NAT instance (replaces NAT Gateway)
│   ├── k3s-node/                     # K3S server: ASG, EBS data volume, EIP, SSM writes
│   └── k3s-worker/                   # K3S worker: ASG in private subnet, SSM-based join
├── cluster-applications/             # ArgoCD App of Apps — synced by ArgoCD after bootstrap
│   ├── traefik/
│   ├── cert-manager/
│   ├── external-dns/
│   └── monitoring/
├── scripts/
│   ├── bootstrap-argocd.sh           # One-shot ArgoCD install + App of Apps bootstrap
│   └── argocd/                       # Manifests used by bootstrap script
│       ├── namespaces.yaml
│       ├── argocd-values.yaml
│       └── cluster-apps.yaml
└── live/
    └── eu-south-2/
        ├── env.hcl                   # region, az, project_name, domain_name, repo_url
        ├── bootstrap/terragrunt.hcl
        ├── vpc/terragrunt.hcl
        ├── fck-nat/terragrunt.hcl
        ├── k3s-node/terragrunt.hcl
        └── k3s-worker/terragrunt.hcl # after_hook runs bootstrap-argocd.sh on apply
```

---

## Prerequisites

- **AWS CLI** — configured and authenticated (`aws sts get-caller-identity` works)
- **Terraform ≥ 1.10** — for S3 native state locking (`terraform version`)
- **Terragrunt v1** — (`terragrunt --version`)
- **Packer** — for building the custom AMI (`brew install packer`)
- **kubectl** — for cluster access after deploy
- **helm** — used by `scripts/bootstrap-argocd.sh` to install ArgoCD (`brew install helm`)
- **Session Manager plugin** — for SSM-based shell access; install from the [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- **A domain with Cloudflare DNS** — required for cluster applications (ArgoCD, Grafana). Register a domain at [Cloudflare](https://www.cloudflare.com/products/registrar/) or any registrar and point its nameservers at Cloudflare. Free plan is sufficient.

---

## First-time deploy

The first deploy is split into two `apply` calls because VPC must exist before Packer can build the AMI.

### 1. Configure AWS credentials

```bash
export AWS_PROFILE=your-profile-name
aws sts get-caller-identity   # verify it works
```

### 2. Edit env.hcl

`live/eu-south-2/env.hcl` is the single file you need to edit before deploying:

```hcl
locals {
  region       = "eu-south-2"   # AWS region
  az           = "eu-south-2a"  # Single AZ — must match region
  project_name = "poorman-k8s"  # Prefix for S3 bucket, AMI, kubeconfig filename
}
```

`domain_name` and `repo_url` are read from environment variables (`DOMAIN_NAME`, `REPO_URL`) — set them in your `.env` file (see step 3). This keeps personal values out of git.

If you change `region`, also rename `live/eu-south-2/` to match and update the `source` paths in each `terragrunt.hcl`. Not all regions have Graviton SPOT capacity — check availability before switching.

### 3. Export required environment variables

These are never committed to git. Add them to your shell profile (`.zshrc` / `.bashrc`) so they persist across sessions:

```bash
# Your current IP — controls who can reach kubectl (port 6443)
export TF_VAR_ADMIN_CIDR="$(curl -s https://checkip.amazonaws.com)/32"

# Your Cloudflare-managed domain (used by ExternalDNS and cert-manager)
export DOMAIN_NAME="yourdomain.com"

# HTTPS URL of your fork — ArgoCD uses this for the App of Apps
export REPO_URL="https://github.com/your-org/your-fork"

# Used by scripts/bootstrap-argocd.sh after the cluster is up
export KUBECONFIG=~/.kube/poorman-k8s.yaml

# Cloudflare API token — cert-manager DNS-01 + ExternalDNS
# Create at: Cloudflare Dashboard → My Profile → API Tokens → Create Token
# Permission needed: Zone → DNS → Edit (scoped to your domain)
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"

# Git token — ArgoCD uses this to clone your repo.
# Required for private repos. Omit for public GitHub.com forks.
export GITHUB_TOKEN="your-git-token"
```

### 4. Create the S3 state bucket

Run once — all subsequent applies use this bucket for remote state.

```bash
cd live/eu-south-2/bootstrap && terragrunt apply
```

### 5. Create the VPC

```bash
cd live/eu-south-2/vpc && terragrunt apply
```

### 6. Build the Packer AMI

```bash
SUBNET_ID=$(cd live/eu-south-2/vpc && terragrunt output -raw public_subnet_id)
cd packer && packer init . && packer build -var "subnet_id=$SUBNET_ID" k3s.pkr.hcl
```

Packer launches a `t4g.small`, bakes K3S into an AMI (`poorman-k8s-k3s-*`), and terminates the instance. Takes ~7–10 minutes.

### 7. Deploy the core stack

```bash
cd live/eu-south-2 && terragrunt run --all apply
```

Deploys in order: `fck-nat → k3s-node → k3s-worker`. The VPC is already applied and skipped.

After `k3s-worker` apply succeeds, a Terragrunt `after_hook` automatically runs `scripts/bootstrap-argocd.sh`. On a **first deploy** `KUBECONFIG` doesn't exist yet so the hook skips gracefully — continue to step 8. On **re-runs** with `KUBECONFIG` already set, ArgoCD bootstrap runs automatically and you can skip steps 8–9.

### 8. Copy kubeconfig

```bash
EIP=$(cd live/eu-south-2/k3s-node && terragrunt output -raw k3s_eip)
INSTANCE_ID=$(aws ec2 describe-instances --region eu-south-2 \
  --filters "Name=tag:Name,Values=poorman-k8s-k3s" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text)

CMD_ID=$(aws ssm send-command --region eu-south-2 \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["sudo cat /etc/rancher/k3s/k3s.yaml"]}' \
  --query 'Command.CommandId' --output text)

sleep 5   # wait for the command to complete

aws ssm get-command-invocation --region eu-south-2 \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text \
  | sed "s/127.0.0.1/$EIP/" > ~/.kube/poorman-k8s.yaml

export KUBECONFIG=~/.kube/poorman-k8s.yaml
kubectl get nodes
```

The kubeconfig filename (`poorman-k8s.yaml`) matches `project_name` in `env.hcl`. If you changed it, update the filename accordingly.

### 9. Bootstrap ArgoCD and cluster applications

```bash
./scripts/bootstrap-argocd.sh
```

Installs ArgoCD via Helm, pre-creates the Cloudflare token Secrets in `cert-manager` and `external-dns` namespaces, and bootstraps the App of Apps pointing at `cluster-applications/`. ArgoCD then syncs Traefik, cert-manager, ExternalDNS, and Prometheus/Grafana automatically.

The script is fully idempotent — safe to re-run at any time. It reads `domain_name` and `repo_url` directly from `live/eu-south-2/env.hcl`, so no extra env vars are needed beyond `KUBECONFIG`, `CLOUDFLARE_API_TOKEN`, and (for private repos) `GITHUB_TOKEN`.

**Wait for DNS and TLS (~5 minutes):**

Once ExternalDNS is healthy it creates A records in Cloudflare for all Ingress hostnames. cert-manager issues Let's Encrypt certificates via DNS-01 challenge. When complete:

- `https://argocd.<your-domain>` — ArgoCD UI (login: `admin` / password from `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d`)
- `https://grafana.<your-domain>` — Grafana (login: `admin` / `prom-operator`)

---

## Subsequent deploys

```bash
cd live/eu-south-2 && terragrunt run --all apply
```

The `after_hook` on `k3s-worker` runs `scripts/bootstrap-argocd.sh` automatically on every successful apply — Helm, secrets, and the App of Apps all reconcile idempotently. No separate step needed.

**To upgrade K3S:** update `k3s_version` in `packer/k3s.pkr.hcl`, rebuild the AMI (`packer build ...`), run `terragrunt run --all apply`, then cycle both instances so the ASG replaces them with the new AMI.

---

## Access the cluster

Instances have no SSH key pair. Access is via **AWS SSM Session Manager** only — the IAM role on both nodes includes `AmazonSSMManagedInstanceCore`.

> Allow ~1–2 minutes after first boot for the SSM agent to register. If you get `TargetNotConnected`, wait and retry.

### Get instance ID and EIP (run once, reuse below)

Commands below use the default `project_name = "poorman-k8s"`. If you changed `project_name` in `env.hcl`, replace `poorman-k8s` with your value in the tag filter and kubeconfig filename.

```bash
INSTANCE_ID=$(aws ec2 describe-instances --region eu-south-2 \
  --filters "Name=tag:Name,Values=poorman-k8s-k3s" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text)

EIP=$(cd live/eu-south-2/k3s-node && terragrunt output -raw k3s_eip)
```

### Copy kubeconfig

```bash
CMD_ID=$(aws ssm send-command --region eu-south-2 \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["sudo cat /etc/rancher/k3s/k3s.yaml"]}' \
  --query 'Command.CommandId' --output text)

sleep 5   # wait for the command to complete

aws ssm get-command-invocation --region eu-south-2 \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text \
  | sed "s/127.0.0.1/$EIP/" > ~/.kube/poorman-k8s.yaml

export KUBECONFIG=~/.kube/poorman-k8s.yaml
kubectl get nodes
# NAME            STATUS   ROLES                  AGE   VERSION
# ip-10-0-1-x     Ready    control-plane,master   2m    v1.x.x+k3s1
# ip-10-0-2-x     Ready    <none>                 1m    v1.x.x+k3s1
```

The worker node joins automatically via SSM — no manual token passing required. Allow ~2–3 minutes for both nodes to appear `Ready`.

---

## What's included

After deploy, the cluster runs:

| Component | How it's installed |
| --- | --- |
| Traefik ingress controller | ArgoCD (Helm, `cluster-applications/traefik/`) |
| cert-manager + ClusterIssuer | ArgoCD (Helm, `cluster-applications/cert-manager/`) |
| ExternalDNS | ArgoCD (Helm, `cluster-applications/external-dns/`) |
| Prometheus + Grafana | ArgoCD (Helm, `cluster-applications/monitoring/`) |
| node-reaper CronJob | ArgoCD (`cluster-applications/node-reaper/`) |
| ArgoCD | `scripts/bootstrap-argocd.sh` (one-shot, idempotent) |
| CoreDNS | K3S default |
| metrics-server | K3S default |
| ServiceLB (klipper-lb) | K3S default |

---

## Downtime risks and expected recovery times

All compute runs on SPOT. AWS can reclaim any instance at any time. Recovery is automatic — no manual intervention required — but not instant.

| Scenario | What breaks | Expected recovery |
|----------|------------|-------------------|
| Server SPOT interruption | API server, ArgoCD, Traefik, HTTP/HTTPS ingress | ~1–2 min |
| Worker SPOT interruption | Workload pods on that node | ~1 min |
| fck-NAT SPOT interruption | Worker egress (image pulls, SSM) | ~45–90 sec |
| Server + fck-NAT simultaneous | Full cluster + worker egress | ~2–3 min (auto-resolves) |
| All three simultaneously | Full cluster outage | ~2–3 min |

**How recovery works:**

- **Server:** ASG replaces the instance → user-data re-attaches the EBS data volume (etcd, certs, kubeconfig all preserved), re-associates the EIP, restarts K3S, republishes token and private IP to SSM.
- **Worker:** ASG replaces the instance → user-data reads K3S token and server IP from SSM, rejoins the cluster. Requires fck-NAT to be up; if both are interrupted simultaneously, fck-NAT recovers first (~45s) and the worker retries SSM for up to 5 minutes.
- **fck-NAT:** ASG (`ha_mode = true`) re-attaches the static ENI. The private route table already points at the ENI ID, not the instance — no Terraform apply needed.

The EBS data volume has `prevent_destroy = true` — it will never be deleted by `terraform destroy` unless you explicitly remove the lifecycle guard first.

**To eliminate SPOT downtime risk:** change `on_demand_percentage_above_base_capacity` to `100` in the k3s-node and k3s-worker launch templates. No other changes required. Cost increases to ~$120–160/mo.

For full architecture details, traffic flows, and security group model, see [`CLAUDE.md`](CLAUDE.md).

---

## Packer AMI

Without a custom AMI, every SPOT replacement downloads the K3S binary (~60 MB) and install script from GitHub on each boot. Over NAT or IGW this takes 2–4 minutes before K3S even starts. On a busy day with multiple interruptions this compounds quickly.

The Packer AMI bakes in:

- `/usr/local/bin/k3s` — the K3S binary for the pinned version
- `/usr/local/share/k3s-install.sh` — the official install script

At boot, user-data runs `INSTALL_K3S_SKIP_DOWNLOAD=true sh /usr/local/share/k3s-install.sh` — which just sets up the systemd service and starts it. No network download. Boot time drops to ~45–90 sec.

Nothing cluster-specific is baked into the AMI — tokens, IPs, and EIP associations all happen at runtime via user-data. The same AMI is used for both the server node and worker.

To upgrade K3S: update `k3s_version` in `packer/k3s.pkr.hcl`, rebuild, and cycle instances.

---

## Adding more worker nodes

The worker ASG runs 1 node by default (`desired_capacity = 1`) with a ceiling of 3 (`max_size = 3`). To scale up manually, increase `desired_capacity` in the `k3s-worker` terragrunt inputs. To raise the ceiling, override `max_size`.

Worker nodes communicate with the K3S server over the private IP (free, no NAT needed). The K3S token and server IP are automatically read from SSM — no manual configuration required.

---

## Node reaper

K3S does not delete node objects when SPOT instances are terminated — the old node lingers as `NotReady` in `kubectl get nodes` until manually removed. Left unattended, stale entries accumulate and can confuse schedulers and monitoring dashboards.

`cluster-applications/node-reaper/` deploys a CronJob in `kube-system` that runs every 5 minutes on the control-plane node. It deletes any node that has been `NotReady` for more than 2 minutes. This is conservative enough to ignore transient blips but fast enough to clean up after a real SPOT interruption.

---

## Using a different DNS provider

The cluster applications stack is wired for **Cloudflare** in three places. If you use Route 53, Azure DNS, or any other provider, you need to change all three:

**1. cert-manager ClusterIssuer** (`cluster-applications/cert-manager/application.yaml`)

The `extraObjects` section defines a `ClusterIssuer` with a `dns01.cloudflare` solver:

```yaml
solvers:
  - dns01:
      cloudflare:
        apiTokenSecretRef:
          name: cloudflare-api-token
          key: api-token
```

Replace with your provider's solver. For Route 53:

```yaml
solvers:
  - dns01:
      route53:
        region: eu-south-2
        hostedZoneID: YOUR_ZONE_ID
```

cert-manager's solver reference: [cert-manager.io/docs/configuration/acme/dns01](https://cert-manager.io/docs/configuration/acme/dns01/)

**2. ExternalDNS** (`cluster-applications/external-dns/application.yaml`)

Change `provider.name` and update the credential `env` var:

```yaml
provider:
  name: aws   # or azure, google, etc.
env: []       # remove CF_API_TOKEN; add provider-specific vars
```

ExternalDNS provider reference: [github.com/kubernetes-sigs/external-dns](https://github.com/kubernetes-sigs/external-dns#status-of-providers)

**3. Bootstrap script secrets** (`scripts/bootstrap-argocd.sh`)

The script creates `cloudflare-api-token` Secrets in both `cert-manager` and `external-dns` namespaces. If your provider needs different credentials, update the `kubectl create secret` calls in the script accordingly.

---

## Why not VPC interface endpoints?

The S3 Gateway endpoint is included (free — routes all EC2↔S3 traffic over the AWS backbone).

Interface endpoints for ECR, SSM, EC2 API, etc. each cost **~$7–10/mo per AZ**. At this scale, the bandwidth savings are far smaller than the endpoint cost. The break-even point is roughly 150–200 GB/mo of ECR traffic per endpoint.

---

## Contributing

Contributions welcome. The project follows these principles (see `CLAUDE.md`):

- Graviton (ARM64) only — no x86-64 instances
- SPOT first, single AZ
- Logic in `.tf` modules, not `.hcl` wrappers
- Cost table in `CLAUDE.md` must be updated when any cost-affecting change is made

Open an issue or PR. Please include cost impact analysis for any change that affects the bill.

---

## License

MIT
