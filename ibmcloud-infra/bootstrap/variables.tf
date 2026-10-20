variable "ibmcloud_api_key" {
  type        = string
  description = "IBM Cloud API Key. Pass via TF_VAR_ibmcloud_api_key environment variable — never hardcode."
  sensitive   = true
}

variable "region" {
  type        = string
  description = "IBM Cloud region (e.g., us-south, us-east, eu-gb)"
  default     = "us-south"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the IBM Cloud Resource Group to deploy into"
  default     = "Default"
}

variable "project_name" {
  type        = string
  description = "Short project identifier used as a naming prefix for all resources"
  default     = "ibmcloud-infra"
}

variable "environment" {
  type        = string
  description = "Deployment environment. Allowed values: dev, prod"
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be one of: dev, prod"
  }
}
