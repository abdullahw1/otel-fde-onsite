# variables.tf -- all the tunable inputs for the infrastructure. Defaults are set
# for a cheap, time-boxed exercise; override them in terraform.tfvars as needed.
# (name + environment combine into the cluster name, e.g. "otel-fde-onsite".)

variable "name" {
  description = "Base name used for AWS resources."
  type        = string
  default     = "otel-fde"
}

variable "environment" {
  description = "Environment tag for all managed resources."
  type        = string
  default     = "onsite"
}

variable "aws_region" {
  description = "AWS region where the cluster is created."
  type        = string
  default     = "us-west-2"
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "CIDR block for the EKS VPC."
  type        = string
  default     = "10.20.0.0/16"
}

# Worker node sizing. t3.large = 2 vCPU / 8 GiB. Intentionally small so the
# cluster is easy to saturate during load testing (the whole point of the exercise).
variable "node_instance_types" {
  description = "Instance types used by the default managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Desired worker node count."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum worker node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum worker node count."
  type        = number
  default     = 4
}

# SECURITY: who can reach the EKS Kubernetes API endpoint. Default 0.0.0.0/0 means
# "the whole internet" -- fine to get started, but tighten to your own IP (e.g.
# ["203.0.113.10/32"]) for any real use.
variable "admin_cidr_blocks" {
  description = "CIDR blocks allowed to access the public EKS API endpoint. Tighten this to your current IP during real use."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
