variable "load_balancers" {
  type = map(object({
    resource_group_name = string

    lb_settings = object({
      name = string

      # 백엔드 풀 다중화: 룰에서 pool_key로 선택 (포털의 "백 엔드 풀" 드롭다운)
      backend_pools = map(object({
        name = string
      }))

      # 백엔드 풀에 조인할 VM NIC 목록 (NIC 방식)
      # key: 멤버 식별용 임의 키 (예: vm1, vm2)
      pool_members = optional(map(object({
        pool_key                = string           # 조인할 backend_pools의 키
        nic_name                = string
        nic_resource_group_name = optional(string) # 생략 시 LB의 resource_group_name 사용
        ip_configuration_name   = optional(string) # 생략 시 NIC의 첫 번째 ip_configuration 사용
      })), {})

      # probe를 여러 개 설정할 수 있도록 map으로 변경
      probes = optional(map(object({
        name         = string
        port         = number
        protocol     = optional(string, "Tcp") # "Tcp" | "Http" | "Https"
        request_path = optional(string)        # Http/Https일 때 필수 (예: "/health")
      })), {})

      rules = map(object({
        name                           = string
        frontend_ip_configuration_name = string           # 포털 "프런트 엔드 IP 주소" (IP 버전은 프론트엔드의 ip_version으로 결정됨)
        pool_key                       = string           # 포털 "백 엔드 풀": backend_pools의 키
        ha_ports                       = optional(bool, false) # 포털 "고가용성 포트" 체크박스 (내부 프론트엔드 전용, true면 아래 프로토콜/포트 무시)
        protocol                       = optional(string, "Tcp") # "Tcp" | "Udp"
        frontend_port                  = optional(number)  # 포털 "포트" (ha_ports=false면 필수)
        backend_port                   = optional(number)  # 포털 "백 엔드 포트" (ha_ports=false면 필수)
        probe_key                      = optional(string)  # 포털 "상태 프로브": probes의 키 (선택)

        load_distribution       = optional(string, "Default") # 세션 지속성: "Default"(없음) | "SourceIP"(클라이언트 IP) | "SourceIPProtocol"(클라이언트 IP+프로토콜)
        idle_timeout_in_minutes = optional(number, 4)         # 유휴 시간 제한(분), 4~30
        enable_tcp_reset        = optional(bool, false)       # TCP 재설정 사용
        enable_floating_ip      = optional(bool, false)       # 부동 IP 사용 (SQL AlwaysOn 등 특수 시나리오용)
      }))
    })

    # 프론트엔드 설정: 공인(pip_name) 또는 내부(subnet_name+vnet_name) 중 택1
    frontend_configs = map(object({
      config_name = string
      ip_version  = optional(string, "IPv4") # "IPv4" | "IPv6"

      # 공인 프론트엔드: pip_name 지정
      pip_name = optional(string)

      # 내부 프론트엔드: subnet_name + vnet_name 지정 (고가용성 포트는 내부 전용)
      subnet_name        = optional(string)
      vnet_name          = optional(string)
      vnet_rg_name       = optional(string) # 생략 시 LB의 resource_group_name
      private_ip_address = optional(string) # 지정 시 Static, 생략 시 Dynamic 할당
    }))

    # principal_id: 사용자/그룹/서비스 프린시펄의 object_id (GUID)
    # role_definition_name: 빌트인 역할 표시 이름 (예: "Reader", "Contributor")
    # 주의: 실행 주체(SP)에 해당 스코프의 Owner 또는 User Access Administrator 필요
    iam = optional(map(object({
      principal_id         = string
      role_definition_name = string
    })), {})

    tags = optional(map(string), {})
  }))
  default = {}

  # rule의 probe_key가 실제 probes에 존재하는지 plan 단계에서 검증
  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for r in lb.lb_settings.rules :
        r.probe_key == null || contains(keys(lb.lb_settings.probes), coalesce(r.probe_key, "_"))
      ]
    ]))
    error_message = "rules의 probe_key가 probes에 정의되지 않은 키를 참조하고 있습니다."
  }

  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for r in lb.lb_settings.rules :
        contains(["Default", "SourceIP", "SourceIPProtocol"], r.load_distribution)
      ]
    ]))
    error_message = "load_distribution은 \"Default\", \"SourceIP\", \"SourceIPProtocol\" 중 하나여야 합니다."
  }

  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for r in lb.lb_settings.rules :
        r.idle_timeout_in_minutes >= 4 && r.idle_timeout_in_minutes <= 30
      ]
    ]))
    error_message = "idle_timeout_in_minutes는 4~30 사이여야 합니다."
  }

  # ha_ports=false인 일반 규칙은 포트가 필수
  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for r in lb.lb_settings.rules :
        r.ha_ports || (r.frontend_port != null && r.backend_port != null)
      ]
    ]))
    error_message = "고가용성 포트(ha_ports = true)가 아닌 규칙은 frontend_port와 backend_port를 지정해야 합니다."
  }

  # rule / pool_member의 pool_key가 실제 backend_pools에 존재하는지 검증
  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : concat(
        [for r in lb.lb_settings.rules : contains(keys(lb.lb_settings.backend_pools), r.pool_key)],
        [for m in lb.lb_settings.pool_members : contains(keys(lb.lb_settings.backend_pools), m.pool_key)]
      )
    ]))
    error_message = "rules 또는 pool_members의 pool_key가 backend_pools에 정의되지 않은 키를 참조하고 있습니다."
  }

  # 프론트엔드는 공인(pip_name) / 내부(subnet_name+vnet_name) 중 정확히 하나
  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for cfg in lb.frontend_configs :
        (cfg.pip_name != null && cfg.subnet_name == null) ||
        (cfg.pip_name == null && cfg.subnet_name != null && cfg.vnet_name != null)
      ]
    ]))
    error_message = "frontend_configs는 공인(pip_name) 또는 내부(subnet_name + vnet_name) 중 한 가지 방식만 지정해야 합니다."
  }

  # 고가용성 포트 규칙은 내부 프론트엔드를 참조해야 함 (Azure 제약)
  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for r in lb.lb_settings.rules :
        !r.ha_ports || anytrue([
          for cfg in lb.frontend_configs :
          cfg.config_name == r.frontend_ip_configuration_name && cfg.subnet_name != null
        ])
      ]
    ]))
    error_message = "고가용성 포트(ha_ports = true)는 내부 프론트엔드(subnet_name 지정)에서만 사용할 수 있습니다."
  }

  # Http/Https 프로브는 request_path 필수
  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for p in lb.lb_settings.probes :
        p.protocol == "Tcp" || p.request_path != null
      ]
    ]))
    error_message = "protocol이 \"Http\" 또는 \"Https\"인 프로브는 request_path를 지정해야 합니다."
  }

  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for cfg in lb.frontend_configs :
        contains(["IPv4", "IPv6"], cfg.ip_version)
      ]
    ]))
    error_message = "ip_version은 \"IPv4\" 또는 \"IPv6\"여야 합니다."
  }

  validation {
    condition = alltrue(flatten([
      for lb in var.load_balancers : [
        for a in lb.iam :
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", a.principal_id))
      ]
    ]))
    error_message = "IAM의 principal_id는 object_id(GUID) 형식이어야 합니다. UPN(이메일)이 아닌 GUID를 넣어야 합니다."
  }
}
