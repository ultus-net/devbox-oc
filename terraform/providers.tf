provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    virtual_machine {
      # Rebuilds are deliberate. Guards against a typo recreating the box.
      delete_os_disk_on_deletion     = true
      skip_shutdown_and_force_delete = false
    }
  }
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "current" {}
