# Backend Configuration
terraform {
  backend "gcs" {
    bucket      = "tf-state-graduate-project-315923"
    prefix      = "terraform/state"
  }
}

# Providers
provider "google" {
  region  = var.region
  project = var.project
}

provider "google-beta" {
  region      = var.region
  project     = var.project
}

# Project Name
resource "random_id" "project_random" {
  prefix      = "${var.project_prefix}-${var.environment}-"
  byte_length = "8"
}

resource "google_project" "tgp" {
  count           = var.project != "" ? 0 : 1
  name            = random_id.project_random.hex
  project_id      = random_id.project_random.hex
  billing_account = var.billing_account
}

data "google_project" "tgp" {
  project_id = var.project != "" ? var.project : google_project.tgp[0].project_id
}

###################################################################################
# Service Accounts
# Main SA
resource "google_service_account" "tgp_gke" {
  account_id   = "tgp-gke-cluster"
  display_name = "Admin Account"
  project      = data.google_project.tgp.project_id
}

resource "google_project_iam_member" "service_account" {
  count   = length(var.service_account_iam_roles)
  project = data.google_project.tgp.project_id
  role    = element(var.service_account_iam_roles, count.index)
  member  = "serviceAccount:${google_service_account.tgp_gke.email}"
}

resource "google_project_service" "service" {
  count   = length(var.project_services)
  project = data.google_project.tgp.project_id
  service = element(var.project_services, count.index)
  disable_on_destroy = false
}

# SA for Jenkins
resource "google_service_account" "jenkins" {
  account_id   = "jenkins"
  display_name = "Jenkins User"
}

resource "google_project_iam_member" "jenkins_instance_admin" {
  project = data.google_project.tgp.project_id
  role    = "roles/compute.instanceAdmin"
  member  = "serviceAccount:${google_service_account.jenkins.email}"
}

resource "google_project_iam_member" "jenkins_network_admin" {
  project = data.google_project.tgp.project_id
  role    = "roles/compute.networkAdmin"
  member  = "serviceAccount:${google_service_account.jenkins.email}"
}

resource "google_project_iam_member" "jenkins_service_account_user" {
  project = data.google_project.tgp.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.jenkins.email}"
}

resource "google_project_iam_member" "jenkins_cloudsql_admin" {
  project = data.google_project.tgp.project_id
  role    = "roles/cloudsql.admin"
  member  = "serviceAccount:${google_service_account.jenkins.email}"
}

# SA for App
resource "google_service_account" "application" {
  account_id   = "application"
  display_name = "App User"
}

resource "google_project_iam_member" "application_pubsub_editor" {
  project = data.google_project.tgp.project_id
  role    = "roles/pubsub.editor"
  member  = "serviceAccount:${google_service_account.application.email}"
}

resource "google_project_iam_member" "application_cloudsql_editor" {
  project = data.google_project.tgp.project_id
  role    = "roles/cloudsql.editor"
  member  = "serviceAccount:${google_service_account.application.email}"
}

# SA for Kube
resource "google_service_account" "kube" {
  account_id   = "kubernetes"
  display_name = "Kube User"
}

resource "google_project_iam_member" "kube_user" {
  project = data.google_project.tgp.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.kube.email}"
}

###################################################################################
# Public Subnetwork
resource "google_compute_subnetwork" "tgp_public_subnetwork" {
  name          = "tgp-public-subnetwork"
  project       = data.google_project.tgp.project_id
  network       = google_compute_network.tgp_network.self_link
  region        = var.region
  ip_cidr_range = var.kubernetes_public_network_ipv4_cidr
  
  secondary_ip_range {
    range_name    = "tgp-public-pods"
    ip_cidr_range = var.kubernetes_pods_public_ipv4_cidr
  }

  secondary_ip_range {
    range_name    = "tgp-public-svcs"
    ip_cidr_range = var.kubernetes_services_public_ipv4_cidr
  }
}

# Private Subnetwork
resource "google_compute_subnetwork" "tgp_private_subnetwork" {
  name          = "tgp-private-subnetwork"
  project       = data.google_project.tgp.project_id
  network       = google_compute_network.tgp_network.self_link
  region        = var.region
  ip_cidr_range = var.kubernetes_private_network_ipv4_cidr
  private_ip_google_access = true
  
  secondary_ip_range {
    range_name    = "tgp-private-pods"
    ip_cidr_range = var.kubernetes_pods_private_ipv4_cidr
  }

  secondary_ip_range {
    range_name    = "tgp-private-svcs"
    ip_cidr_range = var.kubernetes_services_private_ipv4_cidr
  }
}

###################################################################################
# Custom Firewall Rules
# SSH
resource "google_compute_firewall" "default" {
  name        = "tgp-network-general-firewall"
  network     = google_compute_network.tgp_network.self_link

  allow {
    protocol  = "icmp"
  }

  allow {
    protocol  = "tcp"
    ports     = ["22"]
  }
  
  target_tags = ["app"]
}

# Public to Private Subnets: App -> DB (3306)
resource "google_compute_firewall" "app_to_db_fw" {
  name    = "app-to-db-fw"
  network = google_compute_network.tgp_network.self_link

  allow {
    protocol = "icmp"
  }  

  allow {
    protocol = "tcp"
    ports    = ["22", "3306"]
  }

  source_tags = ["app"]
  target_tags = ["db"]
}

data "google_compute_lb_ip_ranges" "ranges" {
}

# Public to Private Subnets: App -> Elastic (9200-9300)
resource "google_compute_firewall" "app_to_elastic_fw" {
  name    = "app-to-elastic-fw"
  network = google_compute_network.tgp_network.self_link

  allow {
    protocol = "icmp"
  } 

  allow {
    protocol = "tcp"
    ports    = ["22", "9200-9300"]
  }

  source_tags = ["app"]
  target_tags = ["elastic"]
}

# Firewall Rules for Load Balancer
resource "google_compute_firewall" "loadbalancer" {
  name    = "fw-rule-loadbalance-to-${var.app-name}"
  network = google_compute_network.tgp_network.self_link

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22", "130.211.0.0/22", "35.191.0.0/16"]
  target_tags = ["app"]
}

###################################################################################
# Router
resource "google_compute_router" "tgp_router" {
  name    = "tgp-router"
  project = data.google_project.tgp.project_id
  region  = var.region
  network = google_compute_network.tgp_network.self_link

  bgp {
    asn = 64514
  }
}

###################################################################################
# NAT
resource "google_compute_router_nat" "tgp_nat" {
  name    = "tgp-nat-1"
  project = data.google_project.tgp.project_id
  router  = google_compute_router.tgp_router.name
  region  = var.region

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = google_compute_address.tgp_nat.*.self_link

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.tgp_public_subnetwork.self_link
    source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE", "LIST_OF_SECONDARY_IP_RANGES"]
    secondary_ip_range_names = [
      google_compute_subnetwork.tgp_public_subnetwork.secondary_ip_range[0].range_name,
      google_compute_subnetwork.tgp_public_subnetwork.secondary_ip_range[1].range_name,
    ]
  }
}

data "google_container_engine_versions" "versions" {
  project  = data.google_project.tgp.project_id
  location = var.region
}

resource "google_compute_address" "tgp_nat" {
  count   = 2
  name    = "tgp-nat-external-${count.index}"
  project = data.google_project.tgp.project_id
  region  = var.region

  depends_on = [google_project_service.service]
}

###################################################################################
# VPC
resource "google_compute_network" "tgp_network" {
  name                    = "tgp-network"
  project                 = data.google_project.tgp.project_id
  auto_create_subnetworks = false

  depends_on = [google_project_service.service]
}

###################################################################################
# Pub/Sub Queue
resource "google_pubsub_topic" "example" {
  name = "example-topic"

  labels = {
    foo = "bar"
  }

  message_storage_policy {
    allowed_persistence_regions = [
      "us-central1",
    ]
  }
}

###################################################################################
# GKE Cluster
resource "google_container_cluster" "tgp" {
  provider = google-beta
  name     = "tgp-cluster"
  project  = data.google_project.tgp.project_id
  location = var.region

  network    = google_compute_network.tgp_network.self_link
  subnetwork = google_compute_subnetwork.tgp_private_subnetwork.self_link

  initial_node_count = var.kubernetes_nodes_per_zone

  min_master_version = data.google_container_engine_versions.versions.latest_master_version
  node_version       = data.google_container_engine_versions.versions.latest_master_version

  logging_service    = var.kubernetes_logging_service
  monitoring_service = var.kubernetes_monitoring_service

  node_config {
    machine_type    = var.kubernetes_instance_type
    service_account = google_service_account.tgp_gke.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    metadata = {
      google-compute-enable-virtio-rng = "true"
      disable-legacy-endpoints         = "false"
    }

    labels = {
      service = "tgp"
    }

    tags = ["tgp"]

    workload_metadata_config {
      node_metadata = "SECURE"
    }
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
  }

  master_auth {
    username = ""
    password = ""

    client_certificate_config {
      issue_client_certificate = false
    }
  }

  network_policy {
    enabled = true
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = var.kubernetes_daily_maintenance_window
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.tgp_private_subnetwork.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.tgp_private_subnetwork.secondary_ip_range[1].range_name
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.kubernetes_master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  private_cluster_config {
    enable_private_endpoint = false
    enable_private_nodes   = true # true for private cluster, PRIV GCR doesn't work in PRIV mode
    master_ipv4_cidr_block = var.kubernetes_masters_private_ipv4_cidr
  }

  depends_on = [
    google_project_service.service,
    google_project_iam_member.service_account,
    google_compute_router_nat.tgp_nat,
  ]
}

###################################################################################
# Container Registry
data "google_container_registry_repository" "tgp" {
  project  = data.google_project.tgp.project_id
}

resource "google_container_registry" "tgp" {
  project  = data.google_project.tgp.project_id
  location = "US"
}

###################################################################################
# App Instance Template
resource "google_compute_instance_template" "app-template" {
  name          = var.app-template
  machine_type  = "e2-medium"
  region        = var.region

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }
  tags = ["app", "http"]
  disk {
    source_image  = var.centos-7
    auto_delete   = true
    boot          = true
  }

#  metadata = {
#    startup-script = file(var.app-script-path)
#  }
  
  network_interface {
    subnetwork  = google_compute_subnetwork.tgp_public_subnetwork.self_link
    access_config {
      // EPHEMERAL IP
     }
  }
}

resource "google_compute_health_check" "app-autohealing" {
  name                = "app-autohealing-health-check"
  check_interval_sec  = 30
  timeout_sec         = 25
  healthy_threshold   = 2
  unhealthy_threshold = 10

  tcp_health_check {
    port = "22"
  }
}

resource "google_compute_region_instance_group_manager" "app-group" {
  name = "${var.app-name}-instance-group-manager"

  base_instance_name  = "${var.app-name}-app"
  region              = var.region
  
  version {
    instance_template = google_compute_instance_template.app-template.id
  }

  target_size = 0

  named_port {
    name      = "custom-ssh"
    port      = 22
  }

  named_port {
    name      = "http"
    port      = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app-autohealing.id
    initial_delay_sec = 600
  }
}

resource "google_compute_region_autoscaler" "autoscaler" {
 name   = "tgp-app-autoscaler"
 target = google_compute_region_instance_group_manager.app-group.id

 autoscaling_policy {
   max_replicas    = 5
   min_replicas    = 3
   cooldown_period = 600
   cpu_utilization {
      target = 0.85
    }

 }
}

###################################################################################
# MySQL Instance Template
resource "google_compute_instance" "mysql-db" {
  name         = "${var.app-name}-mysql-db"
  machine_type = "n1-standard-1"
  zone         = "us-central1-a"
  
  tags = ["db", "mysql"]

  boot_disk {
    initialize_params {
      image = var.centos-7
    }
  }
  
  # metadata = {
  #  startup-script = file(var.db-script-path)
  #}

  network_interface {
    subnetwork  = google_compute_subnetwork.tgp_private_subnetwork.self_link
  }
}

###################################################################################
# Cloud Load Balancer
resource "google_compute_address" "tgp" {
  name    = "tgp-lb"
  region  = var.region
  project = data.google_project.tgp.project_id

  depends_on = [google_project_service.service]
}

resource "google_compute_global_forwarding_rule" "global-forwarding-rule" {
  name = "${var.app-name}-global-forwarding-rule"
  target      = google_compute_target_http_proxy.target-http-proxy.id
  port_range  = "80"
}

resource "google_compute_backend_service" "backend-service" {
  name = "${var.app-name}-backend-service"
  port_name = "http"
  protocol  = "HTTP"
  
  health_checks = [google_compute_health_check.app-autohealing.self_link]

  backend {
      group = google_compute_region_instance_group_manager.app-group.instance_group
      balancing_mode   = "UTILIZATION"
      capacity_scaler  = 1.0
  }
}

resource "google_compute_url_map" "url-map" {
  name = "${var.app-name}-load-balancer"
  
  default_service = google_compute_backend_service.backend-service.id
}

resource "google_compute_target_http_proxy" "target-http-proxy" {
  name    = "${var.app-name}-proxy"
  url_map = google_compute_url_map.url-map.id
}

resource "google_compute_global_forwarding_rule" "global-forwarding-rule-http" {
  name        = "${var.app-name}-global-forwarding-rule-http"
  target      = google_compute_target_http_proxy.target-http-proxy.id
  port_range  = "80"
}

resource "google_compute_backend_service" "backend-service-http" {
  name = "${var.app-name}-backend-service-http"
 
  port_name = "http"
  protocol  = "HTTP"

  health_checks = [google_compute_health_check.app-autohealing.self_link]

  backend {
      group       = google_compute_region_instance_group_manager.app-group.instance_group
      balancing_mode  = "UTILIZATION"
      capacity_scaler = 1.0
    }
}

resource "google_compute_url_map" "url-map-http" {
  name = "${var.app-name}-load-balancer-http"
  
  default_service = google_compute_backend_service.backend-service-http.id
}

resource "google_compute_health_check" "lb-autohealing" {
  name                = "lb-autohealing-health-check"
  check_interval_sec  = 30
  timeout_sec         = 25
  healthy_threshold   = 2
  unhealthy_threshold = 10

  tcp_health_check {
    port = "82"
  }
}