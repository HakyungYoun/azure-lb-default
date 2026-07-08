data "azurerm_resource_group" "rg" {
  for_each = toset([for k, v in var.load_balancers : v.resource_group_name])
  name     = each.key
}

# 내부 프론트엔드(subnet_name 지정)용 서브넷 조회
data "azurerm_subnet" "frontend" {
  for_each = {
    for k, cfg in local.flattened_frontend_configs : k => cfg
    if cfg.subnet_name != null
  }

  name                 = each.value.subnet_name
  virtual_network_name = each.value.vnet_name
  resource_group_name  = coalesce(
    each.value.vnet_rg_name,
    var.load_balancers[each.value.lb_key].resource_group_name
  )
}
