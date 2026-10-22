# Liferay DXP Self-Hosted on Amazon EC2: Step-by-Step Guide

**Product:** Liferay DXP 2026.Q1 LTS (`2026.q1.13-lts`), self-hosted on Amazon EC2, deployed with Docker (or the traditional Tomcat bundle)
**Audience:** Partner and customer technical teams setting up a sandbox or proof-of-concept (PoC) environment
**Prepared by:** Liferay Customer Success APAC
**Status:** Draft, October 2026. Sections 2 to 9, 11, 12 and 15 tested on 22 and 23 October 2026 in Asia Pacific (Tokyo) with the Docker runtime: single mode end to end, and high availability (two clustered nodes, RDS Multi-AZ, EFS, failover, cache replication, rolling CI deploy). Not yet run on AWS: section 10 (HTTPS), section 13 (backups and monitoring) and the Tomcat runtime. The Terraform passes `terraform validate`, every shell script passes ShellCheck, and the sample workspace's build and `linux/amd64` image jobs passed in GitHub Actions on 22 October 2026 ([run 39708712711](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace/actions/runs/39708712711)). Items to confirm are marked **🔎 Verify**.

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

**Time required:** about 1 hour for single mode the first time, most of it setting up tools and AWS access (sections 3 and 4). In testing, `terraform apply` took 3.5 minutes and the instance bootstrap under 5 minutes. High availability adds about 20 minutes: in testing the apply took 16 minutes (RDS Multi-AZ alone 15.5) and both nodes were ready about 6 minutes later.

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

- **A Liferay DXP activation key** (XML). The `liferay/dxp` image ships its own single-node trial key, but this guide turns it off (section 9.6) so only your key is used: without one, Liferay never becomes ready.
- **High availability needs a key that allows clustering.** Look at `<license-type>`:

  | `<license-type>` | Works for | Example |
  | --- | --- | --- |
  | `developer` | Single mode only. Liferay refuses it in a cluster: `Developer licenses do not allow for clustering` | `DXP Development`, often with `<max-http-sessions>5</max-http-sessions>` |
  | `virtual-cluster` | Single mode and HA, up to `<max-cluster-nodes>` nodes | `DXP Non-Production (Virtual Cluster)`, `<max-cluster-nodes>2</max-cluster-nodes>` (tested) |
  | `developer-cluster`, `production`, `enterprise` | Depends on the subscription; look for a node or server count in the file | |

  Check yours with `grep -E '<(license-type|license-name|max-cluster-nodes|max-http-sessions|expiration-date)>' license/license.xml`. Keep `liferay_node_count` at or below `<max-cluster-nodes>`. "Liferay Trial Activation" keys come in both kinds, so check the type rather than the account name.
- Ask your Liferay representative or Liferay Support for a cluster-capable key for DXP 2026.Q1 (7.4).
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
| `github_oidc_subject_prefix` | empty | Set it if the repository uses GitHub's **immutable OIDC subject** (section 12.2). Empty means `repo:<owner>/<name>` |
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
- `plan`: ends with **`Plan: 58 to add, 0 to change, 0 to destroy.`** in single mode (tested). In HA: **`Plan: 78 to add, 0 to change, 0 to destroy.`** (tested), adding RDS, EFS, the NAT gateway, the search instance, a second Liferay node and their security groups.

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

Applying a saved plan doesn't ask for confirmation. Single mode took **3 minutes 25 seconds** in testing (`Apply complete! Resources: 58 added, 0 changed, 0 destroyed.`); HA took **16 minutes** (`78 added`), 15.5 of them for RDS Multi-AZ. Terraform returns once the AWS resources exist; the instances keep bootstrapping for a few more minutes (section 7). From this point the stack is billed until you tear it down (section 15).

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
4. It builds the Elasticsearch image with the analysis plugins (where needed), starts PostgreSQL and Elasticsearch, then Liferay: `docker compose up -d liferay` (Docker runtime; the rendered files are mounted at `/mnt/liferay/files`, which the image copies into `/opt/liferay` at startup), or installs the Tomcat bundle and starts the `liferay` service (Tomcat runtime; `ExecStartPre` copies the same files into `/opt/liferay`).
5. It waits until `http://127.0.0.1:8080/c/portal/robots` returns 200 (the ALB health check), then writes `/opt/liferay-ec2/runtime/bootstrap.done`.

In HA the order matters: the search node first, then node 1, then the other nodes. Section 9.6 explains how the bootstrap enforces it.

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

> ⚠️ **Mount at `/mnt/liferay`, not `/etc/liferay/mount`.** The `liferay/dxp` image uses `/etc/liferay/mount` as its mount folder if that folder exists, and `/mnt/liferay` otherwise, never both. The workspace's generated Dockerfile bakes your module jars into `/mnt/liferay/deploy`, so mounting anything under `/etc/liferay/mount` makes the image skip them silently: client extensions still deploy (they live elsewhere), but OSGi modules don't. Found in testing on 22 October 2026; `verify-node.sh` checks for it (`Image modules deployed`).

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
PASS  Image modules deployed             no module jars in the image
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

After a restart, `License registered` shows `DXP Development license validation passed` instead; both mean the key is active. `Image modules deployed` lists the workspace's jars once you deploy a custom image (section 12).

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

Expected `green liferay-<company-id> <documents>` among the indexes (about 480 documents on a new site), and `2 Results for`. In the browser, **Control Panel → Configuration → Search** shows an active connection to Elasticsearch 8.19.

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

> ✅ **Tested on 22 and 23 October 2026** in Asia Pacific (Tokyo), Docker runtime, two nodes, with a DXP Non-Production (Virtual Cluster) key: clustering, shared Documents and Media, failover in both directions, cache replication between nodes, and a rolling CI deploy. Four start-up problems were found and fixed on the way (9.6). The Tomcat runtime in HA is not yet tested.

### 9.1 Database: RDS for PostgreSQL Multi-AZ

All nodes share one RDS instance (`db_endpoint`). RDS keeps a synchronous standby in the other Availability Zone and fails over automatically; Liferay reconnects through the same DNS name. Backups are kept 7 days. `rds.force_ssl` is `0` so the default JDBC URL works; for production, add `?sslmode=require` to the URL in `render-config.sh` and set `rds.force_ssl = 1`.

Creating it took 15 minutes 38 seconds in testing, most of the 16-minute apply. RDS's API reports `MultiAZ: True` but `SecondaryAvailabilityZone: None` for this instance class and engine; that is expected and doesn't mean the standby is missing.

### 9.2 Documents and Media: EFS

Every Liferay node mounts the same EFS file system at `/mnt/efs` (TLS in transit, through the EFS mount helper's `efs-proxy`) and uses `/mnt/efs/document_library` as Liferay's default file system store. An upload on one node is visible on every other node immediately, and stays readable while any node is down (tested). EFS automatic backups are on.

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

- [`jgroups-tcp-jdbc-ping.xml`](host/config/jgroups-tcp-jdbc-ping.xml) is Liferay's own JGroups stack with `UDP` replaced by `TCP` (bound to the node's private IP, port 7800 for control and 7801 for transport) and `PING` replaced by **`JDBC_PING`**, which keeps the member list in a `JGROUPSPING` table in the shared PostgreSQL database. No extra infrastructure, and it works the same in Docker (host network) and Tomcat. Tested with DXP 2026.Q1.13: both channels form a view of all nodes, and nodes leave and rejoin cleanly.
- The Liferay security group allows 7800-7801 between Liferay nodes only.

### 9.5 Load balancer, sessions and restarts

The ALB spreads users across nodes with **sticky sessions** (`lb_cookie`, 1 day): Liferay does not replicate HTTP sessions, so a user stays on one node. If that node stops, the user moves to another node and must sign in again.

- **Unplanned failure (a node crashes):** the ALB keeps sending that node's users to it until its health check fails. The target group checks `/c/portal/robots` every **10 seconds** and takes a node out after **2** failures, so users see HTTP 502 for about 20 seconds. In testing with the earlier setting (every 30 seconds, 5 failures), users on the stopped node got 502 for **2 minutes 19 seconds to 2.5 minutes**; the faster setting is 🔎 not yet re-measured.
- **Planned restarts (deploys):** `deploy-docker.sh` (and `deploy-tomcat.sh` when it restarts) first **takes the node out of the ALB** and waits up to 30 seconds for its requests to finish, restarts it, waits until Liferay answers, then **puts it back** and waits until the ALB reports it `healthy`. Section 12 rolls nodes one at a time, so the other nodes serve everyone meanwhile. For this, the instance role may read target health and register or deregister targets in this stack's target group only.

### 9.6 First start, in order

Four things must happen in order when an HA stack starts for the first time. All four went wrong in testing before the guide handled them:

| Order | Why | What the bootstrap does |
| --- | --- | --- |
| Search node before Liferay | Liferay creates its search indexes at startup. A node that starts before Elasticsearch answers runs without its company index (`index_not_found_exception ... liferay-<company-id>`) until it is restarted | Every Liferay node waits for `ES_URL/_cluster/health` (up to 20 minutes): `Waiting for Elasticsearch at http://<search-ip>:9200` |
| Node 1 before the others | Against an empty database, two nodes create Liferay's tables at once and one fails: `duplicate key value violates unique constraint "release__pkey"`, then `BeanLocator is null` | Each node gets `NODE_INDEX`. Nodes 2 and up find node 1 through the EC2 API and wait until it answers on port 8080: `Waiting for liferay-poc-liferay-1 to finish starting (this is node 2)`, then `liferay-poc-liferay-1 (10.20.x.x) is up`. Later restarts don't wait, because node 1 is already up |
| Compose on the search node | Compose checks every service in `compose.yaml`, also the Liferay one the search node doesn't run. A required Documents and Media folder stopped Elasticsearch from starting: `required variable LIFERAY_DOCLIB_DIR is missing a value` | The folder has a default, so the search node starts only Elasticsearch |
| Only your license | The `liferay/dxp` image ships a single-node trial key. In a cluster it logs `ERROR ... DXP Development license validation failed` with `Clustering has been detected. Developer licenses do not allow for clustering.` on every first start | Compose sets `LIFERAY_CONTAINER_DISABLE_TRIAL_LICENSE=true`, so the image deletes its trial key. The older name `LIFERAY_DISABLE_TRIAL_LICENSE` is ignored by 2026.Q1 images |

Expected bootstrap timeline (tested): the search node finishes about 2 minutes after the apply starts; RDS is ready after about 16 minutes; node 1 then needs about 2 minutes to pull the image and 2 more to create the database; node 2 starts as soon as node 1 answers and is ready about a minute later.

### Verify

1. Every instance passes its checks:

   ```bash
   scripts/run-on-stack.sh "${STACK}" all 'sudo /opt/liferay-ec2/scripts/verify-node.sh'
   ```

   ✅ Expected: `All checks passed` on every Liferay node, including these lines, and on the search node (`Elasticsearch cluster health ... green`, the four plugins):

   ```text
   PASS  Database reachable                 liferay-poc.<id>.ap-northeast-1.rds.amazonaws.com:5432 reachable
   PASS  Elasticsearch reachable            status green, 1 node(s)
   PASS  License registered                 ... DXP Non-Production license validation passed
   PASS  No license errors                  none found
   PASS  Documents and Media writable       127.0.0.1:/ 1% used
   PASS  EFS mounted                        /mnt/efs is a mountpoint
   PASS  Cluster members = 2                view [ip-10-20-133-124-18359|9] (2)
   ```

2. The nodes see each other in the cluster:

   ```bash
   scripts/run-on-stack.sh "${STACK}" liferay \
     "/opt/liferay-ec2/scripts/liferay-log.sh | grep -oE 'view (MergeView::)?\[[^]]*\] \([0-9]+\)( \[[^]]*\])?' | tail -2"
   ```

   ✅ Expected on every node: the latest view of each channel lists **as many members as `liferay_node_count`**, one per node, for example `view [ip-10-20-133-124-56237|1] (2) [ip-10-20-133-124-56237, ip-10-20-151-158-46150]`. A view of `(1)` on each node means they did not find each other (section 16). The number after `|` grows each time a node leaves or joins.

   A restarted node sometimes starts one channel alone (`(1)`) before it finds the others; JGroups merges the halves within about a minute and logs `MergeView::[...] (2) [...], 2 subgroups: ...`. In testing, node 2's control channel merged 48 seconds after it started. Only a `(1)` that stays for several minutes is a problem.

3. The discovery table in RDS has an entry per node and channel:

   ```bash
   scripts/run-on-stack.sh "${STACK}" liferay 'source /opt/liferay-ec2/scripts/common.sh && PGPASSWORD=$(get_secret db/password) docker run --rm -q --network host -e PGPASSWORD postgres:16 psql -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -At -c "select cluster_name, own_addr from jgroupsping order by 1;"'
   ```

   ✅ Expected: two `liferay-channel-control` rows and two `liferay-channel-transport-0` rows (one per node each), with UUIDs as addresses.

4. Both nodes are healthy behind the ALB:

   ```bash
   TG=$(aws elbv2 describe-target-groups --names "${STACK}-liferay" --query 'TargetGroups[0].TargetGroupArn' --output text)
   aws elbv2 describe-target-health --target-group-arn "${TG}" \
     --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State]' --output text
   ```

   ✅ Expected: every node `healthy`.

5. **Failover test.** Sign in, upload a file to **Documents and Media**, then stop Liferay on one node, reload, and repeat for the other node. To stop and start a node:

   ```bash
   NODE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${STACK}-liferay-1" "Name=instance-state-name,Values=running" \
     --query 'Reservations[0].Instances[0].InstanceId' --output text)
   aws ssm send-command --document-name AWS-RunShellScript --instance-ids "${NODE}" --parameters 'commands=["docker stop liferay"]'
   # later
   aws ssm send-command --document-name AWS-RunShellScript --instance-ids "${NODE}" --parameters 'commands=["docker start liferay"]'
   ```

   (Tomcat runtime: `systemctl stop liferay` / `systemctl start liferay`.)

   ✅ Expected: if you were on the stopped node, you get HTTP 502 until the ALB marks it `unhealthy` (9.5), then the site loads from the other node and you are signed out (sessions aren't shared). If you were on the other node, nothing changes and you stay signed in. Either way, content and your uploaded file are the same. The surviving node's log shows a view of `(1)`; after `docker start`, the node is ready in about 40 seconds and the views are back to `(2)`.

6. **Cache replication test.** Prove that an edit on one node clears the other node's cache. Steer the ALB to one node at a time by taking the other out (each switch takes about 30 seconds):

   ```bash
   ID1=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${STACK}-liferay-1" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
   ID2=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${STACK}-liferay-2" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)

   # only node 2
   aws elbv2 register-targets   --target-group-arn "${TG}" --targets "Id=${ID2},Port=8080"
   aws elbv2 deregister-targets --target-group-arn "${TG}" --targets "Id=${ID1},Port=8080"
   ```

   1. **Only node 2:** open the home page; node 2 now has it cached.
   2. **Only node 1** (swap `ID1` and `ID2` in the two commands): sign in (you are signed out, sessions aren't shared), edit the home page (for example the **Welcome** heading) and **Publish**.
   3. **Only node 2** again: reload the home page.
   4. Put both back: `aws elbv2 register-targets --target-group-arn "${TG}" --targets "Id=${ID1},Port=8080" "Id=${ID2},Port=8080"`.

   ✅ Expected: in step 3, node 2 shows your edit immediately, without a restart. Check `aws elbv2 describe-target-health` between steps: the node you took out shows `draining`, then `unused`. In testing, node 2 showed the edited heading straight after it was published on node 1.

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

> ✅ **Tested on 22 October 2026** in Asia Pacific (Tokyo), single mode with the Docker runtime: every row below except HA failover.

Run the end-to-end check from the repository root:

```bash
scripts/verify-deployment.sh
```

✅ Expected: every target `healthy`, `PASS` for both URLs through the ALB, `All checks passed` on every instance, and `Deployment verified`. In testing it took about 20 seconds:

```text
== 1. Load balancer targets
i-...	healthy	None
PASS  all targets healthy

== 2. Liferay through the load balancer
PASS  http://liferay-poc-<n>.ap-northeast-1.elb.amazonaws.com/c/portal/robots -> 200
PASS  http://liferay-poc-<n>.ap-northeast-1.elb.amazonaws.com/ -> 200

== 3. Instance checks (verify-node.sh through SSM)
--- liferay-poc-liferay-1 (i-...)
...
All checks passed

Deployment verified
```

Then check by hand. Control Panel paths are as in DXP 2026.Q1: open the applications menu and choose the **Control Panel** tab (next to **Applications** and **Commerce**), where links are grouped under **Users**, **Sites**, **Accounts**, **Configuration**, **Notifications**, **Object**, **Security**, **System** and **Marketplace**.

| Check | How | Expected |
| --- | --- | --- |
| Home page | Browser, `liferay_url` | Loads with CSS and images |
| Sign-in | `test@liferay.com` with the password from SSM (then your new one) | Signed in |
| License | **Control Panel → Marketplace → License Manager** (or the log line from `verify-node.sh`) | Your license, correct expiry, node count for HA |
| Search | **Control Panel → Configuration → Search** | Connection active, Elasticsearch 8.19.x |
| Reindex | **Control Panel → Configuration → Search → Index Actions → Reindex all search indexes** | Completes without errors. On a new site it finished in seconds; the log shows `Finished reindexing company ... with execution mode full` |
| Documents | Upload a file in the site menu → **Content & Data → Documents and Media** (**New → File Upload**) | Upload succeeds and downloads. An image also gets Adaptive Media renditions (preview and thumbnail) |
| Persistence | Restart Liferay (`docker restart liferay` / `systemctl restart liferay`), wait for it (about 35 seconds), and reload | Content and the document are still there, and the ALB target is `healthy` again |
| Database | Single: `docker exec postgres psql -U liferay -d lportal -c 'select webid from company;'` on the instance | Returns `liferay.com` |
| Exposure | Find the instance's public IP (single mode) with `aws ec2 describe-instances --filters "Name=tag:LiferayStack,Values=${STACK}" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text`, then from your workstation `nc -vz -G 5 <public-ip> 8080` (also 22, 5432, 9200; on Linux use `-w 5` instead of `-G 5`) | No answer on any port: only the ALB can reach 8080 |
| No SSH | `aws ec2 describe-security-groups --filters "Name=group-name,Values=${STACK}-liferay" --query 'SecurityGroups[0].IpPermissions[].[FromPort, ToPort, UserIdGroupPairs[0].GroupId]' --output text` | Only `8080 8080 sg-...` (the ALB's security group); no port 22 rule. Use `--filters`, not `--group-names`: `--group-names` only finds groups in the default VPC and fails with `InvalidGroup.NotFound` |
| HA failover | Section 9, verify steps 5 and 6 | Site stays up; caches stay in sync |

✅ Confirm the upload and the persistence test on the instance (single mode):

```bash
scripts/run-on-stack.sh "${STACK}" liferay "docker exec postgres psql -U liferay -d lportal -At -F ' | ' -c 'select title, mimetype, size_, createdate from dlfileentry order by createdate desc limit 1;'"
```

Expected the file you uploaded, with its size in bytes; the same row after the restart. A new site already has about 15 documents (images from the site template), so look for your file's title rather than a count.

---

## 12. CI/CD with GitHub Actions

> ✅ **Tested on 22 October 2026** in Asia Pacific (Tokyo), single mode with the Docker runtime ([run 39725947441](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace/actions/runs/39725947441)): build, push to ECR through OIDC, deploy through SSM, and the portlet, the global CSS and the React app all working on a page. The Tomcat runtime's deploy is not yet tested.

Your code (OSGi modules, client extensions, configuration) lives in a **Liferay Workspace** and reaches the instances through GitHub Actions. A ready-made workspace for this guide is **[LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace)** (DXP `2026.q1.13-lts`, a sample OSGi portlet, a global CSS client extension and a React custom element client extension built with Vite).

```text
git push ─▶ build (Gradle, JDK 21) ─▶ image (linux/amd64) ─▶ ECR ─┐
                                   └▶ Tomcat artifacts ─▶ S3 ─────┤
                                                                  ▼  only on "Run workflow" or a v* tag
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

Run them (they set `AWS_REGION`, `AWS_ROLE_ARN`, `ECR_REPOSITORY`, `ARTIFACT_BUCKET`, `LIFERAY_STACK` and `LIFERAY_RUNTIME` as repository **variables**; none of them is a secret). Check them:

```bash
gh variable list --repo <org>/<your-workspace>
```

Then create the GitHub **environment** `ec2`, limited to the `main` branch and `v*` tags: **Settings → Environments → New environment** → `ec2` → **Deployment branches and tags** → **Selected branches and tags** → add branch `main` and tag `v*`. Or with the GitHub CLI:

```bash
REPO=<org>/<your-workspace>
gh api -X PUT "repos/${REPO}/environments/ec2" \
  -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST "repos/${REPO}/environments/ec2/deployment-branch-policies" -f name=main -f type=branch
gh api -X POST "repos/${REPO}/environments/ec2/deployment-branch-policies" -f name='v*' -f type=tag
```

**Approval before each deployment (required reviewers)** needs **GitHub Team or Enterprise** for a private repository; on **GitHub Free** it is available only for public repositories. On a Free organization GitHub refuses it with `Failed to create the environment protection rule. Please ensure the billing plan supports the required reviewers protection rule.` Check your organization's plan with `gh api orgs/<org> --jq .plan.name`. That's why the sample workflow deploys **on demand only** (section 12.3): a push to `main` never deploys by itself, which matters because each deploy restarts Liferay (in single mode it is unavailable for about a minute). On Team or Enterprise you can also add yourself under **Settings → Environments → ec2 → Required reviewers**.

**Check the OIDC subject your repository sends.** Newer repositories use GitHub's **immutable subject** format, which adds the owner and repository IDs:

```bash
gh api repos/<org>/<your-workspace>/actions/oidc/customization/sub
```

If the output shows `"use_immutable_subject":true`, copy its `sub_claim_prefix` (for example `repo:LGSAPAC@85264366/lfrgs-sh-aws-ec2-sample-workspace@1429128939`) into `github_oidc_subject_prefix` in `terraform.tfvars` and run `terraform -chdir=terraform apply` (it changes only the GitHub Actions role's trust policy). Otherwise the `image` job fails with `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`, because the role trusts `repo:<org>/<your-workspace>:...` and the token says `repo:<org>@<id>/<your-workspace>@<id>:...`.

### 12.3 Run the pipeline

Every push and pull request builds; pushes to `main` also build and push the image. **Deploying is on demand**:

- **Run workflow:** **Actions → CI/CD → Run workflow**, choose `main` (or a `v*` tag to redeploy that release), keep **Deploy to the EC2 instances** ticked, **Run workflow**. Or from the CLI:

  ```bash
  gh workflow run ci.yml --repo <org>/<your-workspace> --ref main -f deploy=true
  ```

- **Release tag:** `git tag v1.0.0 && git push origin v1.0.0` builds image `1.0.0` and deploys it. 🔎 Not yet tested.

Tested on 22 October 2026: a push to `main` built and pushed `main-1041124` with `deploy` skipped and Liferay untouched ([run 39729765649](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace/actions/runs/39729765649)); a **Run workflow** with **Deploy** then rolled it out ([run 39730255875](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace/actions/runs/39730255875), `deploy` 1.5 minutes).

| Job | Runs on | What it does |
| --- | --- | --- |
| `build` | Every push and pull request | `./gradlew build dockerDeploy createDockerfile`, checks the Docker context, packages `liferay-artifacts-<tag>.tar.gz` |
| `image` | Pushes to `main`, `v*` tags, manual runs | Builds the `linux/amd64` image, checks its contents, pushes to ECR when the AWS variables exist |
| `deploy` | **On demand**: manual runs with **Deploy** ticked (on `main` or a `v*` tag) and pushed `v*` tags, when `LIFERAY_STACK` is set. **Skipped** on pushes to `main` | Runs in environment `ec2` (waits for approval if it has required reviewers), then rolls out through SSM, one node at a time, and fails on the first node that does not become ready |

**Image tags:** a `v1.2.0` git tag gives `1.2.0`; anything else gives `<branch>-<short-sha>`, for example `main-1a2b3c4`.

Tested timings (single mode): `build` 1 minute, `image` 4 minutes (about 3.1 GB, 2.0 GB compressed in ECR), `deploy` 2 minutes, of which Liferay's restart is about 1 minute.

**In high availability** (tested on 22 October 2026, two nodes, [run 39799656603](https://github.com/LGSAPAC/lfrgs-sh-aws-ec2-sample-workspace/actions/runs/39799656603)): the deploy took 5 minutes, one node at a time, each taken out of the load balancer first (section 9.5):

```text
[liferay-ec2 15:03:13] Taking this node out of the load balancer (in-flight requests finish first)
[liferay-ec2 15:03:46] Load balancer state of this node: unused
...
Liferay is ready
[liferay-ec2 15:04:53] Putting this node back into the load balancer
[liferay-ec2 15:04:59] Load balancer state of this node: healthy
[liferay-ec2 15:04:59] Deployed ...dxp-custom:main-a0f664c
```

A probe requesting `/c/portal/robots` through the ALB every 2 seconds during the whole rollout got **544 × HTTP 200, no 502s, and 3 timeouts** (no answer within 5 seconds) in one **15-second window** right after node 1 was restarted, while node 2 served alone. The likely cause is node 2 taking over the cluster coordinator's role from node 1; it was not confirmed, because node 2's container log was replaced by its own deploy a minute later. Accepted for this PoC; for production, keep Liferay's logs outside the container (for example CloudWatch Logs) so such windows can be diagnosed, and expect a few slow seconds per rollout. To measure it yourself, run this during a deploy:

```bash
URL=$(terraform -chdir=terraform output -raw liferay_url)
while :; do echo "$(date -u +%T) $(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "${URL}/c/portal/robots")"; sleep 2; done | grep -v ' 200$'
```

### 12.4 Roll back

- **Docker runtime:** a node that does not become ready rolls itself back to the previous image, and the rollout stops, so other nodes keep the old image. To return to an older build on purpose, **Run workflow** on its `v*` tag, re-run the old workflow run's `deploy` job, or run on the stack: `scripts/run-on-stack.sh <stack> liferay '/opt/liferay-ec2/scripts/deploy-docker.sh <ecr-repo>:<old-tag>'` (HA: one node at a time).
- **Tomcat runtime:** re-run the `deploy` job of the older run (its archive is still in `builds/` for 90 days). Hot deploy replaces bundles with the same symbolic name; to remove a module entirely, delete its jar from `/opt/liferay/osgi/modules` and restart.

### Verify

1. ✅ A push to `main` builds and pushes the image, and the `deploy` job is **skipped** (Liferay keeps running). A **Run workflow** with **Deploy** ticked is green; the `deploy` job's log shows `Final status: Success` and each node's output ends with `Deployed <image>` (Docker) or `Deployment finished` (Tomcat).
2. ✅ ECR has the image:

   ```bash
   aws ecr describe-images --repository-name "${STACK}/dxp-custom" \
     --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags[0], imagePushedAt]' --output text
   ```

3. ✅ Every Liferay node runs it:

   ```bash
   scripts/run-on-stack.sh "${STACK}" liferay 'docker inspect --format "{{.Config.Image}}" liferay 2>/dev/null || cat /opt/liferay/.liferay-ec2-version'
   scripts/run-on-stack.sh "${STACK}" liferay 'sudo /opt/liferay-ec2/scripts/verify-node.sh | grep -E "Liferay image|Image modules|checks"'
   ```

   Expected the ECR image with your build tag, `PASS  Image modules deployed  com.liferay.ec2.sample.portlet-1.0.0.jar`, and `All checks passed`.

   ✅ The client extensions started, and the portlet is registered:

   ```bash
   scripts/run-on-stack.sh "${STACK}" liferay '/opt/liferay-ec2/scripts/liferay-log.sh | grep -E "STARTED (ec2sampleglobalcss|ec2samplereactapp)"'
   scripts/run-on-stack.sh "${STACK}" liferay "docker exec postgres psql -U liferay -d lportal -At -c \"select portletid, active_ from portlet where lower(portletid) like '%ec2%';\""
   ```

   Expected `STARTED ec2sampleglobalcss_7.4.13` and `STARTED ec2samplereactapp_7.4.13` (client extensions start under their project ID, with the DXP version), then `com_liferay_ec2_sample_portlet_Ec2SamplePortlet|t` and a `..._LXC_ec2_sample_react_app|t` row. A module jar baked into the image is installed while Liferay boots, before it logs `STARTED` lines, so the portlet has no `STARTED` line; the `portlet` table and `verify-node.sh` show it instead.

4. ✅ The React app's files are served through the load balancer:

   ```bash
   URL=$(terraform -chdir=terraform output -raw liferay_url)
   curl -s -o /dev/null -w 'main.js: %{http_code} %{content_type}\n' "${URL}/o/ec2-sample-react-app/main.js"
   curl -s -o /dev/null -w 'index.css: %{http_code} %{content_type}\n' "${URL}/o/ec2-sample-react-app/assets/index.css"
   ```

   Expected `200` with a JavaScript and a CSS content type. A `404` means the zip didn't deploy, or its `assemble` block is wrong.

5. ✅ In Liferay, signed in, edit a page (all three tested on 22 October 2026):
   - Add the **EC2 Sample** widget (category **Sample**). It shows *Hello from Liferay self-hosted on Amazon EC2* and the serving node.
   - Add the **EC2 Sample React App** widget (category **Client Extensions**). It shows *Hello from React on Amazon EC2*, then *Signed in as Test Test (test@liferay.com), read from /o/headless-admin-user*, which proves the React app called Liferay's API with your session. The button counts clicks. Signed out, it says you are a guest.
   - Turn on **EC2 Sample Global CSS** for a page: site menu → **Site Builder → Pages** → the page's **⋮** → **Configure** → **Design** tab → **CSS Client Extensions** → **Add CSS Client Extensions** → select it → **Add** → **Save**. To apply it to every page, use the configuration of the pages list itself instead of one page's. The page gets a thin orange border along the top edge; hard-refresh, and sign out or use a private window if the control bar hides it.
   - In HA, both widgets show the same on every node.
   - The product menu's **Applications** tab → **Client Extensions** lists **EC2 Sample Global CSS** and **EC2 Sample React App**. 🔎

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

> ✅ **Tested on 22 and 23 October 2026** in Asia Pacific (Tokyo): single mode destroyed 58 resources in about 1 minute; high availability destroyed 79 in about 10 minutes (RDS 5.5 minutes, NAT gateway 1 minute). Nothing was left afterwards either time, and no RDS snapshot was kept (`force_destroy = true`).

Preview it first, then destroy:

```bash
terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform apply destroy.tfplan
```

The plan should list only this stack's resources (`Plan: 0 to add, 0 to change, 58 to destroy.` in single mode). With `force_destroy = true` (the default), this deletes the S3 bucket and its objects, the ECR images and the RDS instance **without a final snapshot**, and in single mode the instance's disk, which holds the database and Documents and Media. Take any backups you need first. Rebuilding is sections 5 to 7 again (under 10 minutes for single mode).

Remove the workspace's GitHub variables too. Otherwise its next push to `main` fails at **Sign in to AWS**, because the role no longer exists. Without them, the workflow still builds and checks the image, but doesn't push or deploy. You can keep the `ec2` environment for next time.

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

✅ Expected: `0`, `[]` and `0`. The tagging API (the second command) lags: for minutes to hours after a destroy it can still list ARNs of resources that are already gone (in testing: the terminated instance, its volume, security-group rules and the S3 endpoint). Check any it lists directly, for example `aws ec2 describe-volumes --volume-ids <vol-id>`, which should fail with `does not exist`; the instance shows `terminated`.

✅ The billable parts are gone (Docker or Tomcat, single or HA):

```bash
aws elbv2 describe-load-balancers --query 'length(LoadBalancers)'
aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'length(NatGateways)'
aws ec2 describe-addresses --query 'length(Addresses)'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'length(Volumes)'
aws rds describe-db-instances --query 'length(DBInstances)'
aws efs describe-file-systems --query 'length(FileSystems)'
aws ecr describe-repositories --query 'length(repositories)'
terraform -chdir=terraform state list | wc -l
```

Expected `0` for each in an account used only for this guide (otherwise, none of them belongs to `${STACK}`). `aws ec2 describe-vpcs` should show only the default VPC. Check **Billing → Bills** the next day: no running charges for EC2, NAT gateway, ALB, RDS or EFS.

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
| No emails arrive (password changes, invitations); log says `Skipping email because the sender is not specified` | No mail server configured | Configure SMTP (for example Amazon SES) in **Control Panel → System → Server Administration → Mail** or in `portal-ext.properties` |
| Liferay never finishes starting; log mentions license | Missing or invalid key, or single-node key in a cluster | Check `/opt/liferay/deploy`, the license log lines, and use a cluster-capable key for HA |
| Liferay shuts down soon after start, log mentions Elasticsearch | Wrong Elasticsearch version or unreachable | `curl http://<es>:9200`; keep 8.19.x; check the search security group |
| Elasticsearch container restarts; log mentions `max virtual memory areas` | `vm.max_map_count` too low | `sysctl vm.max_map_count`; re-run the bootstrap |
| `Elasticsearch analysis plugins` FAIL | Image built without plugins | `docker rmi liferay-elasticsearch:<version>` and re-run the bootstrap |
| `EFS mounted` FAIL / `mount.nfs4: Connection timed out` | Mount target not ready or EFS security group | Wait for both mount targets to be `available`; check port 2049 from the Liferay SG |
| `Permission denied` writing Documents and Media | Ownership | `chown 1000:1000 /mnt/efs/document_library` (or the single-mode folder) |
| HA: node 2 never becomes ready; its log shows `duplicate key value violates unique constraint "release__pkey"` and `BeanLocator is null` | Two nodes started against the empty database at once (fixed in the bootstrap, section 9.6). Nodes created before that fix lack `NODE_INDEX` | On the failed node: add `NODE_INDEX=<n>` and `FIRST_NODE_NAME=<stack>-liferay-1` to `/etc/liferay-ec2/host.env`, re-sync the host files, `docker rm -f liferay`, then run `bootstrap.sh` again |
| A Liferay node logs `index_not_found_exception ... no such index [liferay-<company-id>]` | It started before Elasticsearch was reachable | Restart Liferay on that node (it creates the index at startup), then **Reindex all search indexes** (section 11). New stacks wait for Elasticsearch (section 9.6) |
| Search node: Elasticsearch never starts; log shows `required variable LIFERAY_DOCLIB_DIR is missing a value` | `compose.yaml` from before October 2026 required a Liferay-only variable | Use the current `host/docker/compose.yaml`, re-sync the host files and run `bootstrap.sh` again |
| `ERROR ... DXP Development license validation failed` / `Developer licenses do not allow for clustering` | The image's built-in trial key is active in a cluster | Set `LIFERAY_CONTAINER_DISABLE_TRIAL_LICENSE: "true"` (not `LIFERAY_DISABLE_TRIAL_LICENSE`) as in `compose.yaml`, then recreate the container: `docker compose up -d --force-recreate liferay` |
| Right after a `terraform apply` that changed the instance role, instances get `AccessDenied` for the new actions | IAM changes take a few seconds to reach every AWS service | Wait about 30 seconds and retry |
| Users get HTTP 502 for about 2.5 minutes after a node stops | A target group created before October 2026 checks every 30 seconds and needs 5 failures | `terraform -chdir=terraform apply` (it updates the health check in place to 10 seconds and 2 failures) |
| HA: each node's JGroups view shows `(1)` | Nodes can't reach each other on 7800-7801, or JDBC_PING table not written | Check the `liferay_cluster` SG rule; `select * from jgroupsping`; check the bind address in `/opt/liferay/jgroups/control.xml` is the node's private IP |
| HA: `JDBC_PING` or `JGROUPSPING` errors at startup | Protocol attribute differs in your JGroups version (the stack is tested with DXP 2026.Q1.13) | Take `udp_control.xml` from the `com.liferay.portal.cluster.multiple` module of your release and apply the same two substitutions (section 9.4) |
| Users signed out repeatedly | Stickiness off, or a node restarting | Check the target group's stickiness; check node health |
| Pages load without CSS, or links use `http://` behind HTTPS | Forwarded headers or protocol not set | Section 10 step 4; check `web.server.protocol=https` in the rendered `portal-ext.properties` |
| Redirect loop | HTTPS redirect configured in two places | Redirect only at the ALB |
| Large uploads fail | ALB idle timeout (300 s here) or Liferay upload limits | Raise `idle_timeout`; check Liferay's upload size settings |
| GitHub Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The token's subject doesn't match the role's trust policy: most often GitHub's **immutable subject** format (`repo:<org>@<id>/<name>@<id>:...`), otherwise a wrong repository name, branch or environment | Section 12.2: set `github_oidc_subject_prefix`. Also check `github_repository` is `owner/name` exactly, the deploy job uses environment `ec2`, and the run is on `main` or a `v*` tag |
| GitHub: `Please ensure the billing plan supports the required reviewers protection rule` | Required reviewers need GitHub Team or Enterprise for private repositories | Create the environment without reviewers (section 12.2), or use an organization on Team or Enterprise |
| Custom image deployed, client extensions work, but your OSGi modules are missing (no widget, `Image modules deployed` FAIL) | Something is mounted under `/etc/liferay/mount`, so the image ignores `/mnt/liferay/deploy` where the workspace puts module jars | Mount at `/mnt/liferay/files` as in `host/docker/compose.yaml` (section 7), then `docker compose up -d --force-recreate liferay` |
| The site suddenly times out (`curl` exit 28, browser spins) though the target is `healthy` | Your public IP changed (another network or a VPN) and is no longer in `allowed_cidrs` | Compare `curl -s https://checkip.amazonaws.com` with `allowed_cidrs`, update it and `terraform -chdir=terraform apply`. A VPN's shared exit IP lets others on that VPN reach the site too |
| GitHub Actions deploy: `No running instances tagged ...` | `LIFERAY_STACK` variable wrong | Set it to `terraform -chdir=terraform output -raw stack_name` |
| Deploy rolls back: `New image did not become ready` | Your build fails to start | Read the 200 log lines in the job output; fix and push again |
| `exec format error` | ARM image on x86 instances | Build with `--platform linux/amd64` (the workflow does) |
| Docker Hub `toomanyrequests` | Anonymous pull rate limit | Retry later, sign in to Docker Hub on the instance, or mirror `liferay/dxp`, `postgres` and Elasticsearch to ECR |

---

## 17. Assumptions to verify

Confirm these before relying on the guide for anything beyond a sandbox:

1. ✅ **Health check path** `/c/portal/robots` returns 200 on DXP 2026.Q1 once Liferay is ready, **provided the request's host name is in `virtual.hosts.valid.hosts`** (section 8.1). Confirmed on 22 October 2026; the guide originally missed the valid-hosts list, which made the ALB health check fail with 500.
2. ✅ **Docker mount path**: the `liferay/dxp` 2026.Q1 image copies `<mount>/files` into `/opt/liferay` at startup, where `<mount>` is `/etc/liferay/mount` if it exists, otherwise `/mnt/liferay`. This guide mounts at `/mnt/liferay/files` so module jars the workspace bakes into `/mnt/liferay/deploy` are deployed too (section 7). Confirmed for `portal-ext.properties`, `deploy/license.xml`, `osgi/configs`, module jars and `jgroups/` (HA).
3. ✅ **JGroups stack** (section 9.4): TCP with `JDBC_PING` (and an explicit `initialize_sql` for PostgreSQL) works with the JGroups version in DXP 2026.Q1.13, and `cluster.link.autodetect.address` behaves with host networking. Confirmed on 22 October 2026; re-check on other releases.
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
