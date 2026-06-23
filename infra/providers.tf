provider "aws" {
  region = var.aws_region

  # Default tags make it easier to identify and clean up onsite resources.
  default_tags {
    tags = {
      Project     = var.name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
