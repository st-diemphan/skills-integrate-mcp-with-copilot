# CI/CD Workflows

This document describes all GitHub Actions workflows in this repository, their triggers, required configuration, and IAM permissions.

---

## Table of Contents

- [CI Workflow](#ci-workflow)
- [CD Workflow](#cd-workflow)
- [Rollback Workflow](#rollback-workflow)
- [ECS Task Runner](#ecs-task-runner)
- [Scheduled Tasks](#scheduled-tasks)
- [Terraform Plan](#terraform-plan)
- [Terraform Apply](#terraform-apply)
- [Composite Actions](#composite-actions)
- [ECS Task Definitions](#ecs-task-definitions)
- [IAM Policies](#iam-policies)
- [Repository Configuration](#repository-configuration)

---

## CI Workflow

**File:** `.github/workflows/ci.yml`

### Triggers

| Event         | Branches / Filters                         |
|---------------|--------------------------------------------|
| `push`        | `main`, `develop`, `feature/**`            |
| `pull_request`| All PRs                                    |

### Steps

1. Checkout code
2. Set up Python 3.11 with pip caching
3. Install dependencies (`requirements.txt` + dev tools)
4. **Lint** – `flake8 src/`
5. **Type check** – `mypy src/`
6. **Unit tests** – `pytest tests/`
7. **Docker build** – validates the `Dockerfile` produces a valid image

### Concurrency

Duplicate runs for the same branch/PR are cancelled automatically.

---

## CD Workflow

**File:** `.github/workflows/cd.yml`

### Triggers

| Branch    | Environment |
|-----------|-------------|
| `develop` | DEV         |
| `staging` | STG         |
| `main`    | PROD        |

### Steps

1. Build Docker image and tag with commit SHA + `<env>-latest`
2. Push both tags to Amazon ECR
3. Download the current ECS task definition
4. Inject the new image URI into the task definition
5. Register the updated task definition and deploy via rolling update
6. Wait until the ECS service reaches a stable state
7. Print a deployment summary table

### Authentication

Uses **GitHub OIDC** (`aws-actions/configure-aws-credentials@v4`).
No long-lived AWS credentials are stored in repository secrets.

---

## Rollback Workflow

**File:** `.github/workflows/rollback.yml`

### Trigger

`workflow_dispatch` – manual only.

### Inputs

| Input         | Required | Description                                    |
|---------------|----------|------------------------------------------------|
| `environment` | ✅       | Target environment (`dev`, `stg`, `prod`)       |
| `image_tag`   | ✅       | ECR image tag to roll back to (e.g. `prod-abc1234`) |
| `reason`      | ❌       | Free-text reason for the rollback              |

### Process

1. Fetches the current ECS task definition
2. Swaps the container image to the specified tag using `jq`
3. Registers the modified task definition as a new revision
4. Forces a new ECS deployment
5. Waits for service stability

---

## ECS Task Runner

**File:** `.github/workflows/ecs-task-runner.yml`

### Trigger

`workflow_dispatch` – manual only.

### Inputs

| Input            | Required | Default                     | Description                            |
|------------------|----------|-----------------------------|----------------------------------------|
| `environment`    | ✅       | —                           | Target environment                     |
| `command`        | ✅       | `python -m scripts.migrate` | Shell command to run inside container  |
| `container_name` | ❌       | `mergington-api`            | Container name in the task definition  |

### Process

1. Resolves VPC subnet IDs and security group IDs from repository variables
2. Runs a standalone Fargate task with the overridden command
3. Waits for the task to stop
4. Reads the container exit code and fails the workflow if non-zero

---

## Scheduled Tasks

**File:** `.github/workflows/scheduled.yml`

### Jobs

| Job                 | Schedule (UTC)     | Description                              |
|---------------------|--------------------|------------------------------------------|
| `health-check`      | Daily at 02:00     | HTTP GET to `/activities` on all envs    |
| `dependency-audit`  | Mondays at 06:00   | `pip-audit` + `safety` vulnerability scan |

Both jobs can also be triggered manually via `workflow_dispatch`.

---

## Terraform Plan

**File:** `.github/workflows/terraform-plan.yml`

### Trigger

`pull_request` that modifies files under `terraform/`.

### Steps

1. Configure AWS credentials (OIDC)
2. `terraform init` with provider cache
3. `terraform validate`
4. `terraform plan -out=tfplan.binary`
5. Post plan output as a PR comment (replaces previous bot comment)
6. Fail the workflow if `terraform plan` exits with a non-zero/non-2 code

---

## Terraform Apply

**File:** `.github/workflows/terraform-apply.yml`

### Trigger

`push` to `main` that modifies files under `terraform/`.

### Steps

1. Configure AWS credentials (OIDC)
2. `terraform init`
3. `terraform validate`
4. `terraform plan -out=tfplan.binary`
5. `terraform apply -auto-approve tfplan.binary`
6. `terraform output` (for logs)

> **Note:** This job uses the `prod` GitHub environment, so it requires manual approval if you configure an environment protection rule in repository settings.

---

## Composite Actions

### `.github/actions/setup-python/action.yml`

Reusable action that sets up Python, installs pip, and optionally installs dev tools.

**Inputs:**

| Input                | Default          | Description                              |
|----------------------|------------------|------------------------------------------|
| `python-version`     | `3.11`           | Python version                           |
| `requirements-file`  | `requirements.txt` | Path to requirements file              |
| `install-dev-tools`  | `false`          | Install flake8/mypy/pytest/httpx         |

**Usage:**

```yaml
- uses: ./.github/actions/setup-python
  with:
    python-version: "3.11"
    install-dev-tools: "true"
```

---

## ECS Task Definitions

Located in `task-definitions/`:

| File        | Environment | CPU   | Memory |
|-------------|-------------|-------|--------|
| `dev.json`  | DEV         | 256   | 512 MB |
| `stg.json`  | STG         | 512   | 1 GB   |
| `prod.json` | PROD        | 1024  | 2 GB   |

Replace `ACCOUNT_ID` with your AWS account ID before use.

---

## IAM Policies

Located in `iam-policies/`:

| File                           | Used by              | Permissions granted                        |
|--------------------------------|----------------------|--------------------------------------------|
| `github-actions-deploy.json`   | CD workflow          | ECR push, ECS deploy, PassRole             |
| `github-actions-terraform.json`| Terraform workflows  | S3/DynamoDB state, ECS/ECR infra, IAM roles|
| `github-actions-ops.json`      | Rollback, task runner| ECS rollback/run-task, CloudWatch logs     |

---

## Repository Configuration

### Required Repository Variables (`vars.*`)

| Variable           | Description                                           |
|--------------------|-------------------------------------------------------|
| `ECR_REGISTRY`     | ECR registry URL (e.g. `123456789.dkr.ecr.us-east-1.amazonaws.com`) |
| `AWS_ROLE_DEV`     | IAM role ARN for DEV deployments (OIDC)               |
| `AWS_ROLE_STG`     | IAM role ARN for STG deployments (OIDC)               |
| `AWS_ROLE_PROD`    | IAM role ARN for PROD deployments (OIDC)              |
| `AWS_ROLE_TERRAFORM` | IAM role ARN for Terraform (OIDC)                   |
| `DEV_APP_URL`      | Public URL for the DEV environment                    |
| `STG_APP_URL`      | Public URL for the STG environment                    |
| `PROD_APP_URL`     | Public URL for the PROD environment                   |
| `DEV_SUBNET_IDS`   | Comma-separated subnet IDs for DEV Fargate tasks      |
| `STG_SUBNET_IDS`   | Comma-separated subnet IDs for STG Fargate tasks      |
| `PROD_SUBNET_IDS`  | Comma-separated subnet IDs for PROD Fargate tasks     |
| `DEV_SG_IDS`       | Security group IDs for DEV Fargate tasks              |
| `STG_SG_IDS`       | Security group IDs for STG Fargate tasks              |
| `PROD_SG_IDS`      | Security group IDs for PROD Fargate tasks             |

### OIDC Trust Policy

Add this trust relationship to each IAM role referenced above (adjust the `sub` condition as needed):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
        }
      }
    }
  ]
}
```

### GitHub Environments

Create the following environments in **Settings → Environments**:

| Environment | Protection rules recommended          |
|-------------|---------------------------------------|
| `dev`       | None (auto-deploy)                    |
| `stg`       | Required reviewer optional            |
| `prod`      | Required reviewer, deployment branches: `main` only |
