# Fixture for the non-vacuity proof of no_scheduled_stop.sh.
# A file containing the forbidden literal must make the scan fail.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "bad" {
  virtual_machine_id    = "vm"
  location              = "westeurope"
  enabled               = true
  daily_recurrence_time = "1900"
  timezone              = "UTC"
}

resource "azurerm_logic_app_workflow" "start" {
  name = "la-start"
}
