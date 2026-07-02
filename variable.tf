variable "load_balancers" {
  type = map(object({
    resource_group_name = string

    lb_settings = object({
      name              = string
      backend_pool_name = string
      # probe를 여러 개 설정할 수 있도록 map으로 변경
      probes = optional(map(object({
        name = string
        port = number
      })), {})
      rules = map(object({
        name                           = string
        protocol                       = string
        frontend_port                  = number
        backend_port                   = number
        frontend_ip_configuration_name = string
        probe_key                      = optional(string) # 연결할 probe의 key (선택)
      }))
    })

    # 프론트엔드 설정 (이름 + IP 이름을 한 세트로)
    frontend_configs = map(object({
      config_name = string
      pip_name    = string
    }))
    
    tags = optional(map(string), {})
  }))
  default = {}
}
