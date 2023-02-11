#!/bin/bash
# Copyright 2022 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# ------------------------------------------------------------------------------
# Configure the following variables to meet your specific needs
# ------------------------------------------------------------------------------
# Optional identifier to allow multiple DAOS clusters in the same GCP
# project by using this ID in the DAOS server and client instance names.
# Typically, this would contain the username of each user who is running
# the terraform/examples/io500/start.sh script in one GCP project.
# This should be set to a constant value and not the value of an
# environment variable such as '${USER}' which changes depending on where this
# file gets sourced.

##############################################################################
####### user vars ############################################################
##############################################################################

ID=
PROJECT_ID=FIX
NETWORK=FIX
SUBNETWORK=FIX
REGION=FIX
ZONE=FIX

export BUILD_WORKER_POOL="projects/WP_PROJECT_NAME/locations/WP_LOCATION/workerPools/WP_NAME"

#can be adjusted based on the number of CPUs on the node spinning up the cluster
PARALLELISM=20

# Server and client instances
PREEMPTIBLE_INSTANCES=false
SSH_USER="daos-user"
DAOS_ALLOW_INSECURE=true

#used to collect additional monitoring info
USE_PROMETHEUS=false
export SERVERS_ONLY=true

# Server(s)
DAOS_SERVER_INSTANCE_COUNT=56
export DAOS_SERVER_MACHINE_TYPE=n2-custom-36-154368
#export DAOS_SERVER_MACHINE_TYPE=n2d-custom-48-154368
DAOS_SERVER_DISK_COUNT=16
DAOS_SERVER_GVNIC=true
DAOS_SERVER_OS_DISK_SIZE="${DAOS_SERVER_OS_DISK_SIZE:-20}"
DAOS_SERVER_OS_DISK_TYPE="${DAOS_SERVER_OS_DISK_TYPE:-"pd-ssd"}"
export DAOS_SERVER_OS_FAMILY="daos-server-2-2-0-rocky-linux-8"
export DAOS_SERVER_SOURCE_IMAGE_FAMILY="rocky-linux-8-optimized-gcp"
export DAOS_SERVER_SOURCE_IMAGE_PROJECT="rocky-linux-cloud"

# Client(s)
#note - if DAOS_CLIENT_INSTANCE_COUNT=0, there is no need to specify/adjust other DAOS_CLIENT_* variables
DAOS_CLIENT_INSTANCE_COUNT=0
#DAOS_CLIENT_INSTANCE_COUNT=200
export DAOS_CLIENT_MACHINE_TYPE=c2-standard-16
#export DAOS_CLIENT_MACHINE_TYPE=c2d-standard-16
DAOS_CLIENT_GVNIC=false
DAOS_CLIENT_OS_DISK_SIZE="${DAOS_CLIENT_OS_DISK_SIZE:-20}"
DAOS_CLIENT_OS_DISK_TYPE="${DAOS_CLIENT_OS_DISK_TYPE:-"pd-ssd"}"
#fix
export DAOS_CLIENT_OS_FAMILY="daos-client-2-2-0-rocky-linux-8"
export DAOS_CLIENT_SOURCE_IMAGE_FAMILY="rocky-linux-8-optimized-gcp"
export DAOS_CLIENT_SOURCE_IMAGE_PROJECT="rocky-linux-cloud"

# Storage
PERCENT_OF_SSD_FOR_SCM=2

export DAOS_VERSION="2.2.0"
#export DAOS_VERSION="2.3.0"

BASE_CONFIG_ID="GCP-200C-56S16d-GVNIC-n2"
#BASE_CONFIG_ID="GCP-200C-56S16d-GVNIC-n2"

##############################################################################
##############################################################################
##############################################################################

if [[ ("${SERVERS_ONLY}" = true || "${HYPERCONVERGED}" = true) && DAOS_CLIENT_INSTANCE_COUNT -ne 0 ]]; then
   echo "Error. When SERVERS_ONLY=true, the number of clients must equal 0, not ${DAOS_CLIENT_INSTANCE_COUNT} "; 
   exit 1;
else
  echo "okay"
fi

if [[ "${SERVERS_ONLY}" != true && "${HYPERCONVERGED}" = true ]]; then
   echo "Error. When HYPERCONVERGED=true then you must set SERVERS_ONLY=true"
   exit 1;
else
  echo "okay"
fi


# Storage, note: formula assumes all SSD volume will be used for a single pool
GIB_TO_GB_FACTOR=1.07
SSD_SIZE_TB="$(awk -v disk_count=${DAOS_SERVER_DISK_COUNT} -v server_count=${DAOS_SERVER_INSTANCE_COUNT} -v gib_to_gb_factor=${GIB_TO_GB_FACTOR} 'BEGIN {nvme_size = 375 * disk_count * server_count * gib_to_gb_factor / 1000; print nvme_size}')"
SCM_SIZE_TB="$(awk -v ssd_size_tb=${SSD_SIZE_TB} -v percent_ssd_for_scm=${PERCENT_OF_SSD_FOR_SCM} 'BEGIN {scm_size = ssd_size_tb / (100/percent_ssd_for_scm); print scm_size}')"
DAOS_SERVER_SCM_SIZE="$(awk -v scm_size_tb=${SCM_SIZE_TB} -v server_count=${DAOS_SERVER_INSTANCE_COUNT} 'BEGIN {scm_size_per_node_gb = scm_size_tb / server_count * 1000; print scm_size_per_node_gb}')"
DAOS_POOL_SIZE="$(awk -v nvme_size=${SSD_SIZE_TB} -v scm_size=${SCM_SIZE_TB} 'BEGIN {pool_size = nvme_size + scm_size; print pool_size"TB"}')"

DAOS_SERVER_CRT_TIMEOUT=300
export HYPERCONVERGED=false

# ------------------------------------------------------------------------------
# Modify instance base names if ID variable is set
# ------------------------------------------------------------------------------
DAOS_SERVER_BASE_NAME="${DAOS_SERVER_BASE_NAME:-daos-server}"
DAOS_CLIENT_BASE_NAME="${DAOS_CLIENT_BASE_NAME:-daos-client}"
if [[ -n ${ID} ]]; then
    DAOS_SERVER_BASE_NAME="${DAOS_SERVER_BASE_NAME}-${ID}"
    DAOS_CLIENT_BASE_NAME="${DAOS_CLIENT_BASE_NAME}-${ID}"
fi

# ------------------------------------------------------------------------------
# Terraform environment variables
# ------------------------------------------------------------------------------
export TF_CLI_ARGS_plan="-parallelism=${PARALLELISM}"
export TF_CLI_ARGS_apply="-parallelism=${PARALLELISM}"
export TF_CLI_ARGS_destroy="-parallelism=${PARALLELISM}"
export TF_VAR_project_id="${PROJECT_ID}"
export TF_VAR_network="${NETWORK}"
export TF_VAR_subnetwork="${SUBNETWORK}"
export TF_VAR_subnetwork_project="${TF_VAR_project_id}"
export TF_VAR_region="${REGION}"
export TF_VAR_zone="${ZONE}"
export TF_VAR_allow_insecure="${DAOS_ALLOW_INSECURE}"
# Servers
export TF_VAR_server_preemptible=${PREEMPTIBLE_INSTANCES}
export TF_VAR_server_number_of_instances=${DAOS_SERVER_INSTANCE_COUNT}
export TF_VAR_server_daos_disk_count=${DAOS_SERVER_DISK_COUNT}
export TF_VAR_server_daos_crt_timeout=${DAOS_SERVER_CRT_TIMEOUT}
export TF_VAR_server_daos_scm_size=${DAOS_SERVER_SCM_SIZE}
export TF_VAR_server_instance_base_name="${DAOS_SERVER_BASE_NAME}"
export TF_VAR_server_os_disk_size_gb="${DAOS_SERVER_OS_DISK_SIZE}"
export TF_VAR_server_os_disk_type="${DAOS_SERVER_OS_DISK_TYPE}"
export TF_VAR_server_template_name="${DAOS_SERVER_BASE_NAME}"
export TF_VAR_server_mig_name="${DAOS_SERVER_BASE_NAME}"
export TF_VAR_server_machine_type="${DAOS_SERVER_MACHINE_TYPE}"
export TF_VAR_server_os_project="${TF_VAR_project_id}"
export TF_VAR_server_os_family="${DAOS_SERVER_OS_FAMILY}"
export TF_VAR_server_gvnic="${DAOS_SERVER_GVNIC}"
# Clients
export TF_VAR_client_preemptible=${PREEMPTIBLE_INSTANCES}
export TF_VAR_client_number_of_instances=${DAOS_CLIENT_INSTANCE_COUNT}
export TF_VAR_client_instance_base_name="${DAOS_CLIENT_BASE_NAME}"
export TF_VAR_client_os_disk_size_gb="${DAOS_CLIENT_OS_DISK_SIZE}"
export TF_VAR_client_os_disk_type="${DAOS_CLIENT_OS_DISK_TYPE}"
export TF_VAR_client_template_name="${DAOS_CLIENT_BASE_NAME}"
export TF_VAR_client_mig_name="${DAOS_CLIENT_BASE_NAME}"
export TF_VAR_client_machine_type="${DAOS_CLIENT_MACHINE_TYPE}"
export TF_VAR_client_os_project="${TF_VAR_project_id}"
export TF_VAR_client_os_family="${DAOS_CLIENT_OS_FAMILY}"
export TF_VAR_client_gvnic="${DAOS_CLIENT_GVNIC}"

export TF_VAR_daos_version="${DAOS_VERSION}"
