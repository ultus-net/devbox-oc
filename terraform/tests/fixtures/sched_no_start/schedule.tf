# Fixture proving the scheduled-start check is not vacuous: no Logic App here,
# so no_scheduled_stop.sh must fail on the second assertion.
resource "null_resource" "nothing" {}
