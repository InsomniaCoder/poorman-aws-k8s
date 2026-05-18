# poorman-k8s

## Architecture

### Topology

```
VPC 10.0.0.0/16  (single AZ — eu-south-2a)
├── Public subnet  10.0.1.0/24
│   ├── K3S server   m7g.large SPOT   EIP  ← internet traffic arrives here
│   └── fck-NAT      t4g.nano  SPOT   EIP  ← outbound NAT for private subnet
└── Private subnet 10.0.2.0/24
    └── K3S worker   t4g.small SPOT        ← no public IP, egress via fck-NAT
```

### Traffic flows

**Inbound (internet → cluster):**
```
DNS A record → server EIP :80/:443
  → ServiceLB (klipper-lb iptables DNAT on the server node)
    → Traefik ingress controller
      → pod (server node or worker node via Flannel overlay)
```
NodePort is not used. All external traffic enters through Traefik ingress only.

**Pod egress:**
- Server node pods: direct to IGW (public subnet, no extra cost, no NAT hop).
- Worker node pods: private subnet → fck-NAT instance → IGW.

**In-cluster (overlay):**
All pod-to-pod traffic, including cross-node, travels over the Flannel VXLAN overlay (UDP 8472). The server advertises its private IP (`--advertise-address=$PRIVATE_IP`) so in-cluster API calls stay inside the VPC and avoid the EIP hairpin problem AWS would otherwise drop.

**Worker → server join:**
Workers read the K3S token and server private IP from SSM Parameter Store at boot and connect to `https://<private_ip>:6443`. No public IP involved.

### Ports open from the internet

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 80 | TCP | `0.0.0.0/0` | HTTP (Traefik, redirects to HTTPS) |
| 443 | TCP | `0.0.0.0/0` | HTTPS (Traefik TLS termination) |
| 6443 | TCP | `$ADMIN_CIDR` | kubectl / K3S API (admin only) |

Everything else is blocked at the security group. Workers have no internet-facing ports at all.

### Inter-node security group model

The server and worker security groups grant each other full bidirectional access (all ports, all protocols) using SG-reference rules rather than CIDR+port enumeration. Reason: the meaningful security boundary is the internet edge (above table). Server↔worker is a trusted cluster-internal boundary — if either node is compromised the K3S join token gives full cluster access regardless of which ports are open, so enumerating them adds operational friction with no security benefit. The SG-reference model also handles any future Kubernetes feature that opens a new port without requiring a Terraform change.

### Downtime risks and expected recovery times

This cluster is designed for personal use and accepts downtime. All compute runs on SPOT. Recovery is automatic but not instant.

| Scenario | What breaks | Recovery mechanism | Expected recovery |
|----------|------------|-------------------|-------------------|
| Server SPOT interruption | API server, ArgoCD, Traefik, HTTP/HTTPS ingress all go down simultaneously | ASG launches replacement → user-data re-attaches EBS (K3S state preserved), re-associates EIP, restarts K3S | ~1–2 min |
| Worker SPOT interruption | Workload pods on that node evicted; ArgoCD reschedules them after server is back | ASG launches replacement → user-data reads SSM token, rejoins cluster | ~1 min |
| fck-NAT SPOT interruption | Worker egress (image pulls, SSM, external API calls) blocked | ASG (`ha_mode=true`) re-attaches static ENI; private route table never changes | ~45–90 sec |
| Server + fck-NAT simultaneous interruption | Everything above, plus worker cannot reach SSM to rejoin | fck-NAT recovers first (~45s); worker retries SSM for up to 5 min; resolves automatically | ~2–3 min |
| All three simultaneously | Full cluster outage | Same as above, sequenced automatically | ~2–3 min |

EBS data volume has `prevent_destroy = true` — K3S state (etcd, certs, kubeconfig) survives all SPOT interruptions.

If you need higher availability: switch ASG launch templates to on-demand (`on_demand_percentage_above_base_capacity = 100`). No other changes required.

## Principles
- **Graviton first and only**: t4g/m7g/c7g exclusively. No x86-64 instances.
- **SPOT first**: Always use SPOT. Fallback chain within same ARM64 architecture only.
- **Single AZ**: Always eu-south-2a. No cross-AZ resources.
- **Minimal HCL**: Logic in .tf modules. Terragrunt .hcl = inputs + include only.
- **S3 native locking**: `use_lockfile = true`. No DynamoDB.
- **Update cost table**: Any change affecting cost MUST update the table below immediately.

## Cost Estimation Table

| Component              | Cost/mo (est.) | Notes                                    |
|------------------------|----------------|------------------------------------------|
| K3S control plane      | $0             | K3S on EC2, no EKS fee                   |
| Load Balancer          | $0             | ServiceLB HostPort — no NLB needed       |
| m7g.large SPOT (server)| ~$12–18        | ~60–70% off on-demand                    |
| t4g.small SPOT (worker)| ~$3–5          | ~60–70% off on-demand                    |
| fck-NAT t4g.nano       | ~$3            | Replaces $33/mo NAT Gateway              |
| EBS root 30 GB gp3 × 2 | ~$4.80         | Server + worker OS volumes (min 30 GB — AL2023 snapshot size) |
| EBS data 20 GB gp3     | ~$1.60         | /var/lib/rancher/k3s/ persistence        |
| EIP × 2                | $0             | Free when associated to running instance |
| S3 state bucket        | ~$0.02         | Versioning enabled, tiny state files     |
| **Total**              | **~$24–32/mo** |                                          |

## Session setup

Always `source .env` before running any Terragrunt command. All live stacks are under `live/eu-south-2/`.