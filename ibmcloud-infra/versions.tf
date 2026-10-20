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
  # Per-environment key: ibmcloud-infra/dev/terraform.tfstate
  #                      ibmcloud-infra/prod/terraform.tfstate
  # ---------------------------------------------------------------------------
  #backend "s3" {
  #  # Populated at init time via -backend-config flags or environment variables.
  #  # bucket, access_key, and secret_key are intentionally left blank here so
  #  # that credentials are never committed to source control.
  #  bucket = ""
  #  key    = "ibmcloud-infra/terraform.tfstate"
  #  region = "us-geo"
  #
  #  endpoints = {
  #    s3 = "https://s3.us.cloud-object-storage.appdomain.cloud"
  #  }
  #
  #  skip_region_validation      = true
  #  skip_credentials_validation = true
  #  skip_metadata_api_check     = true
  #  skip_requesting_account_id  = true
  #}

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.68.0"
    }
  }
}
