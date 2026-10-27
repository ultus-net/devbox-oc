resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name_prefix}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.vm_subnet_cidr]

  # Private subnet. Blocks the implicit platform egress IP, so an explicit
  # outbound method is mandatory. See docs/decisions.md.
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${var.name_prefix}-vm"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  # Deny inbound from the internet explicitly. Stating the deny is clearer in
  # an audit than relying on an implicit default.
  security_rule {
    name                       = "deny-inbound-internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # SSH is reachable only from inside the VNet. In practice you arrive over
  # the tailnet, which terminates on the host itself.
  security_rule {
    name                       = "allow-inbound-vnet-ssh"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# Explicit egress. Without this the box cannot reach package mirrors, the
# registry, or model APIs.
resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "pip-${var.name_prefix}-nat"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "nat-${var.name_prefix}"
  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.vm.id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

# The NIC deliberately has no public IP address block. This is the whole
# security model: there is nothing to scan.
resource "azurerm_network_interface" "vm" {
  name                = "nic-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_key_vault" "this" {
  name                       = substr("kv-${var.name_prefix}-${random_string.suffix.result}", 0, 24)
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  rbac_authorization_enabled = true
  tags                       = var.tags
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = "vm-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.vm_size
  # `core` is the Fedora CoreOS default account. Ignition sets its
  # authorized_keys, so there is no admin_ssh_key block and no password auth
  # to disable.
  admin_username = "core"
  tags           = var.tags

  network_interface_ids = [azurerm_network_interface.vm.id]

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_sku
    disk_size_gb         = 64
  }

  # A managed image built from Fedora's own Azure VHD. Never a marketplace URN.
  source_image_id = var.os_image_id

  # Ignition, not cloud-init. Fedora CoreOS consumes Ignition only.
  custom_data = base64encode(file("${path.module}/../os/butane/ucore.ign"))

  # No ignore_changes here on purpose. A bootstrap change rolls the VM, and
  # the data disk survives because it is a separate, protected resource.
}

resource "azurerm_managed_disk" "data" {
  name                 = "disk-${var.name_prefix}-data"
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  storage_account_type = var.data_disk_sku
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = 0
  caching            = "ReadWrite"
}

resource "azurerm_role_assignment" "deployer_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "opencode_password" {
  name         = "opencode-password"
  value        = var.opencode_password
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.deployer_kv_admin]
}

resource "azurerm_role_assignment" "vm_kv_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

# Scope the VM identity to this one VM. No subscription-wide compute rights.
resource "azurerm_role_assignment" "vm_self_power" {
  scope                = azurerm_linux_virtual_machine.this.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "vm_disk_snapshot" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Disk Snapshot Contributor"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

locals {
  acr_resource_group = var.acr_resource_group == "" ? azurerm_resource_group.this.name : var.acr_resource_group
}

resource "azurerm_role_assignment" "vm_acr_pull" {
  count = var.acr_name == "" ? 0 : 1

  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${local.acr_resource_group}/providers/Microsoft.ContainerRegistry/registries/${var.acr_name}"
  role_definition_name = "Container Registry Repository Reader"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

resource "azurerm_virtual_machine_extension" "aad_ssh" {
  count = var.azure_ad_ssh_login ? 1 : 0

  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.this.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  tags                       = var.tags
}
