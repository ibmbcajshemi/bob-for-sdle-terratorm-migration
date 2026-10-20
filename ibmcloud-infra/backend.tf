terraform {
  cloud {
    hostname     = "app.terraform.io"
    organization = "tce-to-tfe-migration"

    workspaces {
      name = "ajs-dev-ibmcloud-infra"
    }
  }
}
