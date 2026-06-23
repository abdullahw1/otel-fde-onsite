data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # One predictable name keeps AWS resources easy to find during the interview.
  cluster_name = "${var.name}-${var.environment}"

  # Two AZs are enough for a production-like test while keeping cost and setup time low.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# VPC module creates the networking foundation for EKS and public load balancers.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  # Worker nodes live in private subnets. Public traffic reaches them through the NLB.
  private_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 10),
    cidrsubnet(var.vpc_cidr, 8, 11),
  ]

  # Public subnets are tagged so Kubernetes can create internet-facing AWS load balancers.
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 0),
    cidrsubnet(var.vpc_cidr, 8, 1),
  ]

  enable_dns_hostnames = true
  enable_dns_support   = true

  # A single NAT gateway is a cost-conscious choice for the onsite. Production would
  # usually use one NAT gateway per AZ for better AZ failure isolation.
  enable_nat_gateway = true
  single_nat_gateway = true

  # Kubernetes service-controller uses these tags to place public LoadBalancer services.
  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  # Internal load balancers would use these private subnets.
  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

# EKS module creates the managed Kubernetes control plane, cluster IAM, security
# groups, add-ons, and the managed node group used by the collector workload.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  # Public API endpoint is convenient for a time-boxed exercise. Restrict it with
  # admin_cidr_blocks rather than leaving it open to the whole internet.
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = var.admin_cidr_blocks
  enable_cluster_creator_admin_permissions = true

  # Schedule worker nodes into private subnets.
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Enables Kubernetes service accounts to assume IAM roles later if needed.
  enable_irsa = true

  # Managed add-ons keep core cluster networking and DNS on AWS-supported versions.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # Small managed node group for the onsite. It is large enough to run collector,
  # monitoring, and load-test observability, but still cheap to destroy/recreate.
  eks_managed_node_groups = {
    default = {
      name           = "default"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        workload = "general"
      }
    }
  }
}
