# Running a Real Kubernetes Cluster on AWS for ~$30/mo

At work, I run Kubernetes at scale on AWS. EKS, proper multi-AZ setups, the full managed stack. That's the right choice when reliability matters and the cost is shared across a team and a product.

But when I have this personal side project starting, and I wanted to host it properly — with a real deployment pipeline, automatic TLS, DNS automation, monitoring — the moment I price out EKS for a single-person hobby project, the numbers stop making sense.

I wasn't willing to move to a different cloud provider just to save money to the absolute. since I know AWS networking, and the environment around it. More importantly, I wanted to keep using the same workflow I use professionally: Terragrunt for infrastructure, ArgoCD for GitOps, the whole stack. Starting over on other cloud means context-switching which I don't need at this point.

So I built poorman-k8s: a K3S cluster on AWS that gets you everything you'd want from EKS — GitOps, TLS, DNS automation, monitoring — for around $24–32/mo. A standard EKS setup for the same workload would cost $340–445/mo.

This post walks through how that's possible, what trade-offs it requires, and why I think the approach hits a sweet spot for for me without a real AWS bill.

---

## The Problem: What Does a Standard EKS Stack Actually Cost?

Before getting into the solution, it's worth itemizing why EKS gets expensive so fast. The costs aren't hidden — they're just scattered across enough line items that they're easy to underestimate.

**The EKS control plane fee** is $0.10/hr, which works out to ~$72/mo. That's before a single pod runs. It's the fee for Amazon managing the control plane for you — the API server, etcd, upgrades. Completely reasonable for production, but a significant fixed cost when you're running a side project that gets maybe a few hundred requests a day.

**Compute** is the next big one. EKS officially recommends `m5.large` (or equivalent) for worker nodes, and the conventional wisdom is to run at least two for availability. An `m5.large` on-demand is around $70–100/mo per node. For two workers you're at $140–200/mo — before the EKS fee.

**NAT Gateway** gets overlooked until you see the bill. If your worker nodes are in a private subnet (which is the standard security recommendation), they need a NAT Gateway to reach the internet. AWS charges $32/mo base plus $0.045/GB data processed. For a typical side project you're looking at $33–40/mo just for NAT.

**Network Load Balancer** is needed if you want external traffic to reach your services. An NLB runs $16–32/mo.

Add it up and a conservative EKS stack is around $340–445/mo. For context, that's more than most people pay for their entire AWS bill on a hobby account.

---

## Why Not Just Use Hetzner?

Hetzner can get you a Kubernetes-capable server for €5–10/mo — legitimately cheaper than $30. But staying on AWS means keeping the things that I'm familiar with without context switching and some things are still very useful such as

**SSM Session Manager** — no SSH keys, no key rotation, no exposed port 22. Access through IAM, which is genuinely better ops hygiene than traditional SSH.

**IAM roles** — instances get instance profiles. K3S workers use their IAM role to read the join token from SSM Parameter Store at boot. Zero secrets on disk.

**S3 for Terraform state** — native locking since Terraform 1.10, no DynamoDB needed.

---

## Why Not EKS for a Personal Project?

EKS is excellent for production. Managed control plane, automated upgrades, deep IAM integration, node group management. If I was running this for a company with reliability requirements, I'd be on EKS without doubt.

For a personal project, the managed control plane fee is a cost I don't want to pay, because K3S exists.

[K3S](https://k3s.io/) is a fully CNCF-conformant Kubernetes distribution packaged as a single binary. It runs the API server, scheduler, controller manager, and etcd (or SQLite for small clusters) in a single process. You get real Kubernetes — the same `kubectl`, the same manifest format, the same CRDs and operators — without a separate managed control plane.

The trade-off is that the control plane is now my problem. If K3S breaks, I debug it. That's an acceptable risk at this scale — the cluster is one server, one worker, and "managing the control plane" mostly means nothing in practice. The main failure mode is SPOT interruption, which is handled automatically via ASG replacement and EBS re-attach. For anything else, the blast radius is small enough that I'd rather save $72/mo and fix it myself.

---

## The Stack at a Glance

The full topology is a single VPC in AWS eu-south-2, split into a public and private subnet:

```
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

Key components:

- **K3S** on two Graviton SPOT EC2 instances — one server (control plane + system pods), one worker (application workloads)
- **fck-NAT** — a t4g.nano running NAT masquerade, replacing the NAT Gateway
- **ServiceLB** — K3S's built-in load balancer, claiming HostPort 80/443 directly on the server node, backed by an Elastic IP instead of an NLB
- **ArgoCD** for GitOps — the cluster continuously syncs from the repo
- **Traefik** for ingress, **cert-manager** for TLS, **ExternalDNS** for automatic Cloudflare DNS records, **Prometheus + Grafana** for monitoring

Infrastructure is managed with Terraform and Terragrunt. AMIs are built with Packer so that SPOT replacements boot in 45–90 seconds instead of 3–5 minutes.

---

## Why Graviton (ARM64)?

Simple: Graviton instances are 20–30% cheaper than equivalent x86-64 instances. All the major Kubernetes ecosystem images — Traefik, cert-manager, ExternalDNS, Prometheus, Grafana, ArgoCD, K3S itself — have ARM64 variants, so there's no real compatibility cost.

The SPOT fallback chain for the server is `m7g.large → m6g.large → t4g.large → t4g.medium`, all Graviton. The `m7g.large` is the default because the server runs the API server, ArgoCD, and Traefik simultaneously — memory-hungry enough that a burstable `t4g` risks CPU throttle when credits run out.

---

## SPOT Instances + Auto Scaling Groups

SPOT instances are AWS's way of selling excess capacity. The discount is 60–70% off on-demand pricing. The catch is that AWS can reclaim the instance with a 2-minute warning when they need the capacity back.

For a production cluster, that's a real concern. For a side project, it's a reasonable trade. The key is making the recovery automatic so you don't have to intervene when it happens.

Every compute node in this stack runs behind an Auto Scaling Group with `desired_capacity = 1` and `min_size = 1`. When AWS terminates a SPOT instance, the ASG launches a replacement within 30–60 seconds.

But a replacement instance needs to come back as the *same* server, not a blank one. That's what the user-data scripts handle:

**Server recovery:** The ASG launches a new instance using the same launch template. The user-data script:
1. Re-attaches the EBS data volume (`/var/lib/rancher/k3s/`) — this is where etcd, certificates, and the kubeconfig live. All K3S state is preserved.
2. Re-associates the Elastic IP — same public IP, so DNS records don't need to change.
3. Starts K3S with `--advertise-address=$PRIVATE_IP` (important — more on this in the security section).
4. Writes the K3S token and private IP back to SSM Parameter Store.

Total time from SPOT interruption to API server available: ~1–2 minutes.

**Worker recovery:** The ASG launches a new instance. The user-data script reads the K3S join token and server private IP from SSM Parameter Store and runs the K3S agent join command. Total time: ~1 minute.

**The EBS volume has `prevent_destroy = true`.** This means `terraform destroy` will not delete it unless you explicitly remove that lifecycle guard first. K3S state survives everything — SPOT interruptions, Terraform applies, even a full destroy-and-redeploy of the rest of the stack.

One optimization that cuts recovery time significantly: a custom Packer AMI with the K3S binary pre-baked in. Without this, every boot downloads ~60 MB from GitHub. Over NAT, on a busy day with multiple interruptions, that adds up. With the Packer AMI, `user-data` runs `INSTALL_K3S_SKIP_DOWNLOAD=true` and just configures the systemd service. Boot time drops from 3–5 minutes to 45–90 seconds.

Having Packer in the pipeline also opens up further optimizations down the road — pre-pulling container images, baking in CNI plugins, or pre-configuring systemd units. The groundwork is already there; shaving more seconds off boot time is just a matter of adding steps to the build.

One thing that could reduce recovery time further is using ASG warm pools — keeping a pre-initialized on-demand instance ready to swap in immediately on interruption. In practice that adds cost and complexity that doesn't fit the ethos of this project. The cluster is ephemeral by design: when a SPOT instance is reclaimed, the ASG spins up a fresh replacement, state re-attaches from EBS, and everything is back in 1–2 minutes. That's a trade I'm comfortable with.

---

## Why fck-NAT Instead of NAT Gateway?

NAT Gateway is AWS's managed NAT service. It works well and requires zero maintenance. It also costs $32/mo base, plus $0.045 per GB processed. For a personal project running in a single AZ, that's an additional cost.

[fck-NAT](https://github.com/AndrewGuenther/fck-nat) (the name is accurate) is a community project that runs NAT masquerade on a `t4g.nano` EC2 instance. You configure your private route table to point at the ENI of the fck-NAT instance, and it forwards traffic to the internet gateway on behalf of private-subnet instances.

Cost: ~$3/mo. Savings over managed NAT Gateway: ~$30/mo.

The obvious concern is reliability. The fck-NAT instance is also SPOT. If AWS reclaims it, private-subnet worker nodes lose internet access — which means they can't pull container images, can't reach SSM, can't make external API calls.

The mitigation is `ha_mode = true` in the fck-NAT module. This runs fck-NAT behind its own ASG. When the instance is replaced, it re-attaches a static ENI that was created alongside the instance. The private route table in the VPC points at the ENI ID (not the instance ID), so the route survives the instance replacement. No Terraform apply needed. Recovery time: ~45–90 seconds.

The failure scenario I thought hardest about: what if fck-NAT and the K3S server are both terminated simultaneously? The worker needs fck-NAT to reach SSM to rejoin the cluster. The answer is that fck-NAT recovers faster (~45 seconds) than the server (~90 seconds), and the worker's user-data retries SSM for up to 5 minutes. The sequence resolves automatically without intervention.

---

## Public/Private Subnet Separation

The server node is in the public subnet (it needs an Elastic IP for inbound HTTP/HTTPS traffic). The worker node is in the private subnet (no public IP, egress via fck-NAT).

The security benefit is straightforward: the worker has no internet-facing attack surface. Port scanners scanning your IP range can't reach it. It doesn't have a public IP. The only way to reach the worker is through the VPC, which means through the server (which controls what traffic reaches it).

There's a subtlety in how the server is configured: K3S is started with `--advertise-address=$PRIVATE_IP`. This matters because of how AWS handles traffic to Elastic IPs.

Without this flag, K3S registers the EIP as the `kubernetes` service endpoint. When pods on the server node make API calls to `10.43.0.1` (the Kubernetes ClusterIP for the API server), the VPC DNAT's that to the real endpoint — which is the EIP. AWS drops that traffic because it's a hairpin: a packet going from an instance to its own EIP. This causes mysterious API call failures from system pods running on the server node.

With `--advertise-address=$PRIVATE_IP`, K3S registers the private IP as the endpoint. All in-cluster API traffic stays inside the VPC. No hairpin, no dropped packets, no extra hop through the internet gateway.

Worker-to-server communication also uses the private IP — workers read the server's private IP from SSM at boot and connect to `https://<private_ip>:6443`. The K3S join traffic never leaves the VPC.

---

## Security Model

This isn't production security, but it's not negligent either.

**Internet edge** — the only ports open to `0.0.0.0/0` are 80/443. the K3S API (port 6443) are locked to a specific admin CIDR. Everything else is blocked at the security group level. Workers have no internet-facing ports at all.

**Inter-node traffic** — the server and worker security groups grant each other full bidirectional access (all ports, all protocols) using SG-reference rules: the server SG allows all traffic from the worker SG, and vice versa. This might look permissive, but consider the threat model: if either node is compromised, the attacker has the K3S join token (stored on both nodes). That token gives full cluster admin access. Restricting which internal ports they can use adds friction with no real security benefit. The SG-reference model also means new Kubernetes internals that open additional ports don't require a Terraform change.

**No SSH keys anywhere.** Access is through AWS SSM Session Manager, authenticated via IAM. No keys to rotate, no keys to leak, no port 22 exposed to the world. This is one of the real benefits of staying on AWS — SSM Session Manager is genuinely better than SSH for ops access.

**State persistence** — the `prevent_destroy = true` lifecycle guard on the EBS data volume means K3S state can never be accidentally deleted by Terraform. This is one of those small hygiene choices that prevents a bad day.

---

## GitOps with ArgoCD

Once the cluster is up, a bootstrap script installs ArgoCD via Helm and deploys an App of Apps pointing at the repo's `cluster-applications/` directory. After that, adding a new application to the cluster means adding a directory to the repo and pushing — ArgoCD picks it up automatically.

The cluster applications that run continuously:

| Component | Purpose |
| --- | --- |
| **Traefik** | Ingress controller — routes external HTTP/HTTPS to pods |
| **cert-manager** | Automatic TLS certificates via Let's Encrypt DNS-01 challenge |
| **ExternalDNS** | Watches Ingress resources, creates DNS A records automatically |
| **Prometheus + Grafana** | Cluster and application metrics |
| **node-reaper** | CronJob — cleans up stale NotReady node objects after SPOT interruptions |
| **ArgoCD** | GitOps controller (bootstrapped once, then self-managed) |

The **node-reaper** deserves a mention. K3S doesn't delete node objects when a SPOT instance is terminated — the old node lingers as `NotReady` in `kubectl get nodes` until manually removed. Stale node objects accumulate, confuse monitoring dashboards, and potentially affect scheduling decisions. The node-reaper is a CronJob that runs every 5 minutes on the control-plane node and deletes any node that has been `NotReady` for more than 2 minutes. Conservative enough to ignore transient blips, aggressive enough to clean up after real interruptions.

The Terragrunt `after_hook` on the `k3s-worker` module runs the ArgoCD bootstrap script automatically after every `terragrunt apply`. The script is idempotent — it's safe to re-run at any time.

**A note on DNS provider:** this repo is configured for Cloudflare because that's where my domain lives. But ExternalDNS supports most major DNS providers — Route 53, Google Cloud DNS, Azure DNS, and others. Swapping providers is a one-line change to the ExternalDNS Helm values; the rest of the stack doesn't care.

---

## The Cost Breakdown

Here's the full comparison. The EKS numbers assume 1 EKS cluster, 1 `m5.large` on-demand master plus 2 `m5.large` on-demand workers, 1 NAT Gateway, and 1 NLB. No savings plans.

| Component | poorman-k8s | Full EKS stack |
| --- | --- | --- |
| Control plane | $0 (K3S on EC2, no managed fee) | $72/mo (EKS control plane fee) |
| Server / master compute | ~$12–18/mo (m7g.large SPOT) | $140–200/mo (2× m5.large on-demand) |
| Worker compute | ~$3–5/mo (t4g.small SPOT) | $70–100/mo (m5.large on-demand) |
| NAT | ~$3/mo (fck-NAT t4g.nano) | ~$33/mo (Managed NAT Gateway) |
| Load balancer | $0 (ServiceLB HostPort) | ~$16–32/mo (NLB) |
| EBS volumes | ~$6.40/mo (2× 30 GB + 1× 20 GB gp3) | ~$8/mo |
| EIP × 2 | $0 (free when attached) | $0 |
| Terraform state (S3) | ~$0.02/mo | ~$0.02/mo |
| **Total** | **~$24–32/mo** | **~$340–445/mo** |
| **Savings** | **~90–93%** | — |

Each line item is a deliberate substitution:

- K3S replaces the EKS control plane fee entirely — the control plane runs as a process on an EC2 you already pay for.
- Graviton SPOT replaces x86 on-demand — 20–30% cheaper architecture, 60–70% off for SPOT pricing, multiplied together.
- fck-NAT replaces NAT Gateway — same function, $30/mo cheaper.
- ServiceLB + EIP replaces NLB — same external connectivity, no NLB hourly fee.

---

## Who Is This For?

To be clear about what this is: poorman-aws-k8s is an experimental, educational project. I built it to bootstrap my own side project on AWS without paying EKS prices. It is not production-ready, not battle-tested at scale, and not intended to be.

That said, it's useful if you're in a similar situation — you want to bootstrap something small on AWS, you already know the ecosystem, and you want a working GitOps setup without the $300+/mo bill.

Think of it as a starting point for learning or tinkering.

---

## What's Next

The one obvious missing piece is a cluster autoscaler — right now the worker ASG is fixed at one node, so there's no automatic scale-out when workload increases. Adding the Kubernetes Cluster Autoscaler pointing at the worker ASG would close that gap.

Beyond that, the foundation is intentionally clean. The GitOps pipeline is wired up, TLS and DNS are automated, monitoring is running. If you want to extend it — more workers, additional ingress rules, a second availability zone — everything is already in place to build on. Feel free.
