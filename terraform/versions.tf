# Pin every provider and the Terraform version. Never a range.
terraform {
  required_version = "~> 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
  }

  # State lives outside the repo. Swap for a backend block before the first
  # real apply, and never commit local state.
  # backend "azurerm" {}
}
