terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

# Filled in by the ScyllaDB spec from the deployment cell.
variable "region" {
  type = string
}

variable "vpcId" {
  type = string
}

variable "vpcCidr" {
  type = string
}

provider "aws" {
  region = var.region
}

# Front-end security group for the per-member CQL load balancers of one
# ScyllaDB instance. The operator's member Services carry every ScyllaDB port
# (inter-node 7000/7001, Manager agent 10001, JMX, metrics), and the load
# balancer gets a listener for each; this group admits only client CQL and the
# token-authenticated Manager agent.
resource "aws_security_group" "cql_nlb" {
  name        = "scylla-cql-nlb-{{ $sys.id }}"
  description = "ScyllaDB member load balancers: CQL 9042/19042 and Manager agent 10001 only"
  vpc_id      = var.vpcId

  ingress {
    description = "CQL"
    from_port   = 9042
    to_port     = 9042
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "CQL, shard-aware"
    from_port   = 19042
    to_port     = 19042
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # The operator's cleanup Jobs reach each member's Manager agent at the
  # member's advertised (public) address. Cell nodes egress from their own,
  # changing public IPs, so this can't be narrowed to the cell; the agent serves
  # HTTPS and rejects requests without the cluster's random auth token.
  ingress {
    description = "Scylla Manager agent (HTTPS, token-authenticated)"
    from_port   = 10001
    to_port     = 10001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # to the members (and for the load balancer's health checks)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpcCidr]
  }

  tags = {
    "omnistrate.com/managed-by" = "omnistrate"
    "scylla/purpose"            = "cql-nlb"
  }

  # The load balancers are deleted asynchronously when the instance goes away;
  # give them time to release the group.
  timeouts {
    delete = "30m"
  }
}

output "securityGroupId" {
  value = aws_security_group.cql_nlb.id
}
