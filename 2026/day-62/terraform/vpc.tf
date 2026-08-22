# Everything below is built by hand rather than with the registry module,
# so the wiring is visible. Day 65 replaces all of this with one module block.

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  # both are needed for instances to get DNS names
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "devboard-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  # implicit dependency on the vpc via this reference
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "devboard-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  # without this, instances launched here get no public IP
  map_public_ip_on_launch = true

  tags = {
    Name = "devboard-public-1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # this default route through the IGW is what makes the subnet "public"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "devboard-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
