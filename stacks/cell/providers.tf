terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend configuration: the bucket is fixed but the prefix is
  # per-cell, supplied at init time. This is what lets one root module hold the
  # state of every cell without their states ever touching.
  #
  #   terraform init -backend-config="bucket=..." -backend-config="prefix=cells/acme/prod-syd"
  backend "gcs" {}
}

provider "google" {
  # No credentials block and no key file. Locally this resolves to the
  # operator's ADC; in CI it resolves to the Workload Identity Federation
  # credential minted by google-github-actions/auth.
  region = local.cell.region
}

provider "google-beta" {
  region = local.cell.region
}
