output "state_bucket_name" {
  description = "Name of the COS bucket that will store Terraform state for the main project"
  value       = ibm_cos_bucket.tfstate_bucket.bucket_name
}

output "cos_instance_crn" {
  description = "CRN of the COS service instance that owns the state bucket"
  value       = ibm_resource_instance.cos_instance.crn
}

output "s3_endpoint_public" {
  description = "Public S3-compatible endpoint for the state bucket (us-geo cross-region)"
  value       = ibm_cos_bucket.tfstate_bucket.s3_endpoint_public
}
