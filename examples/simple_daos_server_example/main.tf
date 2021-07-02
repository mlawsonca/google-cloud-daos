provider "google" {
  region  = var.region
}

module "daos_server" {
  source             = "../../modules/daos_server"
  project_id         = var.project_id
  network            = var.network
  subnetwork         = var.subnetwork
  subnetwork_project = var.subnetwork_project
  region             = var.region
  zone               = var.zone

  number_of_instances = var.number_of_instances
  daos_disk_count     = var.daos_disk_count

  instance_base_name = var.instance_base_name
  os_disk_size_gb    = var.os_disk_size_gb
  os_disk_type       = var.os_disk_type
  template_name      = var.template_name
  mig_name           = var.mig_name
  machine_type       = var.machine_type
  os_project         = var.os_project
  os_family          = var.os_family
}