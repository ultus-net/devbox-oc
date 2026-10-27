# A main.tf with the lifecycle block stripped from the data disk.
# Fixture for the non-vacuity proof: data_disk_protected.sh must FAIL on this.
resource "azurerm_managed_disk" "data" {
  name                 = "disk-devbox-oc-data"
  resource_group_name  = "rg-devbox-oc"
  location             = "westeurope"
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 128
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = "vm"
  lun                = 0
  caching            = "ReadWrite"
}
