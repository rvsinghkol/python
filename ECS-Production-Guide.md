# Production CI/CD: Jenkins → Amazon ECR → Amazon ECS (Fargate) with Terraform

This guide sets up a production pipeline that:

1. Builds and tests the Java app (Maven)
2. Builds a Docker image and scans it for vulnerabilities (Trivy)
3. Pushes the image to **Amazon ECR** with a unique, unchangeable tag (`v42-a1b2c3d`)
4. Runs **Terraform** to deploy that image to **ECS Fargate**, after a manual approval
5. Smoke-tests the live URL

It also supports **one-click rollback** to any older image, and **automatic rollback** if a new version fails health checks.

---

## 1. Architecture

```
 Developer ──push──▶ GitHub
                        │
                        ▼
                 Jenkins (outside AWS, IAM user access keys)
   ┌──────────────────────────────────────────────────────────────┐
   │ Build → Unit Test → Docker Build → Trivy Scan → Push to ECR  │
   │ → Terraform Plan → Manual Approval → Terraform Apply → Smoke │
   └──────────────────────────────────────────────────────────────┘
          │ push image                     │ terraform apply
          ▼                                ▼
   Amazon ECR (docker_remote)      ┌──────── Existing VPC 10.0.0.0/16 ──────────┐
   immutable tags, scan on push    │  Public  10.0.1.0/24, 10.0.2.0/24           │
                                   │    Application Load Balancer :80 (:443)    │
          Terraform state:         │  Private 10.0.3.0/24, 10.0.4.0/24           │
          S3 bucket + lock file    │    ECS Fargate tasks :8080  (2 → 6 tasks)  │
                                   └────────────────────────────────────────────┘
   Terraform only READS the VPC and subnets - it never changes them.
   It creates: security groups, ALB, ECS cluster/service, roles, logs, alarms.
                                     CloudWatch logs, alarms → SNS email
```

**Why it's production-ready**

| Area | What's configured |
|---|---|
| Security | Tasks in private subnets with no public IP; only the load balancer can reach them. Container runs as non-root. Jenkins uses a dedicated IAM user that can only touch this app's resources. ECR tags are immutable. Images are scanned before push. |
| Availability | 2 tasks minimum, spread over 2 Availability Zones. Rolling deploys that never drop below current capacity. |
| Safe releases | Manual approval before prod, Terraform plan saved as an artifact, deployment circuit breaker with automatic rollback, smoke test. |
| Scaling | Autoscaling 2–6 tasks on CPU (60%) and memory (75%). |
| Observability | CloudWatch Logs (30 days), Container Insights, alarms for 5xx errors, unhealthy tasks, low task count, high CPU/memory. |
| State | Terraform state in an encrypted, versioned S3 bucket with locking. |

---

## 2. Repository layout

Copy these files into your repo (`rvsinghkol/python`):

```
python/
├── Dockerfile                 # multi-stage build, non-root Tomcat
├── .dockerignore
├── Jenkinsfile                # the pipeline
├── pom.xml
├── src/
├── scripts/
│   └── check-network.sh       # checks your subnets before the first deploy
└── terraform/
    ├── bootstrap/             # run ONCE by an admin
    │   ├── main.tf            # S3 state bucket + ECR repo
    │   ├── jenkins-iam.tf     # IAM user + policy for Jenkins
    │   ├── variables.tf
    │   └── outputs.tf
    └── app/                   # run by Jenkins on every deploy
        ├── versions.tf        # provider + S3 backend
        ├── variables.tf
        ├── prod.tfvars        # production settings
        ├── network.tf         # reads existing VPC/subnets, creates security groups
        ├── alb.tf             # load balancer
        ├── ecs.tf             # cluster, roles, task definition, service
        ├── autoscaling.tf
        ├── monitoring.tf      # alarms + SNS
        └── outputs.tf
```

Also add the lines from `.gitignore.terraform` to your `.gitignore`. Do commit `terraform/app/.terraform.lock.hcl` once it's created; it pins provider versions.

---

## 3. Prerequisites on the Jenkins server

Install these on your Jenkins server and check them **as the `jenkins` user** (`sudo -u jenkins <command>`):

| Tool | Check | Notes |
|---|---|---|
| Docker | `docker ps` | `jenkins` user must be in the `docker` group: `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| AWS CLI v2 | `aws --version` | |
| Terraform ≥ 1.10 | `terraform version` | Needed for the S3 lock file (`use_lockfile`). Install steps below. |
| Git, curl | `git --version` | |
| Maven | Jenkins → Manage Jenkins → Tools → Maven named **`Maven`** | Already set up in your pipeline |

Install Terraform (Ubuntu):

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
```

The Jenkins server needs outbound internet access to the AWS APIs (`*.amazonaws.com`, port 443) and to GitHub.

Jenkins plugins (most come with the suggested install): **Pipeline**, **Git**, **JUnit**, **Pipeline: Stage View**.

---

## 4. Step 1 – Bootstrap (one time, by an AWS admin)

Run this from your laptop or **AWS CloudShell**, logged in as an admin. It creates the state bucket, the ECR repository and the Jenkins IAM user.

```bash
cd terraform/bootstrap
terraform init
```

**Region note:** everything now runs in **ap-south-2**. Your earlier `docker_remote` repository is in ap-south-1, so it's a separate repository and Terraform creates a new one in ap-south-2. Old images stay in ap-south-1; rollback history starts fresh.

**Only if `docker_remote` already exists in ap-south-2** (check with `aws ecr describe-repositories --repository-names docker_remote --region ap-south-2`), import it first so Terraform doesn't fail with "already exists":

```bash
terraform import aws_ecr_repository.app docker_remote
```

Then create everything:

```bash
terraform plan
terraform apply
```

Note the outputs:

```
state_bucket             = "docker-remote-tfstate-717479681461"
ecr_repository_url       = "717479681461.dkr.ecr.ap-south-2.amazonaws.com/docker_remote"
jenkins_iam_user         = "docker-remote-jenkins"
```

> Keep `terraform/bootstrap/terraform.tfstate` safe (don't commit it to a public repo). You only need it to change the bootstrap resources later.

> The ECR repo becomes **IMMUTABLE**. Old tags like `1`, `2` still work for rollback, but no tag can be pushed twice. That's why new builds use `v<build>-<commit>`.

---

## 5. Step 2 – Create the Jenkins access key

Your Jenkins server isn't on AWS, so it signs in with an access key for the IAM user `docker-remote-jenkins`. That user can only work with this app's resources. The key is created by hand, outside Terraform, so the secret never ends up in Terraform state.

**1. Create the key (as an admin):**

```bash
aws iam create-access-key --user-name docker-remote-jenkins
```

Or in the console: IAM → Users → `docker-remote-jenkins` → Security credentials → **Create access key** → *Third-party service*.

Copy `AccessKeyId` and `SecretAccessKey`. The secret is shown only once.

**2. Store it in Jenkins:** Manage Jenkins → Credentials → System → Global → **Add Credentials**, twice, with Kind = **Secret text**:

| ID | Secret |
|---|---|
| `aws-access-key-id` | the AccessKeyId |
| `aws-secret-access-key` | the SecretAccessKey |

If these IDs already exist from your earlier pipeline, **update** them with the new key. Then deactivate the old personal or admin key that was there before, so Jenkins no longer has admin rights.

**3. Verify it from the Jenkins server:**

```bash
AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... aws sts get-caller-identity
# "Arn": "arn:aws:iam::717479681461:user/docker-remote-jenkins"
```

**Key rotation (every 90 days):** create a second key, update both Jenkins credentials, run a build to confirm it works, then deactivate and delete the old key.

---

## 5a. Step 2b – Outbound access for the private subnets

The ECS tasks run in your **private** subnets and must reach ECR to pull the image.

**Your result (2026-11-03):** the VPC `vpc-090c3a4af5cb115ba` is in **ap-south-2 (Hyderabad)**.

- Public subnets use `rtb-0ffd647488e6b6494`, which routes to `igw-02c95d919709327c9`.
- Private subnets use `rtb-0c8d33156de712e5a`, which **already routes to `nat-1ebf1a695ca6c7cf5`**.
- Both pairs span `ap-south-2a` and `ap-south-2b`.

So `prod.tfvars` keeps `create_nat_gateway = false` and `create_vpc_endpoints = false`; nothing needs to be created. The steps below only apply if the network changes later or you set up another VPC.

**1. Find the private route table ID(s).** From the repo root:

```bash
bash scripts/check-network.sh
```

It prints each subnet's AZ, route table (`rtb-...`) and default route, plus the exact lines to put in `prod.tfvars`. In the console, go to VPC → Subnets → select a private subnet → **Route table** tab. If both private subnets show the same `rtb-` ID, list it once.

**2. Choose how tasks get out**, in `terraform/app/prod.tfvars`:

| | **A) NAT gateway** (set by default) | **B) VPC endpoints** |
|---|---|---|
| Setting | `create_nat_gateway = true` | `create_vpc_endpoints = true` |
| Pull from ECR, write logs | Yes | Yes |
| Call **external internet APIs** (payment gateways, SMS, email, third-party services) | Yes | **No** |
| What Terraform creates | 1 Elastic IP, 1 NAT gateway in public subnet 1, and a `0.0.0.0/0 → NAT` route in the private route table(s) | Endpoints for ECR (api + dkr), CloudWatch Logs and S3 |
| Cost | NAT hourly charge plus per-GB data | 3 interface endpoints × 2 AZs, hourly. S3 endpoint is free. |
| Fixed outbound IP (for partner allow-lists) | Yes: the Elastic IP | No |

Use **A** if the application calls anything on the internet; most apps do. Use **B** only if it talks to nothing outside AWS.

```hcl
private_route_table_ids = ["rtb-0abc123..."]   # from step 1
create_nat_gateway      = true
create_vpc_endpoints    = false
```

**What Terraform changes in your network:** it adds only the `0.0.0.0/0` route to the listed route table(s). Nothing else in them is touched, and `terraform destroy` removes only that route. If the check script reports that a route table **already has** a `0.0.0.0/0` route (for example to a transit gateway), stop and talk to your network admin first.

**One NAT gateway lives in one AZ.** If that AZ goes down, tasks in the other AZ lose outbound access. That's fine to start with; for stricter availability, add a second NAT later.

**3. Re-apply the bootstrap** so the Jenkins user is allowed to create the NAT gateway, Elastic IP and route:

```bash
cd terraform/bootstrap && terraform apply
```

**Also check:** the public subnets must route `0.0.0.0/0` to `igw-02c95d919709327c9`, and each pair of subnets must be in **two different AZs**. The script checks both.

---

## 6. Step 3 – Check the configuration files

| File | What to check |
|---|---|
| `terraform/app/versions.tf` | `bucket` = the `state_bucket` output from Step 1 |
| `terraform/app/prod.tfvars` | `alarm_email` = your team's email list; `health_check_path` = a URL that returns 200 (see below) |
| `terraform/app/prod.tfvars` | `public_subnet_ids` / `private_subnet_ids` (already set to your 4 subnets); `private_route_table_ids` and `create_nat_gateway` / `create_vpc_endpoints` from Step 2b. Already set to `rtb-0c8d33156de712e5a`, with both options `false` because a NAT exists. |
| `Jenkinsfile` | `AWS_ACCOUNT_ID`, Git URL/branch, `github-token`, `aws-access-key-id`, `aws-secret-access-key` credential IDs |
| `app_name` | Must be the **same** in `bootstrap/variables.tf` and `app/prod.tfvars` (the Jenkins IAM policy only allows roles named `<app_name>-*`) |

**Health check path:** the load balancer marks a task healthy only if `health_check_path` returns HTTP 200–399. Test it locally:

```bash
docker run -d -p 8080:8080 <your-image> && sleep 30
curl -i http://localhost:8080/
```

If `/` returns 404 or 500, set `health_check_path` to a page that works, such as `/index.jsp` or a `/health` endpoint. Otherwise every deploy will fail and roll back.

Commit and push everything to `master`.

---

## 7. Step 4 – Create the Jenkins job

1. Jenkins → **New Item** → name `docker-remote-prod` → **Pipeline** → OK
2. **Pipeline** section → Definition: **Pipeline script from SCM**
   - SCM: Git, URL `https://github.com/rvsinghkol/python.git`, credentials `github-token`
   - Branch: `*/master`, Script Path: `Jenkinsfile`
3. Optional: **Build Triggers** → *GitHub hook trigger for GITScm polling*, so a push starts the build. The deploy still waits for your approval.
4. Save → **Build Now** once. This first run registers the `ACTION` parameter.

---

## 8. First deployment – what happens

Click **Build with Parameters** → `ACTION = deploy` → **Build**.

| Stage | Notes |
|---|---|
| Verify AWS access | Prints `user/docker-remote-jenkins`. Fails here if the Step 2 credentials are wrong. |
| Build / Unit Test | Maven compile and tests. Test reports appear on the build page. |
| Docker Build image | Tag `v<build>-<commit>`, e.g. `v1-a1b2c3d` |
| Security Scan | Fails on **CRITICAL** vulnerabilities that have a fix. Update the base image or dependency, then rebuild. |
| Push to ECR | |
| Terraform Init & Validate | |
| Terraform Plan | First run: about 25 resources to add (NAT gateway, Elastic IP and route included). Plan saved as **tfplan.txt** in Build Artifacts. |
| **Approve Production Deploy** | Build pauses. Review tfplan.txt, then click **Deploy to Production**. |
| Terraform Apply | **First run takes about 6–10 minutes** (NAT gateway, ALB, ECS). Later deploys take about 3–5 minutes. |
| Smoke Test | Calls the app URL and prints it |

The console log ends with:

```
PRODUCTION is running 717479681461.dkr.ecr.ap-south-2.amazonaws.com/docker_remote:v1-a1b2c3d
at http://docker-remote-prod-alb-1234567890.ap-south-2.elb.amazonaws.com
```

That URL stays the same across all future deploys and rollbacks.

If you set `alarm_email`, AWS sends a **subscription confirmation email**. Click the link, or you won't get alerts.

---

## 9. Day-to-day operations

### Deploy new code

Push to `master` (or click **Build with Parameters → deploy**), then approve the deploy. For a normal release, the plan shows **1 to add, 1 to change**: a new task definition revision and the service update.

### Manual rollback

1. **Build with Parameters** → `ACTION = rollback` → Build
2. **Select Version from ECR** pauses and shows the version currently in production, plus a dropdown of every image in ECR (newest first)
3. Pick a version → Continue → review the plan → **Deploy to Production**

There's no rebuild; it takes about 3–5 minutes. The build description shows `ROLLBACK to v40-9f8e7d6`.

### Automatic rollback

If new tasks fail to start or fail health checks repeatedly, the ECS **deployment circuit breaker** puts the previous version back automatically. The Terraform Apply stage then fails (red build), and production stays on the old version. Fix the code and deploy again, or run a manual rollback so Terraform state matches what's running.

### How far back can I roll back?

ECR keeps the last **30 images** (`ecr_keep_images` in bootstrap). Older images are deleted and can't be rolled back to.

### View logs

```bash
aws logs tail /ecs/docker-remote-prod --follow --region ap-south-2
```

Or in the console: CloudWatch → Log groups → `/ecs/docker-remote-prod`.

### Change infrastructure (CPU, memory, task counts…)

Edit `prod.tfvars` or the `.tf` files, commit, and run a **deploy**. The plan shows the infrastructure change, and you approve it like any release. To undo it, `git revert` the commit and deploy again.

---

## 10. Adding HTTPS later (when you have a domain)

1. In **AWS Certificate Manager** (region `ap-south-2`) → Request a public certificate for `app.yourdomain.com` → **DNS validation**
2. Add the CNAME record ACM shows at your DNS provider and wait for **Issued**
3. At your DNS provider, create a CNAME `app.yourdomain.com` → the `alb_dns_name` output
4. In `prod.tfvars`, set `certificate_arn = "arn:aws:acm:ap-south-2:717479681461:certificate/xxxx"`
5. Commit and deploy. Port 80 now redirects to HTTPS (TLS 1.2/1.3), and `app_url` becomes `https://...`

Add `"acm:DescribeCertificate"` to the Jenkins IAM policy if Terraform reports a permission error for it.

---

## 11. Production hardening checklist

**Done by this setup**

- [x] Tasks in private subnets, least-access security groups
- [x] Jenkins uses a least-privilege IAM user (not admin keys)
- [x] Immutable, scanned images
- [x] Approval gate, saved plan, state locking
- [x] Multi-AZ, autoscaling, circuit-breaker rollback
- [x] Logs, Container Insights, alarms

**Recommended next steps**

- [ ] **Restrict approvers:** add `submitter: 'ravi,teamlead'` to the approval `input` in the Jenkinsfile
- [ ] **Pin the Trivy version** (`TRIVY_IMAGE`) instead of `latest`
- [ ] **Secrets:** store DB passwords and API keys in **AWS Secrets Manager**, then reference them in the task definition with `secrets = [{ name = "DB_PASSWORD", valueFrom = "<secret ARN>" }]`. Also give the execution role `secretsmanager:GetSecretValue` on that secret. Never put secrets in `environment` or in Git.
- [ ] **HTTPS** (section 10), then optionally **AWS WAF** on the load balancer
- [ ] **Rotate the Jenkins access key** every 90 days (Step 2). Better still, move Jenkins onto AWS later and switch to an IAM role.
- [ ] **NAT per AZ:** if your VPC has one NAT gateway, an outage in that AZ stops tasks in the other AZ from pulling images. Ask your network admin about one NAT per AZ.
- [ ] **AWS Budgets** alert on the account
- [ ] **VPC Flow Logs** and **ALB access logs** to S3 for auditing
- [ ] **Jenkins itself:** back up `JENKINS_HOME`, keep plugins updated, put Jenkins behind HTTPS/VPN

---

## 12. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `Unable to locate credentials` / `InvalidClientTokenId` in *Verify AWS access* | Jenkins credential IDs don't match, or the key is wrong or deactivated (Step 2) |
| `AccessDenied ... iam:CreateRole` | `app_name` differs between bootstrap and app; roles must be named `docker-remote-*` |
| `Error acquiring the state lock` | Another run is applying, or a run was killed. If you're sure nothing is running: `terraform force-unlock <LOCK_ID>` in `terraform/app` |
| Plan fails: `aws_ecr_image ... not found` | The tag doesn't exist in ECR. Check the Push stage, or pick a listed version |
| `tag invalid: The image tag 'xx' already exists` | Tags are immutable. Pipeline tags are unique; don't push manual tags twice |
| Apply runs about 20 min then fails, service shows *rolled back* | New tasks unhealthy. Check `aws logs tail /ecs/docker-remote-prod` and the target group health. Usually a wrong `health_check_path` or app startup error. |
| Tasks stuck in PENDING, `CannotPullContainerError` / `ResourceInitializationError` | Private subnets can't reach ECR. Run `scripts/check-network.sh`. Make sure `create_nat_gateway = true` (or endpoints) and `private_route_table_ids` point to the private subnets' route table. |
| `RouteAlreadyExists` during apply | The private route table already has a `0.0.0.0/0` route. Don't override it; check with your network admin. |
| `UnauthorizedOperation ... CreateNatGateway` | Bootstrap not re-applied after the NAT change (Step 2b, item 3) |
| Plan error: `subnets must each be in at least 2 different Availability Zones` | Two of your subnets share an AZ (Step 2b) |
| `InvalidSubnet` / `security group ... does not belong to VPC` | A subnet ID in `prod.tfvars` belongs to a different VPC. All 4 subnets must be in the same VPC. |
| Security Scan fails | A CRITICAL vulnerability has a fix. Update the base image (`tomcat:9-jdk11`) or the dependency in `pom.xml`, then rebuild |
| Smoke test fails but apply succeeded | New ALB DNS can take a few minutes on the first run. Open the URL manually; re-run if it works |

---

## 13. Cost drivers

All of these are charged while running. Check the AWS Pricing Calculator for `ap-south-2`:

- **NAT gateway** (if `create_nat_gateway = true`): hourly charge plus per-GB data, plus the Elastic IP
- **VPC endpoints** (only if `create_vpc_endpoints = true`): 3 interface endpoints × 2 AZs, charged hourly. The S3 endpoint is free.
- **Application Load Balancer**: hourly charge plus usage (LCUs)
- **Fargate**: 2–6 tasks × (1 vCPU + 2 GB) per hour
- **Container Insights, CloudWatch Logs**, ECR storage (small)

---

## 14. Removing everything (if ever needed)

```bash
cd terraform/app
# 1. allow ALB deletion: set alb_deletion_protection = false in prod.tfvars
terraform init
terraform apply  -var-file=prod.tfvars -var image_tag=<current tag>
terraform destroy -var-file=prod.tfvars -var image_tag=<current tag>
```

The bootstrap resources (state bucket, ECR) have `prevent_destroy` on purpose. Remove those lines first if you really want to delete them.

Your VPC and subnets are **not** touched by `destroy`.

Also delete the resources from the earlier experiments (`uat-cluster`, `docker-remote-cluster` and their services and load balancers) so you don't pay for them.
