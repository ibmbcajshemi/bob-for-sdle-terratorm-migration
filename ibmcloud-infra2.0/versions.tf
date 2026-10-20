terraform {
  required_version = ">= 1.5.0"

  # ---------------------------------------------------------------------------
  # Remote backend — IBM Cloud Object Storage (S3-compatible, HMAC credentials)
  # Initialise with:
  #   terraform init \
  #     -backend-config="bucket=<state-bucket-name>" \
  #     -backend-config="access_key=<hmac-access-key>" \
  #     -backend-config="secret_key=<hmac-secret-key>"
  # Or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY before running init.
  # Per-environment key: ibmcloud-infra-v2/dev/terraform.tfstate
  #                      ibmcloud-infra-v2/prod/terraform.tfstate
  # ---------------------------------------------------------------------------
  

  

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.68.0"
    }
  }
}
