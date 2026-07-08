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

  # probes를 "lb_key.probe_key" 형태로 펼침
  flattened_probes = merge([
    for lb_key, lb in var.load_balancers : {
      for probe_key, probe in lb.lb_settings.probes :
      "${lb_key}.${probe_key}" => merge(probe, {
        lb_key = lb_key
      })
    }
  ]...)

  # backend_pools를 "lb_key.pool_key" 형태로 펼침
  flattened_pools = merge([
    for lb_key, lb in var.load_balancers : {
      for pool_key, pool in lb.lb_settings.backend_pools :
      "${lb_key}.${pool_key}" => merge(pool, {
        lb_key = lb_key
      })
    }
  ]...)

  # 풀 멤버(NIC)를 "lb_key.member_key" 형태로 펼침
  # nic_resource_group_name 생략 시 LB의 리소스 그룹을 사용
  flattened_pool_members = merge([
    for lb_key, lb in var.load_balancers : {
      for m_key, m in lb.lb_settings.pool_members :
      "${lb_key}.${m_key}" => {
        lb_key                = lb_key
        pool_key              = m.pool_key
        nic_name              = m.nic_name
        nic_rg                = coalesce(m.nic_resource_group_name, lb.resource_group_name)
        ip_configuration_name = m.ip_configuration_name
      }
    }
  ]...)
}

# 1. 공인 IP (공인 프론트엔드에만 생성)
resource "azurerm_public_ip" "pips" {
  for_each = {
    for k, cfg in local.flattened_frontend_configs : k => cfg
    if cfg.pip_name != null
  }

  name                = each.value.pip_name
  location            = data.azurerm_resource_group.rg[var.load_balancers[each.value.lb_key].resource_group_name].location
  resource_group_name = data.azurerm_resource_group.rg[var.load_balancers[each.value.lb_key].resource_group_name].name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version          = each.value.ip_version # 포털의 "IP 버전"

  lifecycle {
    create_before_destroy = true
  }
}

# 2. 로드밸런서 본체 (LB마다 1개씩)
resource "azurerm_lb" "lb" {
  for_each = var.load_balancers

  name                = each.value.lb_settings.name
  location            = data.azurerm_resource_group.rg[each.value.resource_group_name].location
  resource_group_name = data.azurerm_resource_group.rg[each.value.resource_group_name].name
  sku                 = "Standard"
  tags                = each.value.tags

  dynamic "frontend_ip_configuration" {
    for_each = each.value.frontend_configs
    content {
      name = frontend_ip_configuration.value.config_name

      # 공인 프론트엔드
      public_ip_address_id = (
        frontend_ip_configuration.value.pip_name != null
        ? azurerm_public_ip.pips["${each.key}.${frontend_ip_configuration.key}"].id
        : null
      )

      # 내부 프론트엔드 (고가용성 포트는 이 방식에서만 사용 가능)
      subnet_id = (
        frontend_ip_configuration.value.subnet_name != null
        ? data.azurerm_subnet.frontend["${each.key}.${frontend_ip_configuration.key}"].id
        : null
      )
      private_ip_address_allocation = (
        frontend_ip_configuration.value.subnet_name != null
        ? (frontend_ip_configuration.value.private_ip_address != null ? "Static" : "Dynamic")
        : null
      )
      private_ip_address = frontend_ip_configuration.value.private_ip_address
      private_ip_address_version = (
        frontend_ip_configuration.value.subnet_name != null
        ? frontend_ip_configuration.value.ip_version
        : null
      )
    }
  }
}

# 3. 백엔드 풀 (LB마다 여러 개 가능, 룰에서 pool_key로 선택)
resource "azurerm_lb_backend_address_pool" "backend" {
  for_each = local.flattened_pools

  loadbalancer_id = azurerm_lb.lb[each.value.lb_key].id
  name            = each.value.name
}

# 3-1. 풀 멤버로 조인할 기존 VM NIC 조회
# (VM/NIC가 이 코드 밖에서 만들어졌어도 이름으로 찾아서 연결)
data "azurerm_network_interface" "member" {
  for_each = local.flattened_pool_members

  name                = each.value.nic_name
  resource_group_name = each.value.nic_rg
}

# 3-2. NIC를 백엔드 풀에 조인 (포털의 "백 엔드 풀 구성: NIC"와 동일)
# ip_configuration_name 생략 시 NIC의 첫 번째 ip_configuration 사용
resource "azurerm_network_interface_backend_address_pool_association" "member" {
  for_each = local.flattened_pool_members

  network_interface_id  = data.azurerm_network_interface.member[each.key].id
  ip_configuration_name = coalesce(
    each.value.ip_configuration_name,
    data.azurerm_network_interface.member[each.key].ip_configuration[0].name
  )
  backend_address_pool_id = azurerm_lb_backend_address_pool.backend["${each.value.lb_key}.${each.value.pool_key}"].id
}

# 4. 상태 검사 (LB마다 여러 개 가능, Tcp/Http/Https 선택 가능)
resource "azurerm_lb_probe" "probe" {
  for_each = local.flattened_probes

  loadbalancer_id = azurerm_lb.lb[each.value.lb_key].id
  name            = each.value.name
  port            = each.value.port
  protocol        = each.value.protocol
  request_path    = each.value.request_path # Http/Https일 때만 사용
}

# 5-1. rule이 참조하는 frontend config 이름 추적용
# frontend_ip_configuration_name 값이 바뀌면 이 리소스가 교체되고,
# 아래 rule의 replace_triggered_by가 발동해 rule도 교체(재생성)된다.
resource "terraform_data" "rule_frontend_ref" {
  for_each = local.flattened_rules

  input = each.value.frontend_ip_configuration_name
}

# 5-2. 부하 분산 규칙 (LB마다 여러 개 가능)
resource "azurerm_lb_rule" "rules" {
  for_each = local.flattened_rules

  loadbalancer_id                = azurerm_lb.lb[each.value.lb_key].id
  name                           = each.value.name
  frontend_ip_configuration_name = each.value.frontend_ip_configuration_name

  # 포털 "고가용성 포트" 체크박스: 체크 시 protocol=All, 포트 0 (내부 프론트엔드 전용)
  protocol      = each.value.ha_ports ? "All" : each.value.protocol
  frontend_port = each.value.ha_ports ? 0 : each.value.frontend_port
  backend_port  = each.value.ha_ports ? 0 : each.value.backend_port

  # 포털 "백 엔드 풀" 드롭다운: pool_key로 선택
  backend_address_pool_ids = [azurerm_lb_backend_address_pool.backend["${each.value.lb_key}.${each.value.pool_key}"].id]

  # rule에 probe_key가 지정된 경우에만 해당 probe 연결
  probe_id = each.value.probe_key != null ? azurerm_lb_probe.probe["${each.value.lb_key}.${each.value.probe_key}"].id : null

  # 포털 "부하 분산 규칙 추가" 화면의 옵션들
  load_distribution       = each.value.load_distribution       # 세션 지속성
  idle_timeout_in_minutes = each.value.idle_timeout_in_minutes # 유휴 시간 제한(분)
  enable_tcp_reset        = each.value.enable_tcp_reset        # TCP 재설정 사용
  enable_floating_ip      = each.value.enable_floating_ip      # 부동 IP 사용

  lifecycle {
    replace_triggered_by = [
      terraform_data.rule_frontend_ref[each.key]
    ]
  }
}
