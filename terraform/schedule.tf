# Scheduled wake-up. Shutdown is NOT scheduled: the in-host idle gate owns
# that decision so an active session is never killed. See docs/decisions.md.
#
# A Logic App Consumption workflow is used instead of an Azure Function
# because it needs no code, no runtime and no deployment artifact. Built-in
# actions bill at $0.000025 per run, so 22 runs a month is a rounding error.

resource "azurerm_logic_app_workflow" "start" {
  count = var.schedule_start_utc == "" ? 0 : 1

  name                = "la-${var.name_prefix}-start"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "logicapp_start_vm" {
  count = var.schedule_start_utc == "" ? 0 : 1

  scope                = azurerm_linux_virtual_machine.this.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_logic_app_workflow.start[0].identity[0].principal_id
}

resource "azurerm_logic_app_trigger_recurrence" "weekday_morning" {
  count = var.schedule_start_utc == "" ? 0 : 1

  name         = "weekday-morning"
  logic_app_id = azurerm_logic_app_workflow.start[0].id
  frequency    = "Week"
  interval     = 1
  time_zone    = "UTC"

  schedule {
    at_these_hours   = [tonumber(split(":", var.schedule_start_utc)[0])]
    at_these_minutes = [tonumber(split(":", var.schedule_start_utc)[1])]
    week_days        = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
  }
}

resource "azurerm_logic_app_action_custom" "start_vm" {
  count = var.schedule_start_utc == "" ? 0 : 1

  name         = "start-vm"
  logic_app_id = azurerm_logic_app_workflow.start[0].id

  body = jsonencode({
    type = "Http"
    inputs = {
      method = "POST"
      uri    = "https://management.azure.com/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_resource_group.this.name}/providers/Microsoft.Compute/virtualMachines/vm-${var.name_prefix}/start?api-version=2024-07-01"
      authentication = {
        type = "ManagedServiceIdentity"
      }
    }
    runAfter = {}
  })
}
