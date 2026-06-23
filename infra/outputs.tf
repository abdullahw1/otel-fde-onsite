output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint."
  value       = module.eks.cluster_endpoint
}

output "aws_region" {
  description = "AWS region where the cluster was created."
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  # These are where Kubernetes places the public NLB for OTEL ingestion.
  description = "Public subnet IDs used by internet-facing load balancers."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  # EKS worker nodes run here so they do not need public IPs.
  description = "Private subnet IDs used by EKS worker nodes."
  value       = module.vpc.private_subnets
}

output "configure_kubectl" {
  # Run this after apply to point kubectl at the new EKS cluster.
  description = "Command to configure kubectl for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
