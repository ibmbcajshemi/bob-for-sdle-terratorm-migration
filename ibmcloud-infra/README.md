# ibmcloud-infra

Terraform Community Edition project that provisions the following IBM Cloud resources:

| Resource | Type | Description |
|---|---|---|
| COS Service Instance | `ibm_resource_instance` | Cloud Object Storage service (standard plan) |
| Application Bucket | `ibm_cos_bucket` | S3-compatible bucket for application data |
| VPC | `ibm_is_vpc` | IBM Cloud Virtual Private Cloud |
| Subnet | `ibm_is_subnet` | Single VPC subnet with public gateway |
| Security Group | `ibm_is_security_group` | SSH/HTTP/HTTPS inbound, all outbound |
| VSI | `ibm_is_instance` | RHEL 8 virtual server (bx2-2x8 dev / bx2-4x16 prod) |
| Floating IP | `ibm_is_floating_ip` | Public IP for VSI SSH access |
| Code Engine Project | `ibm_code_engine_project` | Serverless container runtime project |
| Code Engine App | `ibm_code_engine_app` | HTTP-accessible containerised application |

Remote state is stored in IBM Cloud Object Storage using the S3-compatible backend
(HMAC credentials). The state bucket is created separately via `bootstrap/`.

---

## Prerequisites

- [Terraform CLI](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- IBM Cloud API Key (`ibmcloud_api_key`)
- IBM Cloud COS HMAC credentials (`access_key` / `secret_key`) — generated from the
  state bucket's service credentials with `"HMAC": true`
- An SSH public key for VSI access

---

## Quick Start

### Step 1 — Create the state bucket (one-time)

```bash
cd ibmcloud-infra/bootstrap

terraform init

terraform apply \
  -var="ibmcloud_api_key=$TF_VAR_ibmcloud_api_key" \
  -var="environment=dev"
```

Note the `state_bucket_name` and `s3_endpoint_public` outputs — you will need them in Step 2.

### Step 2 — Initialise the main project (once per environment)

```bash
cd ibmcloud-infra

terraform init \
  -backend-config="bucket=<state-bucket-name-from-step-1>" \
  -backend-config="key=ibmcloud-infra/dev/terraform.tfstate" \
  -backend-config="access_key=<hmac-access-key>" \
  -backend-config="secret_key=<hmac-secret-key>"
```

> Tip: export `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` before running `init`
> instead of passing them on the command line.

### Step 3 — Plan and apply

```bash
# Dev
terraform plan \
  -var-file=environments/dev.tfvars \
  -var="ibmcloud_api_key=$TF_VAR_ibmcloud_api_key" \
  -var="ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"

terraform apply \
  -var-file=environments/dev.tfvars \
  -var="ibmcloud_api_key=$TF_VAR_ibmcloud_api_key" \
  -var="ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"

# Prod (re-init with prod state key first)
terraform init -reconfigure \
  -backend-config="bucket=<state-bucket-name>" \
  -backend-config="key=ibmcloud-infra/prod/terraform.tfstate" \
  -backend-config="access_key=<hmac-access-key>" \
  -backend-config="secret_key=<hmac-secret-key>"

terraform apply \
  -var-file=environments/prod.tfvars \
  -var="ibmcloud_api_key=$TF_VAR_ibmcloud_api_key" \
  -var="ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"
```

---

## Project Structure

```
ibmcloud-infra/
├── bootstrap/              # One-time state bucket creation (local backend)
│   ├── versions.tf
│   ├── variables.tf
│   ├── main.tf
│   └── outputs.tf
├── versions.tf             # S3 remote backend + IBM provider constraint
├── providers.tf            # IBM provider configuration
├── variables.tf            # All input variables
├── main.tf                 # All resource definitions
├── outputs.tf              # Key resource outputs
└── environments/
    ├── dev.tfvars          # Dev environment variable values
    └── prod.tfvars         # Prod environment variable values
```

---

## Environment Differences

| Setting | Dev | Prod |
|---|---|---|
| VPC CIDR | 10.10.0.0/16 | 10.20.0.0/16 |
| VSI Profile | bx2-2x8 (2 vCPU, 8 GB) | bx2-4x16 (4 vCPU, 16 GB) |
| Storage Class | standard | smart |
| Object Versioning | disabled | enabled |
| Archive Rule | none | Glacier after 90 days |
| CE min_scale | 0 (scale to zero) | 1 (always-on) |
| CE max_scale | 3 | 10 |
| CE CPU / Memory | 0.25 / 0.5G | 0.5 / 1G |

---

## Security Notes

- **Never commit credentials** — `ibmcloud_api_key`, `ssh_public_key`, and HMAC keys
  are always passed at runtime via environment variables or `-var` flags.
- HMAC credentials are scoped to the COS instance that owns the state bucket.
- SSH access is open to `0.0.0.0/0` on port 22 by default — restrict
  `inbound_ssh` security group rule to your IP range before production use.
- `ibmcloud_api_key` and `ssh_public_key` are marked `sensitive = true` in
  `variables.tf` and will not appear in Terraform plan/apply output.

---

## Outputs

| Output | Description |
|---|---|
| `cos_instance_id` | COS service instance ID |
| `app_bucket_name` | Application bucket name |
| `app_bucket_s3_endpoint_public` | Public S3 endpoint for the app bucket |
| `vpc_id` | VPC ID |
| `subnet_id` | Subnet ID |
| `vsi_id` | VSI instance ID |
| `vsi_floating_ip` | VSI public floating IP address |
| `code_engine_project_id` | Code Engine project ID |
| `code_engine_app_url` | Code Engine application public URL |
