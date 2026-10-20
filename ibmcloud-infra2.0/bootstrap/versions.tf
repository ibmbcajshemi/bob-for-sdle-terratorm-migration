terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    path = "terraform.tfstate"
  }

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.68.0"
    }
  }
}
