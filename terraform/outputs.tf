output "resource_group" {
  value       = azurerm_resource_group.this.name
  description = "Resource group holding the devbox."
}

output "vm_name" {
  value       = azurerm_linux_virtual_machine.this.name
  description = "VM name, for az vm start and az ssh vm."
}

output "vm_private_ip" {
  value       = azurerm_network_interface.vm.private_ip_address
  description = "Private address. Reachable only over the tailnet or from inside the VNet."
}

output "vm_identity_principal_id" {
  value       = azurerm_linux_virtual_machine.this.identity[0].principal_id
  description = "System-assigned identity. Grant this no rights beyond what this module already assigns."
}

output "data_disk_id" {
  value       = azurerm_managed_disk.data.id
  description = "Data disk holding repos and the OpenCode database. Protected from destroy."
}

output "key_vault_name" {
  value       = azurerm_key_vault.this.name
  description = "Vault holding the server password and the tailnet auth key."
}

output "next_steps" {
  value       = <<-EOT
    1. Point DNS-independent clients at the tailnet name:
         opencode --server https://<host>.<tailnet>.ts.net
    2. Pair the desktop app:
         opencode pair --url https://<host>.<tailnet>.ts.net
    3. Confirm the idle probe auth scheme (docs/superpowers/specs/2026-10-27-devbox-opencode-design.md, open question 6).
  EOT
  description = "Post-apply checklist."
}
