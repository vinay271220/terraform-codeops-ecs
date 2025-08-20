variable "region" { type = string }
variable "name" { type = string }
variable "environment" { type = string, default = "prod" }
variable "tags" { type = map(string), default = {} }

variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids" { type = list(string) }

variable "alb_internal" { type = bool, default = false }
variable "alb_ip_address_type" { type = string, default = "ipv4" }
variable "alb_idle_timeout" { type = number, default = 60 }
variable "alb_allowed_ingress_cidrs" { type = list(string), default = ["0.0.0.0/0"] }

variable "alb_protocol" { type = string, default = "HTTP" } # to TG
variable "listener_ssl_policy" { type = string, default = "ELBSecurityPolicy-TLS13-1-2-2021-06" }
variable "certificate_arn" { type = string, description = "ACM certificate for HTTPS" }
variable "enable_http_redirect" { type = bool, default = true }

variable "health_check_path" { type = string, default = "/" }
variable "health_check_matcher" { type = string, default = "200-399" }
variable "health_check_interval" { type = number, default = 30 }
variable "health_check_timeout" { type = number, default = 5 }
variable "health_check_healthy_threshold" { type = number, default = 2 }
variable "health_check_unhealthy_threshold" { type = number, default = 2 }

variable "tg_deregistration_delay" { type = number, default = 30 }
variable "tg_enable_stickiness" { type = bool, default = false }
variable "tg_stickiness_type" { type = string, default = "lb_cookie" }
variable "tg_stickiness_cookie_duration" { type = number, default = 86400 }

variable "container_name" { type = string, default = "app" }
variable "container_image" { type = string }
variable "container_port" { type = number, default = 80 }
variable "app_protocol" { type = string, default = "http" } # http, http2, grpc

variable "task_cpu" { type = string, default = "512" }
variable "task_memory" { type = string, default = "1024" }
variable "readonly_root_fs" { type = bool, default = true }

variable "environment" { type = string, default = "prod" }
variable "environment_vars" { description = "DEPRECATED: Use 'environment' map instead.", type = map(string), default = {} }
variable "environment" { type = string, default = "prod" }

# Correct env map
variable "environment" {
  type        = string
  default     = "prod"
  description = "Environment name (prod/stage/etc)."
}

variable "environment_vars_map" {
  type        = map(string)
  default     = {}
  description = "Key/value environment variables for the container."
}

# for compatibility retain 'environment'
variable "environment" { type = string, default = "prod" }

variable "environment_vars" {
  type        = map(string)
  default     = {}
  description = "Alias for environment_vars_map."
}

# Secrets list: [{ name = "ENV_NAME", value_from = "arn:aws:ssm:..." or "arn:aws:secretsmanager:..." }]
variable "secrets" {
  type = list(object({
    name       = string,
    value_from = string
  }))
  default = []
}

variable "desired_count" { type = number, default = 2 }
variable "assign_public_ip" { type = bool, default = false }
variable "platform_version" { type = string, default = "1.4.0" }
variable "enable_execute_command" { type = bool, default = true }
variable "enable_container_insights" { type = bool, default = true }

variable "capacity_providers" { type = list(string), default = ["FARGATE"] } # or ["FARGATE","FARGATE_SPOT"]
variable "enable_capacity_provider_strategy" { type = bool, default = true }
variable "capacity_provider_base" { type = number, default = 1 }
variable "capacity_provider_weights" {
  type = map(number)
  default = {
    FARGATE       = 1
    FARGATE_SPOT  = 0
  }
}

variable "deployment_controller_type" { type = string, default = "ECS" } # or CODE_DEPLOY

variable "asg_min_capacity" { type = number, default = 2 }
variable "asg_max_capacity" { type = number, default = 10 }
variable "asg_cpu_target" { type = number, default = 60 }
variable "asg_memory_target" { type = number, default = 70 }
variable "asg_scale_in_cooldown" { type = number, default = 60 }
variable "asg_scale_out_cooldown" { type = number, default = 60 }

variable "log_retention_days" { type = number, default = 30 }

# Additional IAM JSON policies (optional)
variable "extra_execution_role_policy_json" { type = string, default = "" }
variable "task_role_inline_policy_json" { type = string, default = "" }

# Listener rules list
variable "listener_rules" {
  type = list(object({
    priority = number
    hosts    = list(string)
    paths    = list(string)
  }))
  default = []
}

# Container healthcheck block passed as object; example below in README
variable "container_healthcheck" {
  type = any
  default = null
}

# Runtime platform
variable "operating_system_family" { type = string, default = "LINUX" }
variable "cpu_architecture" { type = string, default = "X86_64" }
