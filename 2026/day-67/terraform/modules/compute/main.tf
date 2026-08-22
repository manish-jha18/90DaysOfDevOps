data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-web"
  description = "Web tier for ${var.name_prefix}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-web-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.allowed_http_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "HTTP from ${each.value}"

  cidr_ipv4   = each.value
  from_port   = 80
  ip_protocol = "tcp"
  to_port     = 80
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_instance" "this" {
  count = var.instance_count

  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type

  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids = [aws_security_group.this.id]

  monitoring = var.enable_detailed_monitoring

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y nginx
    echo "<h1>${var.name_prefix} - node $(hostname)</h1>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT

  tags = merge(var.tags, { Name = "${var.name_prefix}-web-${count.index + 1}" })
}
