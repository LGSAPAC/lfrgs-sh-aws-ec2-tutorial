# Liferay DXP Self-Hosted on Amazon EC2: Step-by-Step Guide

**Product:** Liferay DXP 2026.Q1 LTS (`2026.q1.13-lts`), self-hosted on Amazon EC2, deployed with Docker (or the traditional Tomcat bundle)
**Audience:** Partner and customer technical teams setting up a sandbox or proof-of-concept (PoC) environment
**Prepared by:** Liferay Customer Success APAC
**Status:** Draft, October 2026. Sections 2 to 8 (prerequisites, tools, AWS access, Terraform plan and apply, instance bootstrap, first start and sign-in) tested on 22 October 2026 in Asia Pacific (Tokyo), single mode with the Docker runtime; sections 9 onwards not yet run on AWS. The Terraform passes `terraform validate`, every shell script passes ShellCheck, and the sample workspace's build and `linux/amd64` image jobs passed in GitHub Actions on 22 October 2026 ([run 39708712711](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace/actions/runs/39708712711)). Items to confirm are marked **🔎 Verify**.

> ⚠️ **Read this first: this is a draft, only partly tested.**
> Sections that have been run on a real AWS account are marked **✅ Tested** or **🟡 Partly tested**; the others have not been run yet. This guide builds Liferay on plain EC2 instances: no Kubernetes, no EKS, no Helm. It combines Liferay's documented self-hosted installation (Docker image and Tomcat bundle, Cluster Link, remote Elasticsearch) with common AWS practice (Terraform, Application Load Balancer, RDS, EFS, Systems Manager, GitHub OIDC). AWS console labels and instance types change; follow AWS documentation where it differs from this guide.

> ⚠️ **Handle credentials with care.** This guide uses placeholders such as `<region>`, `<stack>` and `<account-id>`. Generated passwords live in SSM Parameter Store and in the Terraform state; nothing secret is committed. Never paste access keys, passwords or license files into documents, slides, chat, tickets or Git.

---

## Repository layout

The step-by-step guide below is the source of truth; the files implement it. Terraform copies everything under `host/` to `/opt/liferay-ec2` on each instance at boot.

| File | Used in | Purpose |
| --- | --- | --- |
| `scripts/check-aws-access.sh` | Section 4.4 | Read-only check that your AWS credentials reach every service the guide uses |
| `terraform/` | Sections 5, 6 | VPC, security groups, ALB, EC2, RDS, EFS, S3, ECR, SSM parameters, IAM and the GitHub OIDC role |
| `terraform/terraform.tfvars.example` | Section 5 | Every option: single or high availability, Docker or Tomcat, versions, sizes |
| `terraform/templates/user-data.sh.tftpl` | Section 7 | EC2 user data: writes `/etc/liferay-ec2/host.env`, copies `host/` from S3, runs the bootstrap |
| `license/README.md` | Section 2.3 | Where to put your activation key locally (never committed) |
| `host/scripts/bootstrap.sh` | Section 7 | Installs Docker and Compose, mounts EFS, renders config, starts the stack |
| `host/scripts/render-config.sh` | Section 7 | Writes `portal-ext.properties`, the Elasticsearch OSGi config, JGroups files and the license from host settings and SSM secrets |
| `host/docker/compose.yaml` | Sections 8, 9 | Liferay, PostgreSQL 16 and Elasticsearch services, picked per instance with Compose profiles |
| `host/docker/elasticsearch/Dockerfile` | Sections 8, 9 | Elasticsearch 8.19 with Liferay's four analysis plugins |
| `host/scripts/install-tomcat-bundle.sh` | Section 8.3 | Tomcat runtime: Amazon Corretto 21, the DXP Tomcat bundle (checksum-verified) and a systemd service |
| `host/systemd/liferay.service` | Section 8.3 | systemd unit for the Tomcat bundle |
| `host/config/jgroups-tcp-jdbc-ping.xml` | Section 9.4 | Cluster Link over TCP with JDBC_PING discovery (no multicast in a VPC) |
| `host/scripts/deploy-docker.sh` | Section 12 | Rolls a node to a new image, waits for it to be ready, rolls back on failure |
| `host/scripts/deploy-tomcat.sh` | Section 12 | Deploys a workspace build into a Tomcat bundle (hot deploy, restart only if configs changed) |
| `host/scripts/verify-node.sh` | Every section | Read-only checks of one instance; prints `PASS` / `FAIL` per check |
| `host/scripts/liferay-log.sh` | Sections 8, 9, 12 | Prints the Liferay log for either runtime (`-f` to follow) |
| `scripts/run-on-stack.sh` | Every section | Runs a command on the stack's instances through SSM and prints each output |
| `scripts/verify-deployment.sh` | Section 11 | End-to-end check: load balancer targets, HTTP, and `verify-node.sh` on every instance |
| `docs/architecture-*.mmd` / `.png` | Section 1 | Architecture diagrams (Mermaid source and rendered images) |
| [LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace) (separate repo) | Section 12 | Liferay Workspace with a sample module and client extension, and GitHub Actions that build, push to ECR and deploy to these instances |

---

## Contents

1. [What you will build](#1-what-you-will-build)
2. [Prerequisites](#2-prerequisites)
3. [Install the command-line tools](#3-install-the-command-line-tools)
4. [Set up AWS access](#4-set-up-aws-access)
5. [Choose your options](#5-choose-your-options)
6. [Provision the infrastructure](#6-provision-the-infrastructure)
7. [How each instance is bootstrapped](#7-how-each-instance-is-bootstrapped)
8. [Single instance: start Liferay](#8-single-instance-start-liferay)
9. [High availability](#9-high-availability)
10. [HTTPS and your own domain](#10-https-and-your-own-domain)
11. [Validate the deployment](#11-validate-the-deployment)
12. [CI/CD with GitHub Actions](#12-cicd-with-github-actions)
13. [Backups, logging and monitoring](#13-backups-logging-and-monitoring)
14. [From PoC to production](#14-from-poc-to-production)
15. [Tear down the environment](#15-tear-down-the-environment)
16. [Troubleshooting](#16-troubleshooting)
17. [Assumptions to verify](#17-assumptions-to-verify)
18. [Reference documentation](#18-reference-documentation)

---

## 1. What you will build

Two deployment modes and two ways to run Liferay, chosen with two Terraform variables. Every combination uses the same scripts, the same configuration and the same CI/CD pipeline.

| | `deployment_mode = "single"` | `deployment_mode = "ha"` |
| --- | --- | --- |
| **Use it for** | Sandbox, demo, first PoC | PoC of the production topology, failover tests |
| **Load balancer** | Application Load Balancer (ALB) | ALB with sticky sessions across 2+ nodes |
| **Liferay DXP** | 1 EC2 instance (`m6i.xlarge`) in a public subnet | 2 or more EC2 instances in private subnets, two Availability Zones, Cluster Link |
| **Database** | PostgreSQL 16 container on the same instance | Amazon RDS for PostgreSQL 16, Multi-AZ |
| **Search** | Elasticsearch 8.19 container on the same instance | Elasticsearch 8.19 on its own EC2 instance |
| **Documents and Media** | Folder on the instance's EBS volume | Amazon EFS, shared by every node |
| **Outbound internet** | Public IP (inbound only from the ALB) | NAT gateway |
| **Secrets** | SSM Parameter Store (SecureString) | Same |
| **Admin access** | SSM Session Manager (no SSH, no open ports) | Same |
| **Rough cost** 🔎 | About USD 250 per month in `ap-northeast-1` (Tokyo) | About USD 900 per month |

| | `liferay_runtime = "docker"` (recommended) | `liferay_runtime = "tomcat"` |
| --- | --- | --- |
| **How Liferay runs** | `liferay/dxp:2026.q1.13-lts` container, or your custom image from ECR | DXP Tomcat bundle in `/opt/liferay`, `liferay` systemd service, Amazon Corretto 21 |
| **What CI/CD deploys** | A new image (workspace code baked in), node by node | Module jars and client extension zips into `deploy/` (hot deploy), node by node |
| **Upgrades** | New image tag | New bundle (`liferay_version`), re-run the bootstrap |
| **Choose it when** | You want immutable, repeatable deployments | Your team already operates Tomcat bundles, or policy forbids containers for the application |

In both runtimes PostgreSQL (single mode) and Elasticsearch run as containers with Docker Compose, and every service uses host networking, so Liferay finds them at the same addresses either way.

**Single instance:**

![Single-instance architecture](docs/architecture-single.png)

**High availability:**

![High-availability architecture](docs/architecture-ha.png)

The diagram sources are in [`docs/`](docs/) (Mermaid). After editing one, re-render it with `npx -y @mermaid-js/mermaid-cli -i docs/architecture-ha.mmd -o docs/architecture-ha.png -b white -s 2`.

**Responsibilities when self-hosting:** Liferay supports the DXP image and bundle. Your team owns the AWS account, network, instances, database, search, storage, TLS, DNS, backups, monitoring, patching and secrets.

**Time required:** about 1 hour for single mode the first time, most of it setting up tools and AWS access (sections 3 and 4). In testing, `terraform apply` took 3.5 minutes and the instance bootstrap under 5 minutes. High availability adds 15 to 20 minutes for RDS Multi-AZ.

---

## 2. Prerequisites

> ✅ **Tested on 22 October 2026** with an AWS account in Asia Pacific (Tokyo) and a DXP Development activation key.

### 2.1 AWS account

- An AWS account you may create resources in, with a payment method. A **dedicated sandbox account** (for example from AWS Organizations) is best. A personal account works for a PoC; agree reimbursement in advance and tear down when finished.
- A **budget alert** (Billing → Budgets) at a figure you are comfortable with, so a forgotten stack can't run up a large bill. Tear down when finished (section 15).
- Default service quotas are enough: 1 VPC, 1 Elastic IP (HA mode), 1 ALB, up to 7 vCPUs of standard instances (single) or about 14 (HA). A new account already has the **default VPC**; this guide creates its own VPC next to it and leaves the default one alone.

### 2.2 Region

Pick one region for everything. This guide was tested in **Asia Pacific (Tokyo), `ap-northeast-1`** and uses it in examples. Any commercial region with at least two Availability Zones and `m6i` instances works, for example Singapore (`ap-southeast-1`) or Sydney (`ap-southeast-2`).

### 2.3 Liferay license

- **A Liferay DXP activation key** (XML). The 2026.Q1 LTS images and bundles ship **no trial license**: without a key Liferay never becomes ready.
- **High availability needs a key that allows clustering.** A single-node developer key is not enough for two nodes. Ask your Liferay representative.
- Copy it to `license/license.xml` (see [`license/README.md`](license/README.md)). It is git-ignored; Terraform uploads it to a private S3 bucket.

### 2.4 GitHub

- Access to create repositories (or use the sample workspace) in your GitHub organization, for the CI/CD in section 12.

### Verify

```bash
ls -l license/license.xml                     # your key is in place
grep -c '<license' license/license.xml         # prints 1 or more
git check-ignore license/license.xml           # prints the path: it will never be committed
```

✅ Expected: the file exists, `grep -c` prints 1 or more (a typical key prints `4`: it matches `<license>`, `<license-name>`, `<license-type>` and `<license-version>`), and `git check-ignore` prints `license/license.xml`.

💡 Open the file and check `<license-type>` and `<expiration-date>`. A **developer** key (`DXP Development`) works for single mode; it allows one node and a few concurrent sessions (`<max-http-sessions>`), so it is not enough for high availability (section 9).

---

## 3. Install the command-line tools

> ✅ **Tested on 22 October 2026** on macOS (Apple Silicon) with Homebrew.

| Tool | Version | Purpose |
| --- | --- | --- |
| AWS CLI | v2 (tested: 2.38.4) | Access check, SSM commands, verification |
| Session Manager plugin | current (tested: 1.2.896.0) | Shell on instances without SSH (`aws ssm start-session`) |
| Terraform | 1.9 or later (tested: 1.17.0) | Provision everything |
| jq | any (tested: 1.8.1) | JSON parsing in the scripts |
| GitHub CLI (`gh`) | current (tested: 2.92.0) | Set the workspace's Actions variables (section 12) |
| Git | any (tested: 2.50.1) | Clone the repositories |
| JDK 21 | optional (tested: 21.0.12) | Only to build the sample workspace locally |

### macOS (Homebrew)

Run each line on its own and wait for it to finish:

```bash
brew install awscli jq gh git
brew install --cask session-manager-plugin
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
```

What to expect:

- **`Do you want to proceed with the installation? [y/n]`**: newer Homebrew versions may list what they will install and ask first. Type `y`.
- **`Password:`** while installing `session-manager-plugin`: its installer runs with `sudo`. Type your **Mac login password** in the terminal and press Return. Nothing appears while you type; that is normal. If your Mac account is not an administrator, ask IT to install the plugin; everything except interactive shells on the instances (`aws ssm start-session`) still works without it.
- **Terraform is not in Homebrew's main repository** (licence change), which is why it comes from the `hashicorp/tap`.
- **`Warning: A newer Command Line Tools release is available`**: harmless for this guide. Update from **System Settings → General → Software Update** when convenient.

### Linux / WSL 2

Install the [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), [Terraform](https://developer.hashicorp.com/terraform/install), jq and the [GitHub CLI](https://cli.github.com/) from their official packages.

### Verify

```bash
aws --version                  # aws-cli/2.x
session-manager-plugin --version
terraform version              # 1.9 or later
jq --version
gh --version
git --version
```

✅ Expected: every command prints a version; none says `command not found`. Tested output:

```text
aws-cli/2.38.4 Python/3.15.0 Darwin/25.5.0 source/arm64
1.2.896.0
Terraform v1.17.0
jq-1.8.1
gh version 2.92.0 (2026-04-28)
git version 2.50.1 (Apple Git-155)
```

---

## 4. Set up AWS access

> ✅ **Tested on 22 October 2026** in Asia Pacific (Tokyo) with an IAM user and an access key (4.2 Option A, 4.3 Option A).

Two identities are used:

- **The root user** (the email address the account was created with), only for one-off account tasks: MFA, billing and budgets, and creating the PoC user if nobody else can.
- **A PoC identity** for everything else, from the console or the CLI: an IAM user (Option A) or an IAM Identity Center user (Option B).

**Which option?** If you sign in to the AWS console with an **account ID or alias, a user name and a password**, or you only have the root user, use **Option A**. If you sign in through an **access portal** (`https://<something>.awsapps.com/start`, often from an Okta, Google or Microsoft tile), your company uses IAM Identity Center: use **Option B**. Not sure? Search your email for "AWS IAM Identity Center" or "Invitation to join"; if you find nothing, use Option A.

### 4.1 Secure the root user

Signed in as the account's **root user**: turn on **MFA**, create **no access keys**, and set the budget alert from section 2.1. Use the root user for nothing else.

### 4.2 Create the PoC identity

Both options need the same permissions: the AWS managed policy **`PowerUserAccess`** (everything except IAM) **plus** this inline policy, which lets Terraform create only this stack's two IAM roles (`liferay-poc-instance`, `liferay-poc-github-actions`), its instance profile and the GitHub OIDC provider. If you will use another stack `name` (section 5), replace `liferay-poc` here to match.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageStackRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::*:role/liferay-poc-*",
        "arn:aws:iam::*:instance-profile/liferay-poc-*"
      ]
    },
    {
      "Sid": "PassInstanceRoleToEc2Only",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/liferay-poc-instance",
      "Condition": { "StringEquals": { "iam:PassedToService": "ec2.amazonaws.com" } }
    },
    {
      "Sid": "ManageGitHubOidcProvider",
      "Effect": "Allow",
      "Action": [
        "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider"
      ],
      "Resource": "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com"
    },
    {
      "Sid": "ListForChecks",
      "Effect": "Allow",
      "Action": ["iam:ListRoles", "iam:ListOpenIDConnectProviders"],
      "Resource": "*"
    }
  ]
}
```

- `iam:PassRole` is limited to the instance role and to EC2, so this identity can't hand any other role to any service. Don't widen it to `"Resource": "*"`: the IAM console warns that PassRole on a wildcard is overly permissive, and it is right.
- The two list actions stay on `*` because AWS doesn't support narrowing them; they are read-only and used by the access check (4.4).
- Avoid `AdministratorAccess`, especially in shared or personal accounts.

#### Option A: IAM user with an access key (tested)

Signed in as the **root user** (or an administrator), open **IAM → Users → Create user**:

1. **User name:** `liferay-poc`. Leave **Provide user access to the AWS Management Console** unticked unless a person needs the console (then require MFA).
2. **Permissions:** **Attach policies directly** → tick **`PowerUserAccess`** → **Next** → **Create user**.
3. Open the user → **Permissions** → **Add permissions** → **Create inline policy** → **JSON**. Replace the contents with the policy above → **Next** → name it **`liferay-poc-iam`** → **Create policy**.
4. **Security credentials** tab → **Create access key** → use case **Command Line Interface (CLI)** → tick the confirmation → **Next** → **Create access key**.
5. The **secret access key is shown once only**. Keep the page open, or **Download .csv file** and store it in a password manager. Never paste it into chat, email, documents, tickets or Git. If you lose it, create a new access key and **deactivate and delete** the old one.

#### Option B: IAM Identity Center

In **IAM Identity Center**, create a user, then a **permission set** with the managed policy `PowerUserAccess` and the inline policy above, and assign the user and permission set to the PoC account. The user receives an invitation email with the **AWS access portal URL** (`https://<something>.awsapps.com/start`); you need it in 4.3.

### 4.3 Configure the CLI

Run this in **your own terminal** (not in a shared screen or chat).

#### Option A: IAM user

```bash
aws configure --profile liferay-poc
```

| Prompt | Value |
| --- | --- |
| `AWS Access Key ID` | From 4.2 step 5 (starts with `AKIA`) |
| `AWS Secret Access Key` | From 4.2 step 5 |
| `Default region name` | Your PoC region, for example `ap-northeast-1` (Tokyo) |
| `Default output format` | `json` |

Notes from testing:

- Recent CLI versions print **`Tip: You can deliver temporary credentials ... by running the command 'aws login'`** first. Ignore it; the access key is what this guide uses.
- Recent CLI versions may finish with **`Configure AWS skills and the AWS MCP server for your AI coding agent(s)? [y/n/never]`**. Answer **`n`** (or `never` to stop the question). It is an optional add-on that changes your AI tools' configuration; nothing in this guide needs it. The profile is already saved when the question appears.
- The CLI stores the key in `~/.aws/credentials`, readable only by your user. Treat that file as a secret.

#### Option B: IAM Identity Center

```bash
aws configure sso --profile liferay-poc
```

| Prompt | Value |
| --- | --- |
| `SSO session name` | `liferay-poc` (a local label) |
| `SSO start URL` | Your AWS access portal URL from 4.2 Option B |
| `SSO region` | The region your Identity Center lives in (ask your AWS administrator; often `us-east-1`) |
| `SSO registration scopes` | Press Return for the default |
| *(browser opens)* | Approve the request, then pick the **account** and the **role** (permission set) |
| `Default client Region` | Your PoC region, for example `ap-northeast-1` |
| `CLI default output format` | `json` |

If you don't have a portal URL, your organization doesn't use Identity Center: press **Ctrl+C** and use Option A. The SSO login lasts a few hours; renew it with `aws sso login --profile liferay-poc`.

#### Both options

Select the profile and region for the whole terminal session:

```bash
export AWS_PROFILE=liferay-poc
export AWS_REGION=ap-northeast-1
```

### 4.4 Verify access

Run the read-only check. It creates nothing and costs nothing:

```bash
scripts/check-aws-access.sh ap-northeast-1
```

✅ Expected: the identity is your IAM user or Identity Center role (**not** `root`), every service shows **OK**, and the last line is `All services reachable`. Tested output (Option A, a new account):

```text
Identity:
{
    "UserId": "AIDA...",
    "Account": "<account-id>",
    "Arn": "arn:aws:iam::<account-id>:user/liferay-poc"
}

OK    Region ap-northeast-1        3
OK    EC2                          0
OK    VPC quota (VPCs in use)      1
OK    Elastic IPs in use           0
OK    Load balancers (ELBv2)       0
OK    RDS                          0
OK    EFS                          0
OK    S3                           0
OK    ECR                          0
OK    SSM                          0
OK    IAM (roles)                  3
OK    IAM (OIDC providers)         0
OK    ACM                          0
OK    AL2023 AMI parameter         ami-0cef3c44c19f4cfec

GitHub OIDC provider already in this account (set create_github_oidc_provider = false if listed):
  none

All services reachable
```

The numbers are counts of what already exists: `Region` shows the number of Availability Zones (Tokyo has 3), `VPC ... 1` is the default VPC, and `IAM (roles) 3` are AWS service-linked roles. The AMI ID differs by region and date. If a GitHub OIDC provider **is** listed, set `create_github_oidc_provider = false` in section 5.

| Result | Cause | Fix |
| --- | --- | --- |
| `No valid AWS credentials` / `InvalidClientTokenId` | Wrong or deleted access key, or wrong profile | Check `AWS_PROFILE`; create a new access key (4.2 step 4) and re-run 4.3 |
| `ExpiredToken` / `Token has expired` (Option B) | SSO session expired | `aws sso login --profile liferay-poc` |
| Identity ARN ends in `:root` | Using root credentials | Stop; create the PoC identity (4.2) and delete the root access key |
| `AccessDenied` / `UnauthorizedOperation` on one service | Missing permission | Check `PowerUserAccess` is attached (4.2) |
| IAM rows fail with `AccessDenied` | `PowerUserAccess` alone excludes IAM | Add the inline policy from 4.2 |
| `Could not connect to the endpoint URL` | Region typo or region not enabled | Check `AWS_REGION`; enable opt-in regions in the account settings |

---

## 5. Choose your options

> ✅ **Tested on 22 October 2026** in Asia Pacific (Tokyo): single mode, Docker runtime, Terraform 1.17.0 with the AWS provider 6.69.1 and the random provider 3.9.1.

Run every command from here on from the **repository root** (`lfrgs-sh-aws-ec2-tutorial/`), in a terminal where `AWS_PROFILE` and `AWS_REGION` are exported (section 4.3; export them again in every new terminal). Terraform commands use `-chdir=terraform`, so you never need to `cd`.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`. The important settings:

| Variable | Example | Notes |
| --- | --- | --- |
| `region` | `ap-northeast-1` | Same as `AWS_REGION` |
| `name` | `liferay-poc` | Stack name: prefixes resources, tags instances `LiferayStack=<name>`, names SSM parameters `/<name>/...` |
| `deployment_mode` | `single` or `ha` | Section 1 |
| `liferay_runtime` | `docker` or `tomcat` | Section 1 |
| `liferay_version` | `2026.q1.13-lts` | Image tag `liferay/dxp:<version>` and the Tomcat bundle. Latest promoted release in <https://releases.liferay.com/releases.json> |
| `elasticsearch_version` | `8.19.20` | The sidecar version DXP 2026.Q1.13 ships with |
| `allowed_cidrs` | `["203.0.113.10/32"]` | Who can open Liferay. Find your IP with `curl -s https://checkip.amazonaws.com` and add `/32`. If your IP changes (another network, VPN), update it and `terraform -chdir=terraform apply` |
| `license_file` | `../license/license.xml` | Uploaded to S3 by Terraform |
| `github_repository` | `LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace` | Repository allowed to deploy (section 12). Empty skips the CI/CD role |
| `create_github_oidc_provider` | `true` | `false` if the account already has one (section 4.4) |
| `acm_certificate_arn`, `virtual_host` | empty | HTTPS and your own domain, section 10 |
| `liferay_node_count`, `liferay_heap`, `elasticsearch_heap`, `db_instance_class` | `2`, `6g`, `2g`, `db.m6g.large` | HA sizing. With HA, raise `liferay_heap` to `8g` (Liferay has the instance to itself) |
| `force_destroy` | `true` | Lets `terraform destroy` delete the bucket, ECR images and RDS without a final snapshot. **Set to `false` for anything you want to keep** |

> 💡 **Remote state:** Terraform keeps state, including the generated passwords, in `terraform/terraform.tfstate` by default. For a shared PoC, store it in an encrypted, private S3 bucket with a [`backend "s3"`](https://developer.hashicorp.com/terraform/language/backend/s3) block instead, and never commit it (it is in `.gitignore`).

### Verify

```bash
terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=liferay.tfplan
```

✅ Expected:

- `init`: `Installed hashicorp/aws v6.x` and `Installed hashicorp/random v3.x` (both `signed by HashiCorp`), then `Terraform has been successfully initialized!`. The versions come from the committed `.terraform.lock.hcl`.
- `validate`: `Success! The configuration is valid.`
- `plan`: ends with **`Plan: 58 to add, 0 to change, 0 to destroy.`** in single mode (tested). HA adds RDS, EFS, the NAT gateway, the search instance and their security groups, about 80 in total (🔎 not yet tested).

Read the plan before applying. In single mode it should contain:

- `aws_instance.liferay[0]` with `instance_type = "m6i.xlarge"`, and no `aws_instance.search`, `aws_db_instance` or `aws_nat_gateway`;
- `aws_s3_object.license[0]` (if it is missing, `license_file` was not found);
- 13 `aws_s3_object.host_files[...]` (the files under `host/`);
- `aws_vpc_security_group_ingress_rule.alb_http["<your-ip>/32"]`: only your IP can reach the load balancer.

---

## 6. Provision the infrastructure

> ✅ **Tested on 22 October 2026** in Asia Pacific (Tokyo), single mode.

```bash
terraform -chdir=terraform apply liferay.tfplan
```

Applying a saved plan doesn't ask for confirmation. Single mode took **3 minutes 25 seconds** in testing (`Apply complete! Resources: 58 added, 0 changed, 0 destroyed.`); HA takes 15 to 20 minutes, mostly RDS Multi-AZ. Terraform returns once the AWS resources exist; the instances keep bootstrapping for a few more minutes (section 7). From this point the stack is billed until you tear it down (section 15).

What gets created:

| Resource | Single | HA |
| --- | --- | --- |
| VPC, 2 public and 2 private subnets in 2 AZs, internet gateway, S3 gateway endpoint | ✔ | ✔ |
| NAT gateway and Elastic IP | | ✔ |
| Security groups: ALB (80/443 from `allowed_cidrs`), Liferay (8080 from the ALB; 7800-7801 between nodes in HA), search (9200 from Liferay), RDS (5432 from Liferay), EFS (2049 from Liferay) | ✔ | ✔ |
| ALB, target group (health check `/c/portal/robots`, sticky sessions), HTTP listener (HTTPS when a certificate is set) | ✔ | ✔ |
| Liferay EC2 instances (Amazon Linux 2023, IMDSv2 only, encrypted gp3) | 1 | `liferay_node_count` |
| Elasticsearch EC2 instance | | 1 |
| RDS for PostgreSQL 16 Multi-AZ, encrypted, 7-day backups | | ✔ |
| EFS (encrypted, automatic backups) with mount targets in both AZs | | ✔ |
| S3 artifact bucket (private, encrypted, versioned): `host/`, `license/`, `builds/` | ✔ | ✔ |
| ECR repository `<name>/dxp-custom` (scan on push, keeps 20 images) | ✔ | ✔ |
| SSM parameters `/<name>/db/password` and `/<name>/liferay/admin-password` (SecureString, random) | ✔ | ✔ |
| IAM instance role (SSM, ECR read, the bucket, the stack's parameters) | ✔ | ✔ |
| GitHub OIDC provider and the GitHub Actions role (ECR push, `builds/` upload, SSM Run Command on this stack's instances only) | ✔ | ✔ |

### Verify

```bash
terraform -chdir=terraform output
```

✅ Expected (single mode, tested; `<account-id>` is your 12-digit account ID):

```text
admin_password_command = "aws ssm get-parameter --name /liferay-poc/liferay/admin-password --with-decryption ..."
alb_dns_name = "liferay-poc-<number>.ap-northeast-1.elb.amazonaws.com"
artifact_bucket = "liferay-poc-artifacts-<account-id>-ap-northeast-1"
db_endpoint = "127.0.0.1 (container on the Liferay instance)"
deployment = "single / docker"
ecr_repository_url = "<account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/liferay-poc/dxp-custom"
github_actions_role_arn = "arn:aws:iam::<account-id>:role/liferay-poc-github-actions"
github_variables_commands = <<EOT
gh variable set AWS_REGION --repo ... (six commands, used in section 12)
EOT
license_uploaded = true
liferay_instance_ids = [
  "i-...",
]
liferay_url = "http://liferay-poc-<number>.ap-northeast-1.elb.amazonaws.com"
stack_name = "liferay-poc"
```

`license_uploaded` must be `true`. In HA mode `db_endpoint` is an `rds.amazonaws.com` name, and `efs_id` and `search_instance_id` are set.

✅ Every instance is running and registered with Systems Manager (in testing it was `Online` by the time the apply finished; allow up to 3 minutes):

```bash
STACK=$(terraform -chdir=terraform output -raw stack_name)

aws ec2 describe-instances \
  --filters "Name=tag:LiferayStack,Values=${STACK}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value, InstanceId, PrivateIpAddress, Placement.AvailabilityZone]' \
  --output table

aws ssm describe-instance-information \
  --filters "Key=tag:LiferayStack,Values=${STACK}" \
  --query 'InstanceInformationList[].[InstanceId, PingStatus, PlatformName]' --output table
```

Every instance shows `Online` and `Amazon Linux`. Tested output, single mode:

```text
|  liferay-poc-liferay-1 |  i-...  |  10.20.1.14 |  ap-northeast-1a |
|  i-...  |  Online  |  Amazon Linux  |
```

In HA mode, the Liferay nodes are in **two different** Availability Zones.

✅ The host files and license reached S3:

```bash
aws s3 ls "s3://$(terraform -chdir=terraform output -raw artifact_bucket)/" --recursive | grep -E 'host/scripts/bootstrap.sh|license/license.xml'
```

Expected: two lines, `host/scripts/bootstrap.sh` and `license/license.xml` (the size of your key file).

✅ HA only: RDS is Multi-AZ and EFS is available:

```bash
aws rds describe-db-instances --db-instance-identifier "${STACK}" \
  --query 'DBInstances[0].[DBInstanceStatus, MultiAZ, Engine, EngineVersion, AvailabilityZone, SecondaryAvailabilityZone]' --output text
aws efs describe-file-systems --file-system-id "$(terraform -chdir=terraform output -raw efs_id)" \
  --query 'FileSystems[0].[LifeCycleState, NumberOfMountTargets, Encrypted]' --output text
```

Expected `available  True  postgres  16.x  <az-a>  <az-b>` and `available  2  True`.

---

## 7. How each instance is bootstrapped

> ✅ **Tested on 22 October 2026** in Asia Pacific (Tokyo), single mode with the Docker runtime: the bootstrap finished **4 minutes 39 seconds** after the instance booted, with no warnings or errors in its log.

Nothing in this section needs to be typed except the checks: it explains what runs on each instance and how to watch it.

1. **User data** ([`terraform/templates/user-data.sh.tftpl`](terraform/templates/user-data.sh.tftpl)) writes `/etc/liferay-ec2/host.env`: the stack name, mode, role (`liferay` or `search`), runtime, database and search addresses, versions and heap sizes. No secrets.
2. It copies `s3://<artifact-bucket>/host/` (this repository's `host/` folder) to `/opt/liferay-ec2` and runs [`bootstrap.sh`](host/scripts/bootstrap.sh).
3. **`bootstrap.sh`** installs Docker and the Compose plugin (Amazon Linux 2023's `docker` package doesn't include Compose, so it is downloaded from Docker's GitHub releases), sets `vm.max_map_count=262144` where Elasticsearch runs, mounts EFS (HA Liferay nodes), and calls **[`render-config.sh`](host/scripts/render-config.sh)**, which:
   - reads the database and admin passwords from SSM Parameter Store;
   - writes `/opt/liferay-ec2/runtime/files/portal-ext.properties` (JDBC, admin password, proxy headers, HTTPS, virtual host, and Cluster Link in HA);
   - writes the Elasticsearch 8 OSGi config (`networkHostAddresses`, `productionModeEnabled`);
   - writes the JGroups files (HA) and copies the license from S3 into `files/deploy/license.xml`;
   - writes `/opt/liferay-ec2/docker/.env` for Compose.
4. It builds the Elasticsearch image with the analysis plugins (where needed), starts PostgreSQL and Elasticsearch, then Liferay: `docker compose up -d liferay` (Docker runtime; the image copies `/etc/liferay/mount/files` into `/opt/liferay` at startup), or installs the Tomcat bundle and starts the `liferay` service (Tomcat runtime; `ExecStartPre` copies the same files into `/opt/liferay`).
5. It waits until `http://127.0.0.1:8080/c/portal/robots` returns 200 (the ALB health check), then writes `/opt/liferay-ec2/runtime/bootstrap.done`.

What it looked like in testing (single mode, Docker runtime; times in UTC from `/var/log/liferay-ec2-bootstrap.log`):

| Time | Elapsed | Step |
| --- | --- | --- |
| 03:41:00 | 0:00 | Instance boots |
| 03:41:05 | 0:05 | `Bootstrapping liferay-poc: mode=single role=liferay runtime=docker` |
| 03:41:48 | 0:48 | `Installing Docker Compose v5.6.1` |
| 03:41:51 | 0:51 | `Rendering configuration`, `License copied from s3://...`, `Configuration rendered (profiles: liferay db search)` |
| 03:41:51 | 0:51 | `Building liferay-elasticsearch:8.19.20` (about 1 minute) |
| 03:42:47 | 1:47 | `Starting postgres elasticsearch` (both healthy within 25 seconds) |
| 03:43:11 | 2:11 | `Starting Liferay container liferay/dxp:2026.q1.13-lts` (image pull included) |
| 03:45:39 | 4:39 | `Liferay is ready`, `Bootstrap finished` |

The rendered files on the instance (single mode; HA adds `files/jgroups/control.xml` and `transport.xml`):

```text
/opt/liferay-ec2/runtime/bootstrap.done
/opt/liferay-ec2/runtime/files/deploy/license.xml
/opt/liferay-ec2/runtime/files/osgi/configs/com.liferay.portal.search.elasticsearch8.configuration.ElasticsearchConfiguration.config
/opt/liferay-ec2/runtime/files/portal-ext.properties
/opt/liferay-ec2/docker/.env
```

> 💡 **Why the files belong to `ec2-user`:** they are owned by UID 1000, the user the Liferay container (and the Tomcat runtime's `liferay` user) runs as. On Amazon Linux 2023, UID 1000 is also the default `ec2-user` account, so `ls -l` shows `ec2-user`. `portal-ext.properties` and `.env` contain the database password: SSM sessions run as `ssm-user` and need `sudo` to read them, but anyone who logs in as `ec2-user` can. Don't add SSH keys for `ec2-user`; for production, consider a dedicated UID.

Every step is safe to run again. After changing the host files (or `host.env`), re-sync and re-run on every instance:

```bash
scripts/run-on-stack.sh "${STACK}" all \
  'aws s3 sync s3://'"$(terraform -chdir=terraform output -raw artifact_bucket)"'/host/ /opt/liferay-ec2/ --only-show-errors && chmod 755 /opt/liferay-ec2/scripts/*.sh && /opt/liferay-ec2/scripts/bootstrap.sh'
```

### Watch it

Open a shell on an instance (no SSH needed):

```bash
aws ssm start-session --target "$(terraform -chdir=terraform output -json liferay_instance_ids | jq -r '.[0]')"
sudo tail -f /var/log/liferay-ec2-bootstrap.log
```

### Verify

```bash
scripts/run-on-stack.sh "${STACK}" all 'tail -3 /var/log/liferay-ec2-bootstrap.log; cat /opt/liferay-ec2/runtime/bootstrap.done'
```

✅ Expected on each instance (tested output):

```text
--- liferay-poc-liferay-1 (i-...): Success
Waiting up to 1800s for http://127.0.0.1:8080/c/portal/robots ...
Liferay is ready
[liferay-ec2 03:45:39] Bootstrap finished. Check this instance with: sudo /opt/liferay-ec2/scripts/verify-node.sh
2026-10-22T03:45:39Z
```

✅ The containers are up and healthy (single mode, Docker runtime):

```bash
scripts/run-on-stack.sh "${STACK}" all 'docker ps --format "{{.Names}} {{.Status}}"'
```

Expected `liferay Up ... (healthy)`, `postgres Up ... (healthy)` and `elasticsearch Up ... (healthy)`.

✅ The log has no warnings or errors:

```bash
scripts/run-on-stack.sh "${STACK}" all 'grep -ciE "warn|error|fail" /var/log/liferay-ec2-bootstrap.log || true'
```

Expected `0` (the `|| true` stops `grep` from reporting a clean log as a failure). If a check shows `Failed`, an instance shows `ERROR:`, or the log stops growing, see section 16. If `bootstrap.done` is missing after 20 minutes, read the full log with `tail -100 /var/log/liferay-ec2-bootstrap.log`.

---

## 8. Single instance: start Liferay

> Applies to `deployment_mode = "single"`. For HA, go to section 9.

> ✅ **Tested on 22 October 2026** in Asia Pacific (Tokyo) with the Docker runtime: all `verify-node.sh` checks pass, the site loads through the load balancer, `test@liferay.com` signs in, and search returns results. The Tomcat runtime (8.3) is not yet tested.

### 8.1 What is running

| Service | Docker runtime | Tomcat runtime |
| --- | --- | --- |
| Liferay DXP | Container `liferay` (`liferay/dxp:2026.q1.13-lts`), host network, port 8080 | systemd service `liferay`, `/opt/liferay/tomcat`, port 8080 |
| PostgreSQL 16 | Container `postgres`, `127.0.0.1:5432`, volume `liferay_postgres-data` | Same |
| Elasticsearch 8.19 | Container `elasticsearch`, `127.0.0.1:9200`, volume `liferay_elasticsearch-data` | Same |
| Documents and Media | `/var/lib/liferay-ec2/document_library` (bind mount) | Same (symlink from `/opt/liferay/data/document_library`) |

PostgreSQL and Elasticsearch listen on `127.0.0.1` only; the security group lets only the ALB reach port 8080.

**Host names Liferay accepts.** Liferay answers **HTTP 500** to any request whose `Host` header is not in `virtual.hosts.valid.hosts`, and its default list is only `localhost`, `127.0.0.1`, `[::1]` and `[0:0:0:0:0:0:0:1]`. Behind the ALB two other host names arrive: the **ALB DNS name** (browsers) and the **instance's private IP** (ALB health checks). `render-config.sh` therefore writes:

```properties
virtual.hosts.valid.hosts=localhost,127.0.0.1,[::1],[0:0:0:0:0:0:0:1],<instance-private-ip>,<alb-dns-name>[,<virtual_host>]
```

The ALB DNS name reaches the instance as `ALB_DNS_NAME` in `host.env`, and `virtual_host` is added once you set it (section 10). Without this line the target stays `unhealthy` (`Health checks failed with these codes: [500]`) and every page returns 500, while Liferay looks perfectly healthy from the instance itself. Don't use `virtual.hosts.valid.hosts=*`: it works, but it turns off Liferay's protection against forged `Host` headers.

Useful commands on the instance (`aws ssm start-session`, then `sudo -i`):

```bash
cd /opt/liferay-ec2/docker && docker compose ps     # all containers and their health
/opt/liferay-ec2/scripts/liferay-log.sh -f          # Liferay log, either runtime
journalctl -u liferay -f                             # Tomcat runtime: service events
cat /opt/liferay-ec2/runtime/files/portal-ext.properties   # contains the DB password: do not share
```

### 8.2 First start

The bootstrap waits for Liferay, so once section 7's check shows `Bootstrap finished`, Liferay is up. In testing the first start (database creation and index set-up) took about 2.5 minutes on an `m6i.xlarge` (`Server startup in [88997] milliseconds`), and a restart about 40 seconds. Open the URL:

```bash
terraform -chdir=terraform output -raw liferay_url
```

Only the IPs in `allowed_cidrs` can open it, over plain HTTP until section 10 (browsers show "Not secure"; that is expected for now).

Sign in as **`test@liferay.com`** with the generated password. Print it **in your own terminal** rather than pasting it into chat or documents:

```bash
$(terraform -chdir=terraform output -raw admin_password_command)
```

Click **Sign In**, enter `test@liferay.com` and the 20-character password. Liferay may ask you to accept the terms of use and set a new password; store the new one in your password manager. The value in SSM Parameter Store doesn't change, and Liferay only uses it when the database is first created.

### 8.3 Tomcat runtime details

With `liferay_runtime = "tomcat"`, [`install-tomcat-bundle.sh`](host/scripts/install-tomcat-bundle.sh):

1. installs **Amazon Corretto 21** (`java-21-amazon-corretto-headless`);
2. reads `bundle.url` from `https://releases-cdn.liferay.com/dxp/<version>/release.properties`, downloads the `.tar.gz` bundle and **checks its SHA-512**;
3. extracts it into `/opt/liferay` (owned by the `liferay` user, UID 1000) and links the versioned Tomcat folder to `/opt/liferay/tomcat`;
4. appends the heap setting to `tomcat/bin/setenv.sh` and installs [`liferay.service`](host/systemd/liferay.service).

To move to a newer DXP release on the Tomcat runtime, change `liferay_version`, `terraform apply`, edit `LIFERAY_VERSION` in `/etc/liferay-ec2/host.env` (or replace the instance), and re-run the bootstrap. 🔎 For a real upgrade, follow Liferay's upgrade guide (database upgrade tool) rather than swapping bundles.

### Verify

```bash
scripts/run-on-stack.sh "${STACK}" liferay 'sudo /opt/liferay-ec2/scripts/verify-node.sh'
```

✅ Expected (Docker runtime; the Tomcat runtime shows `Liferay service` and `Liferay bundle version` instead of the container lines):

```text
PASS  Bootstrap finished
PASS  Docker running                     active
PASS  PostgreSQL container               running healthy
PASS  PostgreSQL accepts connections     127.0.0.1:5432 - accepting connections
PASS  Elasticsearch container            running healthy
PASS  Elasticsearch cluster health       status green, 1 node(s)
PASS  Elasticsearch analysis plugins     analysis-icu analysis-kuromoji analysis-smartcn analysis-stempel
PASS  vm.max_map_count >= 262144         262144
PASS  Liferay container                  running healthy
PASS  Liferay image                      liferay/dxp:2026.q1.13-lts
PASS  Database reachable                 127.0.0.1:5432 reachable
PASS  Elasticsearch reachable            status green, 1 node(s)
PASS  Liferay HTTP on 8080               HTTP 200 from http://127.0.0.1:8080/c/portal/robots
PASS  Accepts ALB health-check host      HTTP 200 from http://127.0.0.1:8080/c/portal/robots (Host: 10.20.1.14)
PASS  Accepts ALB host name              HTTP 200 from http://127.0.0.1:8080/c/portal/robots (Host: liferay-poc-<n>.ap-northeast-1.elb.amazonaws.com)
PASS  Server started                     ... Catalina.start Server startup in [88997] milliseconds
PASS  License registered                 ... License registered for DXP Development
PASS  No license errors                  none found
PASS  Documents and Media writable       /dev/nvme0n1p1 9% used

All checks passed
```

After a restart, `License registered` shows `DXP Development license validation passed` instead; both mean the key is active.

✅ The load balancer sees the instance as healthy:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(aws elbv2 describe-target-groups --names "${STACK}-liferay" --query 'TargetGroups[0].TargetGroupArn' --output text)" \
  --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State, TargetHealth.Reason]' --output text
```

Expected `i-...  healthy  None`.

✅ The site loads through the load balancer, with its CSS:

```bash
URL=$(terraform -chdir=terraform output -raw liferay_url)
curl -s -o /dev/null -w 'robots: %{http_code}\n' "${URL}/c/portal/robots"
curl -sL "${URL}/" | grep -o '<title>[^<]*</title>'
```

Expected `robots: 200` and `<title>Home - Liferay DXP</title>`. In the browser the home page has the Liferay theme (not unstyled text).

✅ Search works. The Liferay indexes exist and are green, and a guest search through the load balancer finds content:

```bash
scripts/run-on-stack.sh "${STACK}" liferay 'curl -s "http://127.0.0.1:9200/_cat/indices?h=health,index,docs.count&s=index" | head -3'
curl -sL "${URL}/search?q=liferay" | grep -oE '[0-9]+ Results? for'
```

Expected `green liferay-<company-id> <documents>` among the indexes (about 480 documents on a new site), and `2 Results for`. In the browser, **Control Panel → System → Search** shows an active connection to Elasticsearch 8.19.

✅ Sign-in is recorded. After you sign in:

```bash
scripts/run-on-stack.sh "${STACK}" liferay "docker exec postgres psql -U liferay -d lportal -At -F ' | ' -c \"select emailaddress, logindate, passwordreset from user_ where emailaddress = 'test@liferay.com';\""
```

Expected `test@liferay.com | <the time you signed in, UTC> | f`.

### What else to expect in the log

Seen in testing; none of them stops the PoC:

| Log line | Meaning | What to do |
| --- | --- | --- |
| `java.lang.RuntimeException: Invalid host name ...` with `{code="500", ...}` | A `Host` header not in `virtual.hosts.valid.hosts` | Expected only for stacks created before the fix (section 16). Otherwise check `ALB_DNS_NAME` in `/etc/liferay-ec2/host.env` |
| `NullPointerException: ... "liveGroup" is null` at `PasswordModifiedFilter.processFilter`, once, right after a start | A request arrived while Liferay was still initializing the site | Ignore if it doesn't repeat. 🔎 |
| `Email test@domain.invalid will be ignored because it is included in blacklist` and `Skipping email because the sender is not specified` | No mail server configured, so notification emails (password changes, invitations, workflow) are skipped | Fine for a PoC. Configure SMTP, for example Amazon SES, before real users rely on email (section 14) |

> ⚠️ **Liferay records the load balancer's IP, not the user's.** In testing, `user_.loginip` was `10.20.7.37`, an internal ALB address, because Liferay and Tomcat ignore the ALB's `X-Forwarded-For` header by default. Login history, audit events and IP-based rules all see the ALB. For production, configure Tomcat's `RemoteIpValve` (or the equivalent Liferay setting for your release) to trust the ALB's subnets. 🔎 Not yet done in this guide.

---

## 9. High availability

> Applies to `deployment_mode = "ha"`.

### 9.1 Database: RDS for PostgreSQL Multi-AZ

All nodes share one RDS instance (`db_endpoint`). RDS keeps a synchronous standby in the other Availability Zone and fails over automatically; Liferay reconnects through the same DNS name. Backups are kept 7 days. `rds.force_ssl` is `0` so the default JDBC URL works; for production, add `?sslmode=require` to the URL in `render-config.sh` and set `rds.force_ssl = 1`.

### 9.2 Documents and Media: EFS

Every Liferay node mounts the same EFS file system at `/mnt/efs` (TLS in transit) and uses `/mnt/efs/document_library` as Liferay's default file system store. An upload on one node is visible on every other node immediately. EFS automatic backups are on.

> 🔎 **Alternative:** Liferay's S3 store (`com.liferay.portal.store.s3.S3Store`) puts Documents and Media in S3 instead of EFS. It scales further and costs less at volume, but needs its own OSGi configuration and a data migration if you switch later. This guide uses EFS because it behaves the same for the Docker and Tomcat runtimes.

### 9.3 Search: Elasticsearch on its own instance

One `m6i.large` instance runs the same Elasticsearch container, listening on port 9200 for the Liferay security group only. Liferay nodes connect to `http://<search-private-ip>:9200`. This is a single point of failure for search (not for the site): if it stops, pages still load but search and some admin screens fail until it is back. For production, run a three-node cluster (section 14).

### 9.4 Cluster Link: TCP unicast with JDBC_PING

Liferay nodes must exchange cache invalidations and coordinate scheduled jobs. Liferay's default Cluster Link uses **UDP multicast, which AWS VPCs do not support**, so this guide switches to TCP unicast:

- `portal-ext.properties` (rendered on each node):

  ```properties
  cluster.link.enabled=true
  cluster.link.autodetect.address=<rds-endpoint>:5432
  cluster.link.channel.properties.control=/opt/liferay/jgroups/control.xml
  cluster.link.channel.properties.transport.0=/opt/liferay/jgroups/transport.xml
  ```

- [`jgroups-tcp-jdbc-ping.xml`](host/config/jgroups-tcp-jdbc-ping.xml) is Liferay's own JGroups stack with `UDP` replaced by `TCP` (bound to the node's private IP, port 7800 for control and 7801 for transport) and `PING` replaced by **`JDBC_PING`**, which keeps the member list in a `JGROUPSPING` table in the shared PostgreSQL database. No extra infrastructure, and it works the same in Docker (host network) and Tomcat.
- The Liferay security group allows 7800-7801 between Liferay nodes only.

> 🔎 **Verify** the JGroups version bundled in your DXP release: the stack is copied from Liferay's `udp_control.xml` for JGroups 5.x. If a protocol name is rejected at startup, take `udp_control.xml` from the `com.liferay.portal.cluster.multiple` module of your release and apply the same two substitutions.

### 9.5 Load balancer and sessions

The ALB spreads users across nodes with **sticky sessions** (`lb_cookie`, 1 day): Liferay does not replicate HTTP sessions, so a user stays on one node. If that node stops, the user moves to another node and must sign in again. Deployments (section 12) restart one node at a time and wait for it to be healthy before moving to the next.

### Verify

1. Every instance passes its checks:

   ```bash
   scripts/run-on-stack.sh "${STACK}" all 'sudo /opt/liferay-ec2/scripts/verify-node.sh'
   ```

   ✅ Expected: `All checks passed` on every Liferay node (including `EFS mounted` and `Cluster members = 2`) and on the search node (`Elasticsearch cluster health ... green`, the four plugins).

2. The nodes see each other in the cluster (`verify-node.sh` already checks this as `Cluster members = N`):

   ```bash
   scripts/run-on-stack.sh "${STACK}" liferay \
     "/opt/liferay-ec2/scripts/liferay-log.sh | grep -oE 'view \[[^]]*\] \([0-9]+\)' | tail -2"
   ```

   ✅ Expected: the latest view on each node has **as many members as `liferay_node_count`**, for example `view [ip-10-20-128-10-12345|1] (2)`. A view of `(1)` on each node means they did not find each other (section 16). 🔎 Verify the exact log wording on your release.

3. The discovery table is populated:

   ```bash
   aws ssm start-session --target "$(terraform -chdir=terraform output -json liferay_instance_ids | jq -r '.[0]')"
   sudo docker run --rm --network host postgres:16 \
     psql "postgresql://liferay:$(sudo bash -c 'source /opt/liferay-ec2/scripts/common.sh && get_secret db/password')@$(grep DB_HOST /etc/liferay-ec2/host.env | cut -d= -f2)/lportal" \
     -c 'select cluster_name, own_addr from jgroupsping;'
   ```

   ✅ Expected: one row per node for each of the two channels.

4. Both nodes are healthy behind the ALB:

   ```bash
   aws elbv2 describe-target-health \
     --target-group-arn "$(aws elbv2 describe-target-groups --names "${STACK}-liferay" --query 'TargetGroups[0].TargetGroupArn' --output text)" \
     --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State]' --output text
   ```

   ✅ Expected: every node `healthy`.

5. **Failover test.** Stop Liferay on the node you are using and reload the page:

   ```bash
   scripts/run-on-stack.sh "${STACK}" liferay 'hostname'   # note the node names
   # in a browser, the page footer shows the serving node (web.server.display.node, from the sample workspace)
   aws ssm send-command --document-name AWS-RunShellScript --instance-ids <instance-id> \
     --parameters 'commands=["docker stop liferay || systemctl stop liferay"]'
   ```

   ✅ Expected: within about a minute the site loads from the other node (you may need to sign in again). Content and uploaded documents are the same. Start the node again with `docker start liferay` or `systemctl start liferay` and check it returns to `healthy`.

6. **Cache replication test.** Edit a web content article on one node, then load it through the other (clear the `AWSALB` cookie, or open a private window, to change node). ✅ The change is visible without waiting.

---

## 10. HTTPS and your own domain

For anything beyond a quick test, serve Liferay over HTTPS on your own host name.

1. **Request a certificate** in AWS Certificate Manager, in the **same region** as the ALB, for your host name (for example `liferay.example.com`), with DNS validation. Add the validation CNAME in your DNS and wait for **Issued**.
2. **Point DNS at the ALB:** a Route 53 **alias A record** to the ALB, or a CNAME at another DNS provider, to `terraform -chdir=terraform output -raw alb_dns_name`.
3. **Set the variables** in `terraform.tfvars`:

   ```hcl
   acm_certificate_arn = "arn:aws:acm:ap-northeast-1:<account-id>:certificate/<id>"
   virtual_host        = "liferay.example.com"
   ```

4. **Apply and re-render.** `terraform apply` adds the 443 listener and the HTTP→HTTPS redirect. The instances' `host.env` was written at boot, so update `HTTPS` and `VIRTUAL_HOST` there and restart Liferay:

   ```bash
   terraform -chdir=terraform apply
   scripts/run-on-stack.sh "${STACK}" liferay \
     "sed -i 's/^HTTPS=.*/HTTPS=true/; s/^VIRTUAL_HOST=.*/VIRTUAL_HOST=liferay.example.com/' /etc/liferay-ec2/host.env \
      && /opt/liferay-ec2/scripts/render-config.sh \
      && (docker restart liferay 2>/dev/null || systemctl restart liferay) \
      && /opt/liferay-ec2/scripts/wait-for-liferay.sh"
   ```

   In HA, run it one node at a time (`--instance-ids` with `aws ssm send-command`, or replace `liferay` with each instance in turn) to keep the site up.

The rendered `portal-ext.properties` then contains `web.server.protocol=https`, `company.default.virtual.host.name=liferay.example.com`, and `web.server.forwarded.host.enabled` / `web.server.forwarded.protocol.enabled`, so Liferay builds `https://` links from the ALB's `X-Forwarded-*` headers.

### Verify

```bash
curl -sI http://liferay.example.com | grep -iE '^(HTTP|location)'     # 301 to https://
curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://liferay.example.com/c/portal/robots   # 200 0
curl -sL https://liferay.example.com | grep -o 'http://liferay.example.com' | head -1   # prints nothing
```

✅ Expected: HTTP redirects to HTTPS, the certificate verifies (`0`), and the page contains no `http://` links to your host (mixed content). In the browser, the padlock shows and the CSS loads.

---

## 11. Validate the deployment

Run the end-to-end check from the repository root:

```bash
scripts/verify-deployment.sh
```

✅ Expected: every target `healthy`, `PASS` for both URLs through the ALB, `All checks passed` on every instance, and `Deployment verified`.

Then check by hand:

| Check | How | Expected |
| --- | --- | --- |
| Home page | Browser, `liferay_url` | Loads with CSS and images |
| Sign-in | `test@liferay.com` with the password from SSM (then your new one) | Signed in |
| License | **Control Panel → Configuration → License Manager** 🔎 (or the log line from `verify-node.sh`) | Your license, correct expiry, node count for HA |
| Search | **Control Panel → System → Search** | Connection active, Elasticsearch 8.19.x |
| Reindex | **Control Panel → Configuration → Search → Index Actions → Reindex all search indexes** | Completes without errors |
| Documents | Upload a file in **Site → Content & Data → Documents and Media** | Upload succeeds and downloads |
| Persistence | Restart Liferay (`docker restart liferay` / `systemctl restart liferay`) and reload | Content and the document are still there |
| Database | Single: `docker exec postgres psql -U liferay -d lportal -c 'select webid from company;'` on the instance | Returns `liferay.com` |
| Exposure | `nc -vz <instance-public-ip> 8080` from your workstation (single mode) | Times out: only the ALB can reach 8080 |
| No SSH | `aws ec2 describe-security-groups --group-names <stack>-liferay` | No port 22 rule |
| HA failover | Section 9, verify steps 5 and 6 | Site stays up; caches stay in sync |

---

## 12. CI/CD with GitHub Actions

> 🟡 **Partly tested on 22 October 2026:** the `build` and `image` jobs passed ([run 39708712711](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace/actions/runs/39708712711)). Pushing to ECR and the `deploy` job are **not yet tested** against a real stack.

Your code (OSGi modules, client extensions, configuration) lives in a **Liferay Workspace** and reaches the instances through GitHub Actions. A ready-made workspace for this guide is **[LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace)** (DXP `2026.q1.13-lts`, a sample OSGi portlet, a global CSS client extension and a React custom element client extension built with Vite).

```text
git push ─▶ build (Gradle, JDK 21) ─▶ image (linux/amd64) ─▶ ECR ─┐
                                   └▶ Tomcat artifacts ─▶ S3 ─────┤
                                                                  ▼
                        deploy (environment "ec2") ─▶ SSM Run Command, one node at a time
                                ├─ docker: deploy-docker.sh <ecr-image>   (pull, recreate, wait, roll back on failure)
                                └─ tomcat: deploy-tomcat.sh <s3-archive>  (hot deploy; restart only if configs changed)
```

No AWS keys are stored in GitHub: the workflow signs in with **GitHub OIDC** to the role Terraform created, which can only push to this stack's ECR repository, upload to `builds/`, and run commands on instances tagged with this stack's name.

### 12.1 Use the sample workspace

Use the repository directly, or create your own copy from it:

```bash
gh repo create <org>/<your-workspace> --private --clone \
  --template LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace     # only if it is marked as a template; otherwise fork or copy
```

If you use your own copy, set `github_repository = "<org>/<your-workspace>"` in `terraform.tfvars` and run `terraform apply` so the role trusts it.

### 12.2 Connect the workspace to the stack

Terraform prints the exact commands:

```bash
terraform -chdir=terraform output -raw github_variables_commands
```

Run them (they set `AWS_REGION`, `AWS_ROLE_ARN`, `ECR_REPOSITORY`, `ARTIFACT_BUCKET`, `LIFERAY_STACK` and `LIFERAY_RUNTIME` as repository **variables**; none of them is a secret).

Then create the GitHub **environment** `ec2` (**Settings → Environments → New environment**). Add **required reviewers** to approve every deployment, and limit it to the `main` branch.

### 12.3 Run the pipeline

Push to `main`, or start it by hand: **Actions → CI/CD → Run workflow**.

| Job | Runs on | What it does |
| --- | --- | --- |
| `build` | Every push and pull request | `./gradlew build dockerDeploy createDockerfile`, checks the Docker context, packages `liferay-artifacts-<tag>.tar.gz` |
| `image` | Pushes to `main`, `v*` tags, manual runs | Builds the `linux/amd64` image, checks its contents, pushes to ECR when the AWS variables exist |
| `deploy` | Pushes to `main`, `v*` tags, manual runs, when `LIFERAY_STACK` is set | Waits for approval (environment `ec2`), then rolls out through SSM, one node at a time, and fails on the first node that does not become ready |

**Image tags:** a `v1.2.0` git tag gives `1.2.0`; anything else gives `<branch>-<short-sha>`, for example `main-1a2b3c4`.

### 12.4 Roll back

- **Docker runtime:** a node that does not become ready rolls itself back to the previous image, and the rollout stops, so other nodes keep the old image. To return to an older build on purpose, re-run the old workflow run's `deploy` job, or run on the stack: `scripts/run-on-stack.sh <stack> liferay '/opt/liferay-ec2/scripts/deploy-docker.sh <ecr-repo>:<old-tag>'` (HA: one node at a time).
- **Tomcat runtime:** re-run the `deploy` job of the older run (its archive is still in `builds/` for 90 days). Hot deploy replaces bundles with the same symbolic name; to remove a module entirely, delete its jar from `/opt/liferay/osgi/modules` and restart.

### Verify

1. ✅ The workflow run is green; the `deploy` job's log shows `Final status: Success` and each node's output ends with `Deployed <image>` (Docker) or `Deployment finished` (Tomcat).
2. ✅ ECR has the image:

   ```bash
   aws ecr describe-images --repository-name "${STACK}/dxp-custom" \
     --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags[0], imagePushedAt]' --output text
   ```

3. ✅ Every Liferay node runs it:

   ```bash
   scripts/run-on-stack.sh "${STACK}" liferay 'docker inspect --format "{{.Config.Image}}" liferay 2>/dev/null || cat /opt/liferay/.liferay-ec2-version'
   scripts/run-on-stack.sh "${STACK}" liferay '/opt/liferay-ec2/scripts/liferay-log.sh | grep -E "STARTED (com.liferay.ec2.sample.portlet|ec2sampleglobalcss|ec2samplereactapp)" | tail -3'
   ```

   Expected one `STARTED` line each for the portlet and the two client extensions (client extensions start under their project ID: `ec2sampleglobalcss`, `ec2samplereactapp`). 🔎

4. ✅ The React app's files are served through the load balancer:

   ```bash
   URL=$(terraform -chdir=terraform output -raw liferay_url)
   curl -s -o /dev/null -w 'main.js: %{http_code} %{content_type}\n' "${URL}/o/ec2-sample-react-app/main.js"
   curl -s -o /dev/null -w 'index.css: %{http_code} %{content_type}\n' "${URL}/o/ec2-sample-react-app/assets/index.css"
   ```

   Expected `200` with a JavaScript and a CSS content type. A `404` means the zip didn't deploy, or its `assemble` block is wrong.

5. ✅ In Liferay, signed in, edit a page:
   - Add the **EC2 Sample** widget (category **Sample**). It shows *Hello from Liferay self-hosted on Amazon EC2* and the serving node.
   - Add the **EC2 Sample React App** widget (category **Client Extensions**). It shows *Hello from React on Amazon EC2*, then *Signed in as Test Test (test@liferay.com), read from /o/headless-admin-user*, which proves the React app called Liferay's API with your session. The button counts clicks. Signed out, it says you are a guest.
   - Under the page's **Design → CSS Client Extensions**, add **EC2 Sample Global CSS**: the page gets an orange top border.
   - In HA, both widgets show the same on every node.
   - **Control Panel → Applications → Client Extensions** lists **EC2 Sample Global CSS** and **EC2 Sample React App**.

---

## 13. Backups, logging and monitoring

| Area | Single | HA | How |
| --- | --- | --- | --- |
| Database | ⚠️ Inside the instance's EBS volume | RDS automated backups (7 days) and snapshots | Single: AWS Backup plan for the EBS volume, or `docker exec postgres pg_dump`; HA: RDS console or AWS Backup |
| Documents and Media | ⚠️ Same EBS volume | EFS automatic backups (AWS Backup) | Include the EBS volume or EFS in an AWS Backup plan |
| Search index | Rebuildable | Rebuildable | **Reindex all** after a restore; snapshots to S3 with the `repository-s3` plugin for large indexes 🔎 |
| Instance config | In Git and S3 | Same | `terraform apply` + bootstrap recreates any instance |
| Logs | `docker logs liferay`, `/opt/liferay/tomcat/logs` | Same, per node | Install the CloudWatch agent (or ship Docker logs with the `awslogs` driver) for central logs 🔎 |
| Metrics and alarms | EC2 status checks | Plus ALB `UnHealthyHostCount`, RDS CPU, storage, connections | CloudWatch alarms to an SNS topic |
| Patching | `dnf upgrade` via SSM Patch Manager | Same, one node at a time | Rebuild images for container base updates |

> ⚠️ **Single mode has no backups until you add them.** Create an AWS Backup plan for the instance (tag-based on `LiferayStack`) before you put anything you care about on it. Test a restore once.

Consistent backups: Liferay's database and Documents and Media must be restored **to the same point in time**. Take the RDS snapshot and the EFS/EBS backup together, ideally with Liferay quiet.

---

## 14. From PoC to production

| Area | PoC (this guide) | Production target |
| --- | --- | --- |
| Liferay nodes | Fixed EC2 instances | Same pattern with an Auto Scaling group and a launch template, or more fixed nodes; at least 2 in 2 AZs |
| Sizing | `m6i.xlarge`, 6-8 GB heap | Liferay's sizing for your traffic; load-test |
| Database | RDS Multi-AZ `db.m6g.large`, no TLS | RDS with TLS (`sslmode=require`, `rds.force_ssl=1`), Performance Insights, deletion protection (`force_destroy = false`) |
| Search | 1 Elasticsearch node, security off | 3-node Elasticsearch cluster across AZs, or Elastic Cloud on AWS, with TLS and authentication (`authenticationEnabled`, `httpSSLEnabled`) 🔎 |
| Documents and Media | EFS | EFS, or Liferay's S3 store |
| Network | 1 NAT gateway | 1 NAT gateway per AZ; VPC endpoints for ECR, SSM and logs |
| Edge | ALB, `allowed_cidrs` | ALB with AWS WAF, HTTPS only, CloudFront for static assets |
| Secrets | SSM Parameter Store, Terraform state | Same with a customer-managed KMS key, or Secrets Manager with rotation; remote, encrypted Terraform state |
| CI/CD | Deploy on push to `main` after approval | Separate stacks per environment (`dev`, `uat`, `prod`), promotion by tag, required reviewers on `prod` |
| Observability | Logs on the instance | CloudWatch Logs and alarms, or your APM; Liferay's own monitoring |
| Email | None (notifications skipped) | Amazon SES (or your SMTP relay) with a verified sender domain |
| Client IP | Liferay sees the ALB's IP | Tomcat `RemoteIpValve` trusting the ALB subnets, so audit logs and IP rules see the real user 🔎 |
| Upgrades | Swap image/bundle | Liferay's upgrade process (database upgrade tool), rehearsed on a copy of production |

---

## 15. Tear down the environment

```bash
terraform -chdir=terraform destroy
```

With `force_destroy = true` (the default), this deletes the S3 bucket and its objects, the ECR images and the RDS instance **without a final snapshot**. Take any backups you need first.

If you created a GitHub environment and variables, remove them too:

```bash
for v in AWS_REGION AWS_ROLE_ARN ECR_REPOSITORY ARTIFACT_BUCKET LIFERAY_STACK LIFERAY_RUNTIME; do
  gh variable delete "$v" --repo <org>/<workspace>
done
```

### Verify

```bash
aws ec2 describe-instances --filters "Name=tag:LiferayStack,Values=${STACK}" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'length(Reservations)'
aws resourcegroupstaggingapi get-resources --tag-filters "Key=LiferayStack,Values=${STACK}" --query 'ResourceTagMappingList[].ResourceARN'
aws ssm get-parameters-by-path --path "/${STACK}" --query 'length(Parameters)'
```

✅ Expected: `0`, `[]` (or only resources that are still being deleted) and `0`. Check **Billing → Bills** the next day: no running charges for EC2, NAT gateway, ALB, RDS or EFS.

---

## 16. Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| Instance not `Online` in Systems Manager | No outbound internet (HA: NAT gateway not ready), or instance profile missing | Check the private route table has `0.0.0.0/0 → nat-...`; wait 5 minutes; check the instance's IAM role |
| Bootstrap log stops at `Installing Docker Compose` or `dnf install` | No outbound internet, or GitHub/Docker Hub blocked by a proxy | Check NAT and outbound rules; mirror images to ECR if Docker Hub is blocked |
| `render-config.sh`: `AccessDeniedException` on `ssm:GetParameter` | Instance role policy or parameter names don't match | `aws ssm get-parameters-by-path --path /<stack>`; check the role's `ReadStackParameters` statement |
| `WARNING: no license at s3://...` | `license_file` not found at apply time | Copy the key to `license/license.xml`, `terraform apply`, then re-run `render-config.sh` and restart Liferay (see `license/README.md`) |
| ALB target `unhealthy` with `Target.Timeout` or `Target.FailedHealthChecks` during the first 15 minutes | First start still running | Wait; watch the Liferay log |
| ALB target `unhealthy` with `Health checks failed with these codes: [500]`; every page returns 500; Liferay log shows `Invalid host name <ip or alb-dns-name>` | The host name is not in `virtual.hosts.valid.hosts` (section 8.1). Stacks created before this guide added `ALB_DNS_NAME` (October 2026) have it missing | Add it and re-render: `scripts/run-on-stack.sh <stack> liferay "grep -q '^ALB_DNS_NAME=' /etc/liferay-ec2/host.env \|\| echo 'ALB_DNS_NAME=<alb-dns-name>' >> /etc/liferay-ec2/host.env; aws s3 sync s3://<artifact-bucket>/host/ /opt/liferay-ec2/ --only-show-errors; chmod 755 /opt/liferay-ec2/scripts/*.sh; /opt/liferay-ec2/scripts/render-config.sh; docker restart liferay; /opt/liferay-ec2/scripts/wait-for-liferay.sh"` (Tomcat runtime: `systemctl restart liferay`) |
| ALB target stays `unhealthy` with another code or a timeout; Liferay log shows `Server startup` | Health check path or port | `curl -i http://127.0.0.1:8080/c/portal/robots` on the instance; it must return 200 |
| Login history and audit logs show `10.20.x.x` for every user | Liferay sees the ALB's IP, not `X-Forwarded-For` | Section 8, "What else to expect in the log" |
| No emails arrive (password changes, invitations); log says `Skipping email because the sender is not specified` | No mail server configured | Configure SMTP (for example Amazon SES) in **Control Panel → Server Administration → Mail** or in `portal-ext.properties` |
| Liferay never finishes starting; log mentions license | Missing or invalid key, or single-node key in a cluster | Check `/opt/liferay/deploy`, the license log lines, and use a cluster-capable key for HA |
| Liferay shuts down soon after start, log mentions Elasticsearch | Wrong Elasticsearch version or unreachable | `curl http://<es>:9200`; keep 8.19.x; check the search security group |
| Elasticsearch container restarts; log mentions `max virtual memory areas` | `vm.max_map_count` too low | `sysctl vm.max_map_count`; re-run the bootstrap |
| `Elasticsearch analysis plugins` FAIL | Image built without plugins | `docker rmi liferay-elasticsearch:<version>` and re-run the bootstrap |
| `EFS mounted` FAIL / `mount.nfs4: Connection timed out` | Mount target not ready or EFS security group | Wait for both mount targets to be `available`; check port 2049 from the Liferay SG |
| `Permission denied` writing Documents and Media | Ownership | `chown 1000:1000 /mnt/efs/document_library` (or the single-mode folder) |
| HA: each node's JGroups view shows `(1)` | Nodes can't reach each other on 7800-7801, or JDBC_PING table not written | Check the `liferay_cluster` SG rule; `select * from jgroupsping`; check the bind address in `/opt/liferay/jgroups/control.xml` is the node's private IP |
| HA: `JDBC_PING` or `JGROUPSPING` errors at startup | Protocol attribute differs in your JGroups version | Section 9.4 🔎; take `udp_control.xml` from your release |
| Users signed out repeatedly | Stickiness off, or a node restarting | Check the target group's stickiness; check node health |
| Pages load without CSS, or links use `http://` behind HTTPS | Forwarded headers or protocol not set | Section 10 step 4; check `web.server.protocol=https` in the rendered `portal-ext.properties` |
| Redirect loop | HTTPS redirect configured in two places | Redirect only at the ALB |
| Large uploads fail | ALB idle timeout (300 s here) or Liferay upload limits | Raise `idle_timeout`; check Liferay's upload size settings |
| GitHub Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Repository name, branch or environment doesn't match the role's trust policy | `github_repository` in tfvars must be `owner/name` exactly; deploy job must use environment `ec2`; run on `main` or a `v*` tag |
| GitHub Actions deploy: `No running instances tagged ...` | `LIFERAY_STACK` variable wrong | Set it to `terraform -chdir=terraform output -raw stack_name` |
| Deploy rolls back: `New image did not become ready` | Your build fails to start | Read the 200 log lines in the job output; fix and push again |
| `exec format error` | ARM image on x86 instances | Build with `--platform linux/amd64` (the workflow does) |
| Docker Hub `toomanyrequests` | Anonymous pull rate limit | Retry later, sign in to Docker Hub on the instance, or mirror `liferay/dxp`, `postgres` and Elasticsearch to ECR |

---

## 17. Assumptions to verify

Confirm these before relying on the guide for anything beyond a sandbox:

1. ✅ **Health check path** `/c/portal/robots` returns 200 on DXP 2026.Q1 once Liferay is ready, **provided the request's host name is in `virtual.hosts.valid.hosts`** (section 8.1). Confirmed on 22 October 2026; the guide originally missed the valid-hosts list, which made the ALB health check fail with 500.
2. 🟡 **Docker mount path**: the `liferay/dxp` 2026.Q1 image copies `/etc/liferay/mount/files` into `/opt/liferay` at startup. Confirmed for `portal-ext.properties`, `deploy/license.xml` and `osgi/configs`; `jgroups/` (HA) not yet tested.
3. **JGroups stack** (section 9.4): protocol names and `JDBC_PING` attributes match the JGroups version in your release; `cluster.link.autodetect.address` behaves as expected with host networking.
4. **Forwarded-header properties** `web.server.forwarded.host.enabled` and `web.server.forwarded.protocol.enabled` behind the ALB (section 10).
5. 🟡 **Elasticsearch 8.19.20** works with DXP 2026.Q1.13 using the `elasticsearch8` OSGi configuration (tested: green indexes, search results). Still check it is in the compatibility matrix for your release.
6. 🟡 **PostgreSQL 16** works as the container (tested); RDS not yet tested. Still check the compatibility matrix.
7. ✅ **License log lines** used by `verify-node.sh`: `License registered for DXP Development` on first start and `DXP Development license validation passed` after a restart (confirmed with a DXP Development key).
8. **Tomcat bundle layout**: `.tar.gz` next to the `.7z` named in `release.properties`, a single top folder, and a `tomcat*` folder inside.
9. **Costs** in section 1 for your region (use the AWS Pricing Calculator).
10. **Client IP behind the ALB**: how to make Liferay record `X-Forwarded-For` (Tomcat `RemoteIpValve` or a Liferay property) in the Docker image and the Tomcat bundle (section 8).
11. **The `PasswordModifiedFilter` `NullPointerException`** seen once right after a start (section 8) is harmless and doesn't recur.

---

## 18. Reference documentation

**Liferay**

- [Installing Liferay (self-hosted)](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/installing-liferay)
- [Using the Liferay DXP Docker image](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/installing-liferay/using-liferay-docker-images)
- [Configuring containers (environment variables and mounted files)](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/installing-liferay/using-liferay-docker-images/configuring-containers)
- [Installing a Liferay Tomcat bundle](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/installing-liferay/installing-a-liferay-tomcat-bundle)
- [Clustering for high availability](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/setting-up-liferay/clustering-for-high-availability)
- [Configuring Cluster Link](https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/setting-up-liferay/clustering-for-high-availability/configuring-cluster-link)
- [Installing Elasticsearch](https://learn.liferay.com/w/dxp/using-search/installing-and-upgrading-a-search-engine/elasticsearch/installing-elasticsearch)
- [Connecting to Elasticsearch](https://learn.liferay.com/w/dxp/using-search/installing-and-upgrading-a-search-engine/elasticsearch/connecting-to-elasticsearch)
- [Liferay Workspace](https://learn.liferay.com/w/dxp/liferay-development/tooling/liferay-workspace)
- [Compatibility matrix (Help Center)](https://help.liferay.com/hc/en-us/articles/360049238151)
- [Liferay releases feed](https://releases.liferay.com/releases.json)

**AWS**

- [Amazon Linux 2023](https://docs.aws.amazon.com/linux/al2023/ug/what-is-amazon-linux.html)
- [Application Load Balancer target groups and sticky sessions](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/sticky-sessions.html)
- [Amazon RDS for PostgreSQL Multi-AZ](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html)
- [Mounting EFS with the EFS mount helper](https://docs.aws.amazon.com/efs/latest/ug/efs-mount-helper.html)
- [Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) and [Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html)
- [Configuring OpenID Connect in AWS for GitHub Actions](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [Amazon ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html)
- [AWS Backup](https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html)
- [Terraform AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

**Related**

- [LGSAPAC/lfrgs-cne-alibaba-ready](https://github.com/LGSAPAC/lfrgs-cne-alibaba-ready): the same kind of guide for Liferay CNE (Kubernetes) on Alibaba Cloud ACK

---

*For questions about this guide or your environment, contact your Liferay representative or Liferay Support.*
