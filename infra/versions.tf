# versions.tf -- pins the tool versions so everyone gets a reproducible build.
terraform {
  # Require a reasonably modern Terraform CLI.
  required_version = ">= 1.6.0"

  required_providers {
    # The AWS provider is what actually talks to AWS APIs. "~> 5.0" allows 5.x
    # updates but blocks the breaking 6.0 jump.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
