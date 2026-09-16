# devops-ecs-pipeline

A production-shaped AWS deployment pipeline built entirely from code: a containerized FastAPI service running on ECS Fargate behind an Application Load Balancer, provisioned with Terraform, and deployed automatically by GitHub Actions using OIDC federation — no static AWS credentials anywhere.

**Live demo:** `http://<your-alb-dns-name>` *(replace, or remove this line when the stack is torn down)*

---

## Architecture

```
Developer
    │  git push to main
    ▼
GitHub Actions ──── OIDC federation ────► AWS IAM (temporary credentials)
    │  test → build → scan → push
    ▼
Amazon ECR  (immutable, SHA-tagged images)
    │
    ▼
ECS Fargate service ◄──── Application Load Balancer ◄──── Internet
    │
    ▼
CloudWatch  (logs, metrics, dashboard, alarms → SNS email)
```

**Network:** a VPC spanning two availability zones with public subnets, an internet gateway, and a shared route table.

---

## What this demonstrates

| Area | Implementation |
|---|---|
| Infrastructure as Code | Terraform for 100% of AWS resources; remote state in S3 with native locking |
| Containers | Multi-stage Docker build, non-root runtime user, pinned dependencies |
| CI/CD | GitHub Actions: test gate, build, vulnerability scan, push, rolling deploy |
| Security | OIDC federation instead of static keys; least-privilege IAM; SHA-pinned actions |
| Networking | VPC, subnets, route tables, security groups with SG-to-SG references |
| Observability | Structured JSON logs, CloudWatch dashboard, five alarms, SNS email alerts |
| Reliability | Zero-downtime rolling deploys, health-check-driven self-healing, one-command rollback |
| Cost awareness | Documented trade-offs, log retention limits, ECR lifecycle policy, teardown workflow |

---

## Repository layout

```
.
├── app/                    FastAPI service and tests
├── infra/
│   ├── bootstrap/          S3 state backend (local state, run once)
│   └── envs/dev/           VPC, ECR, ALB, ECS, IAM, monitoring
├── .github/workflows/      CI/CD pipeline
└── Dockerfile              Multi-stage build
```

---

## Pipeline

```
push to main
    │
    ├─► Test        pytest, gates everything downstream
    │
    └─► Deploy      (only on main, only on push)
         ├── Assume AWS role via OIDC
         ├── Build image, tag with commit SHA
         ├── Scan with Trivy (CRITICAL/HIGH)
         ├── Push to ECR
         ├── Register new task definition revision
         └── Rolling deploy, wait for service stability
```

Pull requests run the test job only. Deployments are gated on tests passing.

---

## Design decisions and trade-offs

### Public subnets instead of private subnets with NAT

A production VPC would place application tasks in private subnets with a NAT Gateway for outbound traffic. A NAT Gateway costs roughly $32/month running continuously, which would exceed the cost of everything else in this project combined.

Instead, tasks run in public subnets with a security group that accepts traffic **only** from the load balancer's security group — an SG-to-SG reference rather than a CIDR range. Tasks have public IPs for ECR image pulls, but nothing on the internet can reach them directly.

*Production change:* private subnets, NAT Gateway (or VPC endpoints for ECR/CloudWatch/S3, which are cheaper for this traffic pattern).

### Terraform manages infrastructure; the pipeline manages deployments

The ECS service uses `lifecycle { ignore_changes = [task_definition, desired_count] }`.

Without it, Terraform and the CD pipeline fight: the pipeline registers a new task definition revision on every deploy, and the next `terraform apply` would see that as drift and roll the service back to an older image. This is the classic IaC/CD boundary problem, resolved by giving each system clear ownership.

### OIDC federation instead of access keys

The pipeline holds no AWS credentials. GitHub Actions presents a signed OIDC token, AWS validates it against a trust policy scoped to this repository and the `main` branch, and returns short-lived credentials.

The attached policy is least-privilege: ECR actions scoped to this repository's ARN, ECS actions to this service, and `iam:PassRole` restricted to the two task roles. `ecr:GetAuthorizationToken` and `ecs:RegisterTaskDefinition` require `*` because AWS does not support resource-level permissions for those actions.

### Two IAM roles for the task

- **Execution role** — used by the ECS agent to pull images and write logs
- **Task role** — used by application code to call AWS services

The task role is intentionally empty, because the application needs no AWS permissions. Keeping them separate means granting the app a permission later doesn't also widen what the agent can do.

### Alarm thresholds

- **Unhealthy hosts** uses `treat_missing_data = "breaching"`. If the service disappears entirely, the ALB stops publishing the metric; the default setting would leave the alarm in `INSUFFICIENT_DATA` and never fire.
- **5xx count** uses `notBreaching`, because absence of errors is not a failure.
- **Latency** alarms on **p95**, not average — averages hide the tail.
- All alarms use multiple evaluation periods so a single noisy datapoint doesn't page anyone.

### SHA-pinned GitHub Actions

Third-party actions are pinned to commit SHAs, not tags. In March 2026 an attacker with compromised credentials force-pushed the majority of version tags in `aquasecurity/trivy-action` to credential-stealing malware. Git tags are mutable; commit SHAs are not.

---

## Notable debugging: GitHub's immutable OIDC subject claims

The pipeline initially failed with:

```
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

The trust policy matched every published example. Widening the `sub` condition to a wildcard didn't help, which ruled out a simple typo.

Decoding the actual JWT claim inside the workflow revealed the cause:

```
repo:owner@96948136/devops-ecs-pipeline@1361768931:ref:refs/heads/main
```

GitHub repositories created after July 15, 2026 use an **immutable subject format** that embeds the numeric owner and repository IDs, preventing a recycled namespace from minting tokens that match an existing trust policy. Nearly every OIDC tutorial online still shows the older name-only format.

The trust policy now constructs the immutable form explicitly, retaining an exact `StringEquals` match rather than falling back to a wildcard.

*Reference: [GitHub Docs — OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc)*

---

## Reliability demonstrations

### Self-healing

Killing the running task directly:

```bash
aws ecs stop-task --cluster devops-ecs-dev-cluster --task <task-arn> --reason "chaos test"
```

| Time | Desired | Pending | Running |
|---|---|---|---|
| 13:33:27 | 1 | 0 | 0 |
| 13:34:00 | 1 | 1 | 0 |
| 13:34:33 | 1 | 0 | 1 |

Full recovery in ~66 seconds with no human intervention.

With `desired_count = 1` there is a brief outage during replacement. Running two tasks across both availability zones would eliminate it, at roughly double the compute cost.

### Rollback

Every deploy produces an immutable, SHA-tagged image and a numbered task definition revision, so rollback is a single command:

```bash
aws ecs update-service \
  --cluster devops-ecs-dev-cluster \
  --service devops-ecs-dev-service \
  --task-definition devops-ecs-dev:<previous-revision>
```

Measured rollback: **167 seconds**, with no period of zero healthy targets. The application confirmed the change — the `version` field returned by the service reverted from the current commit SHA to the previous revision's value.

Roughly 150 seconds of that is deliberate safety margin rather than latency: a 60-second health check grace period, two consecutive health checks at 30-second intervals, and a 30-second deregistration delay while the old task drains. Tightening those would speed up both deploys and rollbacks at the cost of tolerating slow-starting containers less well.

Zero downtime comes from `deployment_minimum_healthy_percent = 100`, which prevents ECS from stopping the old task before the replacement is healthy and registered with the load balancer.

---

## Running it yourself

**Prerequisites:** AWS account, AWS CLI, Terraform ≥ 1.10, Docker, a GitHub repository.

```bash
# 1. Create the Terraform state backend (once)
cd infra/bootstrap
terraform init && terraform apply

# 2. Update the backend bucket name in infra/envs/dev/providers.tf

# 3. Create the ECR repository first
cd ../envs/dev
terraform init
terraform apply -target="aws_ecr_repository.app"

# 4. Build and push an initial image
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com
docker build -t <ecr-url>:latest ../../.. && docker push <ecr-url>:latest

# 5. Provision everything else
terraform apply

# 6. Store the role ARN as the AWS_ROLE_ARN repository secret
terraform output -raw github_actions_role_arn
```

Update `github_owner_id` and `github_repo_id` in `variables.tf` to match your repository's OIDC claim.

---

## Cost

| Resource | Approximate monthly cost |
|---|---|
| Application Load Balancer | ~$16 |
| Fargate task (0.25 vCPU / 0.5 GB) | ~$9 |
| ECR, CloudWatch, VPC | negligible |
| **Total** | **~$25** |

Cost controls in place: CloudWatch log retention capped at 7 days, ECR lifecycle policy retaining only the 10 most recent images, no NAT Gateway, and `containerInsights` disabled.

Teardown between sessions:

```bash
cd infra/envs/dev && terraform destroy
```

The state bucket in `infra/bootstrap` is left in place. Rebuilding takes about five minutes plus one push.

---

## Possible extensions

- Multi-environment promotion (dev → staging → prod) with separate state and manual approval gates
- HTTPS via ACM and Route 53, with HTTP redirecting to HTTPS
- Blue/green deployment through CodeDeploy with automatic rollback on alarm
- Application auto-scaling driven by request count or CPU
- `terraform plan` on pull requests, posted as a PR comment
- Container Insights for per-task metrics
- Distributed tracing with AWS X-Ray
