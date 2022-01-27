output "project_name" {
  value = data.google_project.tgp.project_id
}

output "project_id" {
  value = random_id.project_random.hex
}

output "cluster_name" {
  value = google_container_cluster.tgp.name
}

output "ip_address" {
  value = google_compute_address.tgp.address
}

output "gcr_url" {
  value = data.google_container_registry_repository.tgp.repository_url
}

output "region" {
  value = var.region
}

output "load_balancer_ip_address" {
  value = google_compute_global_forwarding_rule.global-forwarding-rule.ip_address
}