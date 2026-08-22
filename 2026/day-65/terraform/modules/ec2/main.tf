# a module should not force its caller to supply an AMI, but should let
# them override it. count = 0 skips the lookup entirely when they do.
data "aws_ami" "al2023" {
  count = var.ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

locals {
  ami_id = coalesce(var.ami_id, try(data.aws_ami.al2023[0].id, null))
}

resource "aws_instance" "this" {
  count = var.instance_count

  ami           = local.ami_id
  instance_type = var.instance_type

  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids = var.security_group_ids

  user_data = var.user_data

  tags = merge(var.tags, {
    Name = "${var.name}-${count.index + 1}"
  })
}
