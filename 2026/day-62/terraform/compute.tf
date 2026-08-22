resource "aws_security_group" "web" {
  name        = "devboard-web"
  description = "Allow HTTP in, everything out"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "devboard-web-sg"
  }

  # replace the SG before destroying the old one, so the instance is
  # never left without one during an update
  lifecycle {
    create_before_destroy = true
  }
}

# Rules as separate resources rather than inline blocks. Inline ingress/egress
# blocks conflict with any rule added outside terraform, and terraform will
# silently revert them on the next apply.
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP from anywhere"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  ip_protocol = "tcp"
  to_port     = 80
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "All outbound"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "web" {
  ami           = data.aws_ami.al2023.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public.id

  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y nginx
    echo "<h1>DevBoard - Day 62</h1>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT

  # explicit: nothing in the instance config references the route table,
  # so terraform would happily build the instance before the route exists.
  # Without this the user_data cannot reach the internet to install nginx.
  depends_on = [aws_route_table_association.public]

  tags = {
    Name = "devboard-web"
  }
}
