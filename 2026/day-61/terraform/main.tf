# S3 bucket names are globally unique across every AWS account,
# so a fixed name would collide. random_id makes it unique per apply.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "demo" {
  bucket = "devboard-day61-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "demo" {
  # implicit dependency: referencing .id makes terraform create the bucket first
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Look the AMI up rather than hardcoding it - AMI IDs differ per region
# and are replaced whenever Amazon publishes a new build.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "demo" {
  ami           = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  tags = {
    Name = "devboard-day61"
  }
}
