//Connecting to AWS-user
provider "aws" {
  region = "ap-south-1"
  profile = "shivam"
}

resource "tls_private_key" "key_pair" {
algorithm = "RSA"
}

//Creating EC2 authentication key
resource "aws_key_pair" "ec2_key" {
  depends_on = [tls_private_key.key_pair]

  key_name = "shivefs"
  public_key = tls_private_key.key_pair.public_key_openssh
}

//Creating Security Groups
resource "aws_security_group" "web_security" {
  depends_on = [aws_key_pair.ec2_key]

  name        = "web_security"
  description = "Allow TLS inbound traffic"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NFS"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [ "0.0.0.0/0" ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web_security"
  }
}

//Creating s3 bucket(object storage system)
resource "aws_s3_bucket" "cloudtask2s3bucket" {
  bucket        = "cloudtask2s3bucket"
  acl           = "public-read"
  region        = "ap-south-1"
  force_destroy = true

  tags = {
    Name = "my_bucket"
    Environment = "Deployment"
  }
}

//Downloading git repository in local system using null resource
resource "null_resource" "local-git" {
  depends_on = [aws_s3_bucket.cloudtask2s3bucket]  

  provisioner "local-exec" {
    command = "git clone https://github.com/Shivamshiv/AWS_Cloud_EFS"
  }
}

//Uploading file to s3-bucket
resource "aws_s3_bucket_object" "object" {
  depends_on = [aws_s3_bucket.cloudtask2s3bucket, null_resource.local-git] 

  bucket = aws_s3_bucket.cloudtask2s3bucket.id
  key    = "aws-efs.jpg"
  source = "AWS_Cloud_EFS/aws-efs.jpg"
  acl = "public-read"
}

resource "aws_s3_bucket_public_access_block" "cloudtask2s3bucket_public" {
  bucket = "cloudtask2s3bucket"
  block_public_acls   = false
  block_public_policy = false
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  depends_on = [aws_s3_bucket_object.object]
  comment = "Cloud Task 2"
}

//Creating Cloud-front 
resource "aws_cloudfront_distribution" "s3_distribution" {
  depends_on = [aws_s3_bucket.cloudtask2s3bucket, null_resource.local-git]

  origin {
    domain_name = aws_s3_bucket.cloudtask2s3bucket.bucket_regional_domain_name
    origin_id   = "S3-cloudtask2s3bucket"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-cloudtask2s3bucket"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

//Printing Cloud-front domain name
output "domain-name" {
  value = aws_cloudfront_distribution.s3_distribution.domain_name
}

//Launching EC2 instance
resource "aws_instance" "web_os" {
  depends_on = [aws_security_group.web_security]

  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = aws_key_pair.ec2_key.key_name
  security_groups = [ "web_security" ]

  connection {
    type   = "ssh"
    user   = "ec2-user"
    private_key = tls_private_key.key_pair.private_key_pem
    host   = aws_instance.web_os.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum update -y",
      "sudo yum install amazon-efs-utils nfs-utils -y",
      "sudo yum install httpd  php git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd",
    ]
  }

  tags = {
    Name = "web_os"
  }
}

//Creating NFS storage
resource "aws_efs_file_system" "nfs_storage" {
  depends_on = [aws_security_group.web_security, aws_instance.web_os]

  creation_token = "nfs_storage"
  performance_mode = "generalPurpose"
  throughput_mode = "bursting"
  tags = {
    Name = "nfs_storage"
  }
}

//Connecting EFS to the VPC and security groups 
resource "aws_efs_mount_target" "efs_mount" {
  depends_on = [aws_efs_file_system.nfs_storage]

  file_system_id = aws_efs_file_system.nfs_storage.id
  subnet_id      = aws_instance.web_os.subnet_id
  security_groups = ["${aws_security_group.web_security.id}"]
}

//Printing Instance public IP
output "instance_ip" {
  value = aws_instance.web_os.public_ip
}

//Mounting EFS to the web hosting directory /var/www/html
resource "null_resource" "null_remote_mount"  {
  depends_on = [aws_efs_mount_target.efs_mount]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.key_pair.private_key_pem
    host     = aws_instance.web_os.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo echo ${aws_efs_file_system.nfs_storage.dns_name}:/var/www/html efs defaults,_netdev 0 0 >> sudo /etc/fstab",
      "sudo mount  ${aws_efs_file_system.nfs_storage.dns_name}:/  /var/www/html",
      "sudo git clone https://github.com/Shivamshiv/AWS_Cloud_EFS /var/www/html/",
      "sudo sed -i 's@$aws-efs.jpg@https://${aws_cloudfront_distribution.s3_distribution.domain_name}/aws-efs.jpg@g'  /var/www/html/index.html ",
      "sudo systemctl restart  httpd"
    ]
  }
}

//Web hosting to the server
resource "null_resource" "web_hosting" {
  depends_on = [null_resource.null_remote_mount]

  provisioner "local-exec" {
    command = "start chrome ${aws_instance.web_os.public_ip}"
  }
}