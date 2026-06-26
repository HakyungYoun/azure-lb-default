data "azurerm_resource_group" "rg" {
  for_each = toset([for k, v in var.load_balancers : v.resource_group_name])
  name     = each.key
}
