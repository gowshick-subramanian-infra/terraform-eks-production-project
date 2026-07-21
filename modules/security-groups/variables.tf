variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "tomcat_port" {
  description = "Port Tomcat app listens on inside the pods/nodes"
  type        = number
  default     = 8080
}

variable "postgres_port" {
  type    = number
  default = 5432
}

variable "allowed_bastion_cidrs" {
  description = "CIDR blocks allowed to reach the bastion / admin access (e.g. office IP). Empty by default (no SSH open)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
