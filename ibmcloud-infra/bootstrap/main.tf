provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = var.region
}

# ---------------------------------------------------------------------------
# Data: resolve the target Resource Group ID from its name
# ---------------------------------------------------------------------------
data "ibm_resource_group" "group" {
  name = var.resource_group_name
}

# ---------------------------------------------------------------------------
# COS Service Instance — holds the Terraform state bucket
# ---------------------------------------------------------------------------
resource "ibm_resource_instance" "cos_instance" {
  name              = "${var.project_name}-tfstate-cos-${var.environment}"
  service           = "cloud-object-storage"
  plan              = "standard"
  location          = "global"
  resource_group_id = data.ibm_resource_group.group.id

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

# ---------------------------------------------------------------------------
# State Bucket — cross-region (us-geo), standard storage class
# Name must be globally unique; project_name + environment provides sufficient
# differentiation for most cases. If a collision occurs, prefix with an
# account-specific short string via project_name.
# ---------------------------------------------------------------------------
resource "ibm_cos_bucket" "tfstate_bucket" {
  bucket_name           = "${var.project_name}-tfstate-${var.environment}"
  resource_instance_id  = ibm_resource_instance.cos_instance.id
  cross_region_location = "us"
  storage_class         = "standard"
}
