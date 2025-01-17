/**
 * Copyright 2021 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  build_type         = var.build_type
  daos_version       = var.daos_version
  os_project         = var.os_project != null ? var.os_project : var.project_id
  subnetwork_project = var.subnetwork_project != null ? var.subnetwork_project : var.project_id
  servers            = var.number_of_instances == 1 ? local.first_server : format("%s-[%04s-%04s]", var.instance_base_name, 1, var.number_of_instances)
  first_server       = format("%s-%04s", var.instance_base_name, 1)
  max_aps            = var.number_of_instances > 5 ? 5 : (var.number_of_instances % 2) == 1 ? var.number_of_instances : var.number_of_instances - 1
  access_points      = formatlist("%s-%04s", var.instance_base_name, range(1, local.max_aps + 1))
  scm_size           = var.daos_scm_size
  # To get nr_hugepages value: (targets * 1Gib) / hugepagesize
  huge_pages        = (var.daos_disk_count * 1048576) / 2048
  targets           = var.daos_disk_count
  crt_timeout       = var.daos_crt_timeout
  allow_insecure    = var.allow_insecure
  pools             = var.pools
  daos_ca_secret_id = !local.allow_insecure ? basename(google_secret_manager_secret.daos_ca[0].id) : ""

  # Google Virtual NIC (gVNIC) network interface
  nic_type                    = var.gvnic ? "GVNIC" : "VIRTIO_NET"
  total_egress_bandwidth_tier = var.gvnic ? "TIER_1" : "DEFAULT"

   daos_server_yaml_content = templatefile(
     "${path.module}/templates/daos_server.yml.tftpl",
     {
       access_points  = local.access_points
       nr_hugepages   = local.huge_pages
       targets        = local.targets
       scm_size       = local.scm_size
       crt_timeout    = local.crt_timeout
       allow_insecure = local.allow_insecure
     }
   )

   daos_control_yaml_content = templatefile(
     "${path.module}/templates/daos_control.yml.tftpl",
     {
       servers        = [local.servers]
       allow_insecure = local.allow_insecure
     }
   )

   daos_agent_yaml_content = templatefile(
     "${path.module}/templates/daos_agent.yml.tftpl",
     {
       access_points  = local.access_points
       allow_insecure = local.allow_insecure
     }
   )

   certs_gen_content = templatefile(
     "${path.module}/templates/certs_gen.inc.sh.tftpl",
     {
       allow_insecure    = local.allow_insecure
       daos_ca_secret_id = local.daos_ca_secret_id
     }
   )

   certs_install_content = templatefile(
     "${path.module}/templates/certs_install.inc.sh.tftpl",
     {
       allow_insecure    = local.allow_insecure
       daos_ca_secret_id = local.daos_ca_secret_id
     }
   )

   client_install_script_content = file(
   "${path.module}/scripts/client_install.sh")

   client_config_script_content = templatefile(
     "${path.module}/templates/client_config.sh.tftpl",
     {
       certs_install_content = local.certs_install_content
     }
   )

   storage_format_content = templatefile(
     "${path.module}/templates/storage_format.inc.sh.tftpl",
     {
       servers = local.servers
     }
   )

   pool_cont_create_content = templatefile(
     "${path.module}/templates/pool_cont_create.inc.sh.tftpl",
     {
       servers = local.servers
       pools   = local.pools
     }
   )

   startup_script = templatefile(
     "${path.module}/templates/startup_script.tftpl",
     {
       first_server             = local.first_server
       certs_gen_content        = local.certs_gen_content
       certs_install_content    = local.certs_install_content
       storage_format_content   = local.storage_format_content
       pool_cont_create_content = local.pool_cont_create_content
       daos_version             = local.daos_version
       build_type               = local.build_type
     }
   )
}

data "google_compute_image" "os_image" {
  family  = var.os_family
  project = local.os_project
}


resource "google_compute_disk" "boot_disk" {
  project = var.project_id
  count = var.number_of_instances
  name = format("%s-%04d-boot-disk", var.instance_base_name, count.index+1)
  image  = data.google_compute_image.os_image.self_link
  type   = var.os_disk_type
  size   = var.os_disk_size_gb
  zone   = var.zone
}


resource "google_compute_instance" "named_instances" {
  provider = google-beta
  zone                   = var.zone
  project                = var.project_id
  labels         = var.labels
  count = var.number_of_instances
  name         = format("%s-%04d", var.instance_base_name, count.index+1)
  can_ip_forward = false
  tags           = ["daos-server"]
  machine_type = var.machine_type

  #note: could re-enable this if using N2 instead of N2D
  #min_cpu_platform = "Intel Ice Lake"


   metadata = {
     inst_type                 = "daos-server"
     enable-oslogin            = "true"
     inst_nr                   = var.number_of_instances
     inst_base_name            = var.instance_base_name
     daos_server_yaml_content  = local.daos_server_yaml_content
     daos_control_yaml_content = local.daos_control_yaml_content
     daos_agent_yaml_content   = local.daos_agent_yaml_content
     startup-script            = local.startup_script
     # Adding a reference to the instance template used causes the stateful instance to update
     # if the instance template changes. Otherwise there is no explicit dependency and template
     # changes may not occur on the stateful instance
   }


  boot_disk {
    source      = google_compute_disk.boot_disk[count.index].self_link
    auto_delete  = true
  }

   dynamic "scratch_disk" {
     for_each = range(var.daos_disk_count)
     content {
       interface    = "NVME"
     }
   }

  network_interface {
    network            = var.network_name
    subnetwork         = var.subnetwork_name
    subnetwork_project = local.subnetwork_project
    nic_type           = local.nic_type
  }

   network_performance_config {
     total_egress_bandwidth_tier = local.total_egress_bandwidth_tier
   }

   dynamic "service_account" {
     for_each = var.service_account == null ? [] : [var.service_account]
     content {
       email  = lookup(service_account.value, "email", null)
       scopes = lookup(service_account.value, "scopes", null)
     }
   }

   scheduling {
     preemptible       = var.preemptible
     automatic_restart = false
   }

  #advanced_machine_features {
  #  threads_per_core = 1
  #  visible_core_count = split("-", var.machine_type)[2]/2
  #}
}


 data "google_compute_default_service_account" "default" {
   project = var.project_id
 }


data "google_iam_policy" "daos_ca_secret_version_manager" {
   count       = !local.allow_insecure ? 1 : 0
   binding {
     role = "roles/secretmanager.secretVersionManager"
     members = [
       format("serviceAccount:%s", var.service_account.email == null ? data.google_compute_default_service_account.default.email : var.service_account.email)
     ]
   }
   binding {
     role = "roles/secretmanager.viewer"
     members = [
       format("serviceAccount:%s", var.service_account.email == null ? data.google_compute_default_service_account.default.email : var.service_account.email)
     ]
   }
   binding {
     role = "roles/secretmanager.secretAccessor"
     members = [
       format("serviceAccount:%s", var.service_account.email == null ? data.google_compute_default_service_account.default.email : var.service_account.email)
     ]
   }
 }

 resource "google_secret_manager_secret_iam_policy" "daos_ca_secret_policy" {
   count       = !local.allow_insecure ? 1 : 0
   project     = var.project_id
   secret_id   = google_secret_manager_secret.daos_ca[0].secret_id
   policy_data = data.google_iam_policy.daos_ca_secret_version_manager[0].policy_data
 }

 resource "google_secret_manager_secret" "daos_ca" {
   count       = !local.allow_insecure ? 1 : 0
   secret_id = format("%s_ca", var.instance_base_name)
   project   = var.project_id

   replication {
     user_managed {
       replicas {
         location = var.region
       }
     }
   }
 }


