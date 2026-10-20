# ===========================================================================
# COS
# ===========================================================================

output "cos_instance_id" {
  description = "ID of the COS service instance"
  value       = ibm_resource_instance.cos_instance.id
}

output "app_bucket_name" {
  description = "Name of the application COS bucket"
  value       = ibm_cos_bucket.app_bucket.bucket_name
}

output "app_bucket_s3_endpoint_public" {
  description = "Public S3-compatible endpoint for the application bucket"
  value       = ibm_cos_bucket.app_bucket.s3_endpoint_public
}

# ===========================================================================
# VPC
# ===========================================================================

output "vpc_id" {
  description = "ID of the IBM Cloud VPC"
  value       = ibm_is_vpc.vpc.id
}

output "subnet_id" {
  description = "ID of the VPC subnet"
  value       = ibm_is_subnet.subnet.id
}

# ===========================================================================
# VSI
# ===========================================================================

output "vsi_id" {
  description = "ID of the Virtual Server Instance"
  value       = ibm_is_instance.vsi.id
}

output "vsi_floating_ip" {
  description = "Public floating IP address assigned to the VSI"
  value       = ibm_is_floating_ip.vsi_fip.address
}

# ===========================================================================
# Code Engine
# ===========================================================================

output "code_engine_project_id" {
  description = "ID of the Code Engine project"
  value       = ibm_code_engine_project.ce_project.project_id
}

output "code_engine_app_url" {
  description = "Public URL of the deployed Code Engine application"
  value       = ibm_code_engine_app.ce_app.endpoint
}
