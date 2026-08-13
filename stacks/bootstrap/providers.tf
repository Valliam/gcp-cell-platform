terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # First apply runs with local state, then migrates here. See the header
  # comment in main.tf.
  backend "gcs" {}
}

provider "google" {}
