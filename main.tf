locals {
  # frontend_configs를 "lb_key.config_key" 형태로 펼침
  flattened_frontend_configs = merge([
    for lb_key, lb in var.load_balancers : {
      for cfg_key, cfg in lb.frontend_configs :
      "${lb_key}.${cfg_key}" => merge(cfg, {
        lb_key = lb_key
      })
    }
  ]...)

  # rules를 "lb_key.rule_key" 형태로 펼침
  flattened_rules = merge([
    for lb_key, lb in var.load_balancers : {
      for rule_key, rule in lb.lb_settings.rules :
      "${lb_key}.${rule_key}" => merge(rule, {
        lb_key = lb_key
      })
    }
  ]...)

  # probe가 있는 LB만 추려서 LB key 기준 map으로
  lbs_with_probe = {
    for lb_key, lb in var.load_balancers : lb_key => lb.lb_settings.probe
    if lb.lb_settings.probe != null
  }
}

# 1. 공인 IP
resource "azurerm_public_ip" "pips" {
  for_each = local.flattened_frontend_configs

  name                = each.value.pip_name
  location            = data.azurerm_resource_group.rg[var.load_balancers[each.value.lb_key].resource_group_name].location
  resource_group_name = data.azurerm_resource_group.rg[var.load_balancers[each.value.lb_key].resource_group_name].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 2. 로드밸런서 본체 (LB마다 1개씩)
resource "azurerm_lb" "lb" {
  for_each = var.load_balancers

  name                = each.value.lb_settings.name
  location            = data.azurerm_resource_group.rg[each.value.resource_group_name].location
  resource_group_name = data.azurerm_resource_group.rg[each.value.resource_group_name].name
  sku                 = "Standard"

  dynamic "frontend_ip_configuration" {
    for_each = each.value.frontend_configs
    content {
      name                  = frontend_ip_configuration.value.config_name
      public_ip_address_id = azurerm_public_ip.pips["${each.key}.${frontend_ip_configuration.key}"].id
    }
  }
}

# 3. 백엔드 풀 (LB마다 1개씩)
resource "azurerm_lb_backend_address_pool" "backend" {
  for_each = var.load_balancers

  loadbalancer_id = azurerm_lb.lb[each.key].id
  name            = each.value.lb_settings.backend_pool_name
}

# 4. 상태 검사 (probe가 있는 LB만)
resource "azurerm_lb_probe" "probe" {
  for_each = local.lbs_with_probe

  loadbalancer_id = azurerm_lb.lb[each.key].id
  name            = each.value.name
  port            = each.value.port
}

# 5. 부하 분산 규칙 (LB마다 여러 개 가능)
resource "azurerm_lb_rule" "rules" {
  for_each = local.flattened_rules

  loadbalancer_id                = azurerm_lb.lb[each.value.lb_key].id
  name                            = each.value.name
  protocol                        = each.value.protocol
  frontend_port                   = each.value.frontend_port
  backend_port                    = each.value.backend_port
  frontend_ip_configuration_name = each.value.frontend_ip_configuration_name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend[each.value.lb_key].id]
  probe_id                        = try(azurerm_lb_probe.probe[each.value.lb_key].id, null)
}
