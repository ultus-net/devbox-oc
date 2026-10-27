variable "subscription_id" {
  type        = string
  description = "Target subscription. Set explicitly so a wrong az context cannot apply to the wrong subscription."
}

variable "location" {
  type        = string
  description = "Azure region for every resource."
  default     = "westeurope"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all resource names. Keep it short; storage and registry names have tight limits."
  default     = "devbox-oc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,14}$", var.name_prefix))
    error_message = "Use 3 to 15 lowercase alphanumerics or hyphens, starting with a letter."
  }
}

variable "vm_size" {
  type        = string
  description = "VM SKU. B2as_v2 (2 vCPU / 8 GiB) is the default balance of cost and headroom."
  default     = "Standard_B2as_v2"
}

variable "os_image_id" {
  type        = string
  description = "Managed image ID of the published ucore image. Never a marketplace URN."

  validation {
    condition     = can(regex("^/subscriptions/.+/providers/Microsoft.Compute/images/.+$", var.os_image_id))
    error_message = "Must be a managed image resource ID, not a marketplace reference."
  }
}

variable "vnet_cidr" {
  type        = string
  description = "VNet address space."
  default     = "10.42.0.0/16"
}
variable "vm_subnet_cidr" {
  type        = string
  description = "Subnet for the VM. No public IP, no inbound rules."
  default     = "10.42.10.0/24"
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Explicit egress. Required on subnets created after March 2026, which default to private."
  default     = true
}

variable "data_disk_size_gb" {
  type        = number
  description = "Data disk for repos and the OpenCode database."
  default     = 128
}

variable "data_disk_sku" {
  type        = string
  description = "Managed disk SKU for the data disk."
  default     = "StandardSSD_LRS"
}

variable "os_disk_sku" {
  type        = string
  description = "Managed disk SKU for the OS disk."
  default     = "Premium_LRS"
}

variable "acr_name" {
  type        = string
  description = "Existing Azure Container Registry that holds the devbox image. Required: without it there is no pull path."

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.acr_name))
    error_message = "ACR names are 5 to 50 lowercase alphanumerics. Leaving this empty removes the only image pull path."
  }
}

variable "acr_resource_group" {
  type        = string
  description = "Resource group of the ACR. Defaults to the devbox resource group, which is usually wrong because the registry usually predates the devbox."
  default     = ""
}

variable "acr_abac_enabled" {
  type        = bool
  description = "True when the registry's role assignment permissions mode is 'rbac-abac'. Legacy 'rbac' mode honours AcrPull and ignores the ABAC role names."
  default     = true
}

variable "opencode_password" {
  type        = string
  description = "OpenCode server password. Stored in Key Vault; never written to state-consuming outputs."
  sensitive   = true
}

variable "tailscale_authkey" {
  type        = string
  description = "Reusable, tagged Tailscale auth key. Use a key scoped to this device only."
  sensitive   = true
}

variable "azure_ad_ssh_login" {
  type        = bool
  description = "Install AADSSHLoginForLinux so you can SSH with Entra credentials. Requires system-assigned identity."
  default     = true
}

variable "schedule_start_utc" {
  type        = string
  description = "Weekday start time, HH:MM in UTC. Empty disables the scheduled start."
  default     = "06:45"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource. Inherited cost and ownership tags belong here."
  default = {
    workload = "devbox-oc"
    managed  = "terraform"
  }
}
