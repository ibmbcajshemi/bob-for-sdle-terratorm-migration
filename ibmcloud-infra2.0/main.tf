# ===========================================================================
# Data Sources
# ===========================================================================

data "ibm_resource_group" "group" {
  name = var.resource_group_name
}

data "ibm_is_image" "vsi_image" {
  name       = var.vsi_image_name
  visibility = "public"
}

# ===========================================================================
# Sub-Task 3 — COS Service Instance & Application Bucket
# ===========================================================================

resource "ibm_resource_instance" "cos_instance" {
  name              = "${var.project_name}-cos-${var.environment}"
  service           = "cloud-object-storage"
  plan              = "standard"
  location          = "global"
  resource_group_id = data.ibm_resource_group.group.id

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
    "audit:gitops-verified",
  ]
}

resource "ibm_cos_bucket" "app_bucket" {
  bucket_name          = var.app_bucket_name
  resource_instance_id = ibm_resource_instance.cos_instance.id
  cross_region_location = "us"
  storage_class        = var.app_storage_class

  dynamic "object_versioning" {
    for_each = var.enable_versioning ? [1] : []
    content {
      enable = true
    }
  }

  activity_tracking {
    read_data_events  = true
    write_data_events = true
  }

  dynamic "archive_rule" {
    for_each = var.environment == "prod" ? [1] : []
    content {
      rule_id = "archive-cold-90d"
      enable  = true
      days    = 90
      type    = "GLACIER"
    }
  }
}

# ===========================================================================
# Sub-Task 4 — VPC Networking
# ===========================================================================

resource "ibm_is_vpc" "vpc" {
  name                      = "${var.project_name}-${var.environment}-vpc"
  resource_group            = data.ibm_resource_group.group.id
  address_prefix_management = "manual"

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

resource "ibm_is_vpc_address_prefix" "prefix" {
  name = "${var.project_name}-${var.environment}-prefix"
  vpc  = ibm_is_vpc.vpc.id
  zone = var.zone
  cidr = var.vpc_address_prefix
}

resource "ibm_is_public_gateway" "pgw" {
  name           = "${var.project_name}-${var.environment}-pgw"
  vpc            = ibm_is_vpc.vpc.id
  zone           = var.zone
  resource_group = data.ibm_resource_group.group.id

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

resource "ibm_is_subnet" "subnet" {
  name            = "${var.project_name}-${var.environment}-subnet"
  vpc             = ibm_is_vpc.vpc.id
  zone            = var.zone
  ipv4_cidr_block = var.subnet_cidr
  public_gateway  = ibm_is_public_gateway.pgw.id
  resource_group  = data.ibm_resource_group.group.id

  depends_on = [ibm_is_vpc_address_prefix.prefix]

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

resource "ibm_is_security_group" "sg" {
  name           = "${var.project_name}-${var.environment}-sg"
  vpc            = ibm_is_vpc.vpc.id
  resource_group = data.ibm_resource_group.group.id

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

# Inbound SSH
resource "ibm_is_security_group_rule" "inbound_ssh" {
  group     = ibm_is_security_group.sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"
  protocol  = "tcp"
  port_min  = 22
  port_max  = 22
}

# Inbound HTTP
resource "ibm_is_security_group_rule" "inbound_http" {
  group     = ibm_is_security_group.sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"
  protocol  = "tcp"
  port_min  = 80
  port_max  = 80
}

# Inbound HTTPS
resource "ibm_is_security_group_rule" "inbound_https" {
  group     = ibm_is_security_group.sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"
  protocol  = "tcp"
  port_min  = 443
  port_max  = 443
}

# Outbound all
resource "ibm_is_security_group_rule" "outbound_all" {
  group     = ibm_is_security_group.sg.id
  direction = "outbound"
  remote    = "0.0.0.0/0"
  protocol  = "any"
}

# ===========================================================================
# Sub-Task 5 — VSI (Virtual Server Instance)
# ===========================================================================

resource "ibm_is_ssh_key" "ssh_key" {
  name           = "${var.project_name}-${var.environment}-key"
  public_key     = var.ssh_public_key
  resource_group = data.ibm_resource_group.group.id

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

resource "ibm_is_instance" "vsi" {
  name           = "${var.project_name}-${var.environment}-vsi"
  vpc            = ibm_is_vpc.vpc.id
  zone           = var.zone
  profile        = var.vsi_profile
  image          = data.ibm_is_image.vsi_image.id
  resource_group = data.ibm_resource_group.group.id

  primary_network_interface {
    subnet          = ibm_is_subnet.subnet.id
    security_groups = [ibm_is_security_group.sg.id]
  }

  keys = [ibm_is_ssh_key.ssh_key.id]

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

resource "ibm_is_floating_ip" "vsi_fip" {
  name           = "${var.project_name}-${var.environment}-fip"
  target         = ibm_is_instance.vsi.primary_network_interface[0].id
  resource_group = data.ibm_resource_group.group.id

  tags = [
    "environment:${var.environment}",
    "managed-by:terraform",
    "project:${var.project_name}",
  ]
}

# ===========================================================================
# Sub-Task 6 — Code Engine Project & Application
# ===========================================================================

resource "ibm_code_engine_project" "ce_project" {
  name              = "${var.project_name}-${var.environment}-ce-project"
  resource_group_id = data.ibm_resource_group.group.id
}

resource "ibm_code_engine_app" "ce_app" {
  project_id      = ibm_code_engine_project.ce_project.project_id
  name            = "${var.project_name}-${var.environment}-app"
  image_reference = var.ce_app_image
  scale_min_instances = var.ce_app_min_scale
  scale_max_instances = var.ce_app_max_scale
  scale_cpu_limit     = var.ce_app_cpu
  scale_memory_limit  = var.ce_app_memory
}
