resource "aws_security_group" "this" {
  name        = var.name
  description = "Managed by the security-group module"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

# flatten map-of-rules x list-of-cidrs into one rule resource per pair,
# because a single rule resource takes exactly one cidr_ipv4
locals {
  ingress_pairs = merge([
    for rule_name, rule in var.ingress_rules : {
      for cidr in rule.cidr_blocks :
      "${rule_name}-${cidr}" => {
        description = rule.description
        from_port   = rule.from_port
        to_port     = rule.to_port
        protocol    = rule.protocol
        cidr        = cidr
      }
    }
  ]...)
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_pairs

  security_group_id = aws_security_group.this.id
  description       = each.value.description

  cidr_ipv4   = each.value.cidr
  from_port   = each.value.from_port
  to_port     = each.value.to_port
  ip_protocol = each.value.protocol
}

# a terraform-managed group allows NOTHING out unless this exists
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "All outbound"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
