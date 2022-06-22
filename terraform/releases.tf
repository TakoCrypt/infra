locals {
  releases_domain = "releases.nixos.org"

  releases_index = templatefile("${path.module}/s3_listing.html.tpl", {
    bucket_name    = aws_s3_bucket.releases.bucket
    bucket_url     = "https://${aws_s3_bucket.releases.bucket_domain_name}"
    bucket_website = "https://${local.releases_domain}"
  })

  releases_backend = "nix-releases.s3-eu-west-1.amazonaws.com"
}

resource "aws_s3_bucket" "releases" {
  bucket = "nix-releases"

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["HEAD", "GET"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

resource "aws_s3_bucket_object" "releases-index-html" {
  acl          = "public-read"
  bucket       = aws_s3_bucket.releases.bucket
  content_type = "text/html"
  etag         = md5(local.releases_index)
  key          = "index.html"
  content      = local.releases_index
}

resource "aws_s3_bucket_policy" "releases" {
  bucket = aws_s3_bucket.releases.id
  policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "AllowPublicRead",
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::nix-releases/*"
    },
    {
      "Sid": "AllowPublicList",
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::nix-releases"
    },
    {
      "Sid": "AllowUpload",
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::080433136561:user/s3-upload-releases",
          "arn:aws:iam::065343343465:user/nixos-s3-upload-releases"
        ]
      },
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws:s3:::nix-releases/*"
    }
  ]
}
EOF
}

resource "fastly_service_v1" "releases" {
  name        = local.releases_domain
  default_ttl = 86400

  backend {
    address               = local.releases_backend
    auto_loadbalance      = false
    between_bytes_timeout = 10000
    connect_timeout       = 5000
    error_threshold       = 0
    first_byte_timeout    = 15000
    max_conn              = 200
    name                  = local.releases_backend
    override_host         = local.releases_backend
    port                  = 443
    shield                = local.fastly_shield
    ssl_cert_hostname     = local.releases_backend
    ssl_check_cert        = true
    use_ssl               = true
    weight                = 100
  }

  condition {
    name      = "Generated by synthetic response for 404 page"
    priority  = 0
    statement = "beresp.status == 404"
    type      = "CACHE"
  }

  condition {
    name      = "Match /"
    priority  = 10
    statement = "req.url ~ \"^/$\""
    type      = "REQUEST"
  }

  domain {
    name = local.releases_domain
  }

  header {
    action            = "set"
    destination       = "url"
    ignore_if_set     = false
    name              = "Landing page"
    priority          = 10
    request_condition = "Match /"
    source            = "\"/index.html\""
    type              = "request"
  }

  # Clean headers for caching
  header {
    destination = "http.x-amz-request-id"
    type        = "cache"
    action      = "delete"
    name        = "remove x-amz-request-id"
  }
  header {
    destination = "http.x-amz-version-id"
    type        = "cache"
    action      = "delete"
    name        = "remove x-amz-version-id"
  }
  header {
    destination = "http.x-amz-id-2"
    type        = "cache"
    action      = "delete"
    name        = "remove x-amz-id-2"
  }

  # Allow CORS GET requests.
  header {
    destination = "http.access-control-allow-origin"
    type        = "cache"
    action      = "set"
    name        = "CORS Allow"
    source      = "\"*\""
  }

  response_object {
    cache_condition = "Generated by synthetic response for 404 page"
    content         = "404"
    content_type    = "text/html"
    name            = "Generated by synthetic response for 404 page"
    response        = "Not Found"
    status          = 404
  }

  snippet {
    content  = "set req.url = querystring.remove(req.url);"
    name     = "Remove all query strings"
    priority = 50
    type     = "recv"
  }

  # Work around the 2GB size limit for large files
  #
  # See https://docs.fastly.com/en/guides/segmented-caching
  snippet {
    content  = <<-EOT
      if (req.url.path ~ "^/nixos/") {
        set req.enable_segmented_caching = true;
      }
    EOT
    name     = "Enable segment caching for ISOs and friends"
    priority = 60
    type     = "recv"
  }

  snippet {
    content  = <<-EOT
      if (beresp.status == 403) {
        set beresp.status = 404;
        set beresp.ttl = 86400s;
        set beresp.grace = 0s;
        set beresp.cacheable = true;
      }
    EOT
    name     = "Change 403 from S3 to 404"
    priority = 100
    type     = "fetch"
  }

  s3logging {
    name              = "${local.releases_domain}-to-s3"
    bucket_name       = module.fastlylogs.bucket_name
    compression_codec = "zstd"
    domain            = module.fastlylogs.s3_domain
    format            = module.fastlylogs.format
    format_version    = 2
    path              = "${local.releases_domain}/"
    period            = module.fastlylogs.period
    message_type      = "blank"
    s3_iam_role       = module.fastlylogs.iam_role_arn
  }
}

resource "fastly_tls_subscription" "releases" {
  domains               = [for domain in fastly_service_v1.releases.domain : domain.name]
  configuration_id      = local.fastly_tls12_sni_configuration_id
  certificate_authority = "globalsign"
}

# TODO: move the DNS config to terraform
output "releases-managed_dns_challenge" {
  value = fastly_tls_subscription.releases.managed_dns_challenge
}
