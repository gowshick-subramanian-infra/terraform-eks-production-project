# Architecture Deep Dive

## 1. Networking

Each environment provisions its own VPC (non-overlapping CIDRs across
dev/stg/prod so they could theoretically be peered or connected via Transit
Gateway later):

| Environment | VPC CIDR |
|---|---|
| dev  | 10.10.0.0/16 |
| stg  | 10.20.0.0/16 |
| prod | 10.30.0.0/16 |

Each VPC is split into three subnet tiers, one subnet per tier per AZ:

- **Public** — `/24`s hosting the ALB and NAT Gateway(s). Route: `0.0.0.0/0` → IGW.
- **Private** — `/24`s hosting EKS worker nodes. Route: `0.0.0.0/0` → NAT Gateway.
- **Database** — `/24`s hosting RDS. No default route to the internet at all;
  only reachable from within the VPC CIDR.

`dev` uses a single NAT Gateway (in AZ-a) referenced by all private route
tables to minimize cost. `stg`/`prod` create one NAT Gateway per AZ and a
matching private route table per AZ, so an AZ failure doesn't take down
outbound connectivity for the other AZs.

## 2. Security Groups vs NACLs

Security Groups are the **primary, stateful** control and are scoped
tightly by reference (SG-to-SG), not by CIDR, wherever possible:

- ALB SG: allows 80/443 from `0.0.0.0/0` (this is the actual internet-facing
  boundary — everything downstream is private).
- EKS node SG: allows the Tomcat port **only** from the ALB SG, plus
  node-to-node traffic for the CNI/kubelet.
- RDS SG: allows the Postgres port **only** from the EKS node SG.

NACLs are the **secondary, stateless** control applied at the subnet level.
Because NACLs are stateless, each rule set explicitly opens the ephemeral
port range (1024-65535) for return traffic. The database NACL is the most
restrictive: it only permits Postgres + ephemeral traffic from the VPC CIDR,
regardless of what's in the security group.

This two-layer model means a misconfigured security group alone is not
enough to expose the database tier to the internet — the NACL would still
block it.

## 3. IAM & IRSA

Two IAM modules exist by design:

- **`modules/iam`** — created *before* the EKS cluster exists. Contains the
  EKS control-plane service role and the managed node group's EC2 instance
  role. These have no dependency on the cluster itself.
- **`modules/iam-irsa`** — created *after* the EKS cluster (and its OIDC
  provider) exists. Contains roles that Kubernetes service accounts assume
  via IRSA (IAM Roles for Service Accounts): AWS Load Balancer Controller,
  Cluster Autoscaler, and the EBS CSI driver.

Splitting these avoids a circular module dependency (iam → eks → iam) while
still letting Terraform resolve the whole graph in one `apply`.

## 4. EKS

- Control plane logging is enabled for all five log types (api, audit,
  authenticator, controllerManager, scheduler) → CloudWatch, with a
  configurable retention period.
- Secrets are encrypted at the etcd layer using a dedicated, rotated KMS key
  (`aws_eks_cluster.encryption_config`).
- The managed node group spans all given private subnets in stg/prod
  (`multi_az_nodes = true`) and a single subnet in dev.
- Core add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI) are managed as
  first-class `aws_eks_addon` resources rather than manually installed, so
  their versions and configuration are tracked in Terraform state.
- `lifecycle { ignore_changes = [scaling_config[0].desired_size] }` on the
  node group prevents Terraform from fighting the Cluster Autoscaler over
  the desired node count.

## 5. RDS

- PostgreSQL, parameterized engine version (default 16.4).
- `manage_master_user_password = true` delegates password generation and
  rotation-readiness to AWS Secrets Manager — the password is never present
  in Terraform state or version control.
- `multi_az` toggle: `false` in dev, `true` in stg/prod, giving a
  synchronous standby in a second AZ with automatic failover.
- Enhanced Monitoring (60s granularity) and Performance Insights are enabled
  in stg/prod for deeper query-level visibility; disabled in dev to save
  cost.
- `enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]` ships DB logs
  to CloudWatch for centralized troubleshooting.

## 6. Observability

- A single CloudWatch dashboard per environment visualizes RDS CPU, free
  storage, and connection count.
- Three baseline alarms (CPU, storage, connections) publish to an SNS topic
  with an optional email subscription.
- VPC Flow Logs and EKS/RDS logs all funnel into CloudWatch Logs with
  per-resource retention settings, so log volume/cost scales predictably.

## 7. DNS

Route53 record creation is deliberately decoupled from the initial
`terraform apply`: the ALB is created dynamically by the in-cluster AWS Load
Balancer Controller in response to the `Ingress` resource, so its DNS name
isn't known until after the app is deployed. The `route53` module is ready
to use — you supply the ALB's DNS name/zone ID (from
`kubectl get ingress`) and apply again, or manage DNS as a small separate
Terraform root that only depends on that one output.

## 8. CI/CD Trust Model

GitHub Actions authenticates to AWS via OIDC federation
(`aws-actions/configure-aws-credentials` with `role-to-assume`), so no
long-lived AWS access keys are stored as GitHub secrets. Production applies
require both a manual `workflow_dispatch` trigger and reviewer approval via
a protected GitHub Environment — there is no path for a `prod` apply to run
unattended from a normal push.
