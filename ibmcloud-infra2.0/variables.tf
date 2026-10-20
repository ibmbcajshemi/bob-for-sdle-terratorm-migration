# ===========================================================================
# Authentication
# ===========================================================================

variable "ibmcloud_api_key" {
  type        = string
  description = "IBM Cloud API Key. Pass via TF_VAR_ibmcloud_api_key — never hardcode."
  sensitive   = true
}

variable "cos_access_key" {
  type        = string
  description = "HMAC access key (key_id) for the COS state bucket backend. Pass via AWS_ACCESS_KEY_ID or -backend-config."
  sensitive   = true
  default     = ""
}

variable "cos_secret_key" {
  type        = string
  description = "HMAC secret key for the COS state bucket backend. Pass via AWS_SECRET_ACCESS_KEY or -backend-config."
  sensitive   = true
  default     = ""
}

# ===========================================================================
# Common
# ===========================================================================

variable "project_name" {
  type        = string
  description = "Short project identifier used as a naming prefix for all resources."
  default     = "ibmcloud-infra-v2"
}

variable "environment" {
  type        = string
  description = "Deployment environment. Allowed values: dev, prod."
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be one of: dev, prod."
  }
}

variable "region" {
  type        = string
  description = "IBM Cloud region for VPC, Code Engine, and provider configuration."
  default     = "us-south"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the IBM Cloud Resource Group to deploy resources into."
  default     = "Default"
}

# ===========================================================================
# COS State Backend (populated at terraform init time — not used as TF resources)
# ===========================================================================

variable "state_bucket_name" {
  type        = string
  description = "Name of the COS bucket used to store Terraform state (created by bootstrap/)."
  default     = ""
}

variable "state_bucket_endpoint" {
  type        = string
  description = "Public S3 endpoint for the state bucket (output from bootstrap/)."
  default     = "https://s3.us.cloud-object-storage.appdomain.cloud"
}

# ===========================================================================
# Application COS Bucket
# ===========================================================================

variable "app_bucket_name" {
  type        = string
  description = "Globally unique name for the application COS bucket."
}

variable "app_storage_class" {
  type        = string
  description = "Storage class for the application bucket. standard | smart | cold | vault."
  default     = "standard"

  validation {
    condition     = contains(["standard", "smart", "cold", "vault"], var.app_storage_class)
    error_message = "app_storage_class must be one of: standard, smart, cold, vault."
  }
}

variable "enable_versioning" {
  type        = bool
  description = "Enable object versioning on the application bucket. Recommended true for prod."
  default     = false
}

# ===========================================================================
# VPC Networking
# ===========================================================================

variable "vpc_address_prefix" {
  type        = string
  description = "CIDR block for the VPC address prefix."
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR block for the single VPC subnet."
  default     = "10.10.1.0/24"
}

variable "zone" {
  type        = string
  description = "IBM Cloud availability zone for the subnet and VSI (e.g. us-south-1)."
  default     = "us-south-1"
}

# ===========================================================================
# VSI (Virtual Server Instance)
# ===========================================================================

variable "vsi_image_name" {
  type        = string
  description = "Name of the IBM Cloud VPC stock image to use for the VSI."
  default     = "ibm-redhat-8-8-minimal-amd64-3"
}

variable "vsi_profile" {
  type        = string
  description = "VPC instance profile for the VSI (e.g. bx2-2x8, bx2-4x16)."
  default     = "bx2-2x8"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key material to register in IBM Cloud VPC for VSI access."
}

# ===========================================================================
# Code Engine
# ===========================================================================

variable "ce_app_image" {
  type        = string
  description = "Container image reference for the Code Engine application."
  default     = "icr.io/codeengine/helloworld"
}

variable "ce_app_min_scale" {
  type        = number
  description = "Minimum number of running instances (0 = scale to zero)."
  default     = 0
}

variable "ce_app_max_scale" {
  type        = number
  description = "Maximum number of running instances."
  default     = 5
}

variable "ce_app_cpu" {
  type        = string
  description = "CPU allocation per Code Engine app instance (e.g. 0.25, 0.5, 1)."
  default     = "0.25"
}

variable "ce_app_memory" {
  type        = string
  description = "Memory allocation per Code Engine app instance (e.g. 0.5G, 1G, 2G)."
  default     = "0.5G"
}
