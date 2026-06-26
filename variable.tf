variable "load_balancers" {
  type = map(object({
    resource_group_name = string

    lb_settings = object({
      name              = string
      backend_pool_name = string
      probe = optional(object({
        name = string
        port = number
      }))
      rules = map(object({
        name                           = string
        protocol                       = string
        frontend_port                  = number
        backend_port                   = number
        frontend_ip_configuration_name = string
      }))
    })

    # 프론트엔드 설정 (이름 + IP 이름을 한 세트로)
    frontend_configs = map(object({
      config_name = string
      pip_name    = string
    }))
  }))
  default = {}
}
