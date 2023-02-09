#!/usr/bin/env bash
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

#
# Runs Terraform to create DAOS Server and Client instances.
# Copies necessary files to clients to allow the IO500 benchmark to be run.
#
# Since some GCP projects are not set up to use os-login this script generates
# an SSH for the daos-user account that exists in the instances. You can then
# use the generated key to log into the first daos-client instance which
# is used as a bastion host.
#

set -eo pipefail
trap 'echo "Hit an unexpected and unchecked error. Exiting."' ERR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
SCRIPT_FILENAME=$(basename "${BASH_SOURCE[0]}")

# shellcheck source=_log.sh
source "${SCRIPT_DIR}/_log.sh"

# shellcheck disable=SC2034
LOG_LEVEL=INFO

# Directory where all generated files will be stored
IO500_TMP="${SCRIPT_DIR}/tmp"

# Directory containing config files
CONFIG_DIR="${CONFIG_DIR:-${SCRIPT_DIR}/config}"

# Config file in ./config that is used to spin up the environment and configure IO500
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.sh}"

# active_config.sh is a symlink to the last config file used by start.sh
ACTIVE_CONFIG="${CONFIG_DIR}/active_config.sh"

# SSH config file path
# We generate an SSH config file that is used with 'ssh -F' to simplify logging
# into the first DAOS client instance. The first DAOS client instance is our
# bastion host for the IO500 example.
SSH_CONFIG_FILE="${IO500_TMP}/ssh_config"

# Use internal IP for SSH connection with the first daos client
USE_INTERNAL_IP=0

ERROR_MSGS=()

show_help() {
  cat <<EOF

Usage:

  ${SCRIPT_FILENAME} <options>

  Set up DAOS server and client images in GCP that are capable of running the
  IO500 benchmark.

Options:

  [ -c --config   CONFIG_FILE ]   Path to a configuration file.
                                  See files in ./config
                                  Default: ./config/config.sh

  [ -v --version  DAOS_VERSION ]  Version of DAOS to install

  [ -u --repo-baseurl DAOS_REPO_BASE_URL ] Base URL of a repo.

  [ -i --internal-ip ]            Use internal IP for SSH to the first client

  [ -f --force ]                  Force images to be re-built

  [ -h --help ]                   Show help

Examples:

  Deploy a DAOS environment with a specifc configuration

    ${SCRIPT_FILENAME} -c ./config/config_1c_1s_8d.sh

EOF
}

show_errors() {
  # If there are errors, print the error messages and exit
  if [[ ${#ERROR_MSGS[@]} -gt 0 ]]; then
    # shellcheck disable=SC2034
    for msg in "${ERROR_MSGS[@]}"; do
      log.error "${ERROR_MSGS[@]}"
    done
    #show_help
    exit 1
  fi
}

check_dependencies() {
  # Exit if gcloud command not found
  if ! gcloud -v &> /dev/null; then
    log.error "'gcloud' command not found
       Is the Google Cloud Platform SDK installed?
       See https://cloud.google.com/sdk/docs/install"
    exit 1
  fi
  # Exit if terraform command not found
  if ! terraform -v &> /dev/null; then
    log.error "'terraform' command not found
       Is Terraform installed?"
    exit 1
  fi
}

opts() {

  # shift will cause the script to exit if attempting to shift beyond the
  # max args.  So set +e to continue processing when shift errors.
  set +e
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config|-c)
        CONFIG_FILE="$2"
        if [[ "${CONFIG_FILE}" == -* ]] || [[ "${CONFIG_FILE}" == "" ]] || [[ -z ${CONFIG_FILE} ]]; then
          ERROR_MSGS+=("ERROR: Missing CONFIG_FILE value for -c or --config")
          break
        elif [[ ! -f "${CONFIG_FILE}" ]]; then
          ERROR_MSGS+=("ERROR: Configuration file '${CONFIG_FILE}' not found.")
        fi
        export CONFIG_FILE
        shift 2
      ;;
      --internal-ip|-i)
        USE_INTERNAL_IP=1
        shift
      ;;
      --version|-v)
        DAOS_VERSION="${2}"
        if [[ "${DAOS_VERSION}" == -* ]] || [[ "${DAOS_VERSION}" = "" ]] || [[ -z ${DAOS_VERSION} ]]; then
          log.error "Missing DAOS_VERSION value for -v or --version"
          show_help
          exit 1
        fi
        export DAOS_VERSION
        shift 2
      ;;
      --repo-baseurl|-u)
        DAOS_REPO_BASE_URL="${2}"
        if [[ "${DAOS_REPO_BASE_URL}" == -* ]] || [[ "${DAOS_REPO_BASE_URL}" = "" ]] || [[ -z ${DAOS_REPO_BASE_URL} ]]; then
          log.error "Missing URL value for -u or --repo-baseurl"
          show_help
          exit 1
        fi
        export DAOS_REPO_BASE_URL
        shift 2
      ;;
      --force|-f)
        FORCE_REBUILD=1
        export FORCE_REBUILD
        shift
      ;;
      --help|-h)
        show_help
        exit 0
      ;;
      --*|-*)
        ERROR_MSGS+=("ERROR: Unrecognized option '${1}'")
        shift
        break
      ;;
      *)
        ERROR_MSGS+=("ERROR: Unrecognized option '${1}'")
        shift
        break
      ;;
    esac
  done
  set -eo pipefail

  show_errors
}

create_active_config_symlink() {
  # Create a ${IO500_TMP}/config/active_config.sh symlink that points to the
  # config file that is being used now. This is needed so that the stop.sh can
  # always source the same config file that was used in start.sh
  if [[ -L "${ACTIVE_CONFIG}" ]]; then
    current_config=$(readlink "${ACTIVE_CONFIG}")
    if [[ "$(basename "${CONFIG_FILE}")" != $(basename "${current_config}") ]]; then
       read -r -d '' err_msg <<EOF || true
ERROR
Cannot use configuration: ${CONFIG_FILE}
An active configuration already exists: ${current_config}

You must run

  ${SCRIPT_FILENAME} -c ${current_config}

or run the stop.sh script before running

  ${SCRIPT_FILENAME} -c ${CONFIG_FILE}
EOF
      log.error "${err_msg}"
      exit 1
    fi
  else
    ln -snf "${CONFIG_FILE}" "${CONFIG_DIR}/active_config.sh"
  fi
}

load_config() {
  # Load configuration which contains wall settings for Terraform and the IO500
  # benchmark
  log.info "Sourcing config file: ${CONFIG_FILE}"
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  if ${HYPERCONVERGED}; then
    node_type="server"
  else
    node_type="client"
  fi

}

create_hosts_files() {

  # pdsh or clush commands will need to be run from the first daos-client
  # instance. Those commands will need to take a file which contains a list of
  # hosts.  This function creates 3 files:
  #    hosts_clients - a list of daos-client* hosts
  #    hosts_servers - a list of daos-server* hosts
  #    hosts_all     - a list of all hosts
  # The copy_files_to_first_client function in this script will copy the hosts_* files to
  # the first daos-client instance.

  unset CLIENTS
  unset SERVERS
  unset ALL_NODES

  mkdir -p "${IO500_TMP}"
  HOSTS_CLIENTS_FILE="${IO500_TMP}/hosts_clients"
  HOSTS_SERVERS_FILE="${IO500_TMP}/hosts_servers"
  HOSTS_ALL_FILE="${IO500_TMP}/hosts_all"

  rm -f "${HOSTS_CLIENTS_FILE}" "${HOSTS_SERVERS_FILE}" "${HOSTS_ALL_FILE}"

  for ((i=1; i<=DAOS_CLIENT_INSTANCE_COUNT; i++))
  do
      CLIENTS+="${DAOS_CLIENT_BASE_NAME}-$(printf "%04d" "${i}") "
      echo "${DAOS_CLIENT_BASE_NAME}-$(printf "%04d" "${i}")" >> "${HOSTS_CLIENTS_FILE}"
      echo "${DAOS_CLIENT_BASE_NAME}-$(printf "%04d" "${i}")" >> "${HOSTS_ALL_FILE}"
  done

  for ((i=1; i<=DAOS_SERVER_INSTANCE_COUNT; i++))
  do
      SERVERS+="${DAOS_SERVER_BASE_NAME}-$(printf "%04d" "${i}") "
      echo "${DAOS_SERVER_BASE_NAME}-$(printf "%04d" "${i}")" >> "${HOSTS_SERVERS_FILE}"
      echo "${DAOS_SERVER_BASE_NAME}-$(printf "%04d" "${i}")" >> "${HOSTS_ALL_FILE}"
  done



  if ${HYPERCONVERGED}; then
    DAOS_FIRST_CLIENT=$(echo "${SERVERS}" | awk '{print $1}')
  else
    DAOS_FIRST_CLIENT=$(echo "${CLIENTS}" | awk '{print $1}')
  fi
  DAOS_FIRST_SERVER=$(echo "${SERVERS}" | awk '{print $1}')

  ALL_NODES="${SERVERS} ${CLIENTS}"

  export CLIENTS
  export DAOS_FIRST_CLIENT
  export HOSTS_CLIENTS_FILE
  export SERVERS
  export DAOS_FIRST_SERVER
  export HOSTS_SERVERS_FILE
  export ALL_NODES

}

build_disk_images() {
  # Build the DAOS disk images
  log.section "IO500 Disk Images"
  "${SCRIPT_DIR}/build_daos_io500_images.sh" --type all -i false
}

run_terraform() {
  log.section "Deploying DAOS Servers and Clients using Terraform"
  pushd ../daos_cluster
  terraform init -input=false
  terraform plan -out=tfplan -input=false
  terraform apply -input=false tfplan
  popd
}

configure_first_client_ip() {

  log.info "Wait for DAOS ${node_type} instances"


  if [[ "${USE_INTERNAL_IP}" -eq 1 ]]; then
    FIRST_CLIENT_IP=$(gcloud compute instances describe "${DAOS_FIRST_CLIENT}" \
      --project="${TF_VAR_project_id}" \
      --zone="${TF_VAR_zone}" \
      --format="value(networkInterfaces[0].networkIP)")

    # Check to see if first client instance has an external IP.
    # If it does, then don't attempt to add an external IP again.
    NAT_NETWORK=$(gcloud compute routers nats list \
      "--router=nat-router-us-central1" \
      "--region=us-central1")

    if [[ -z "${NAT_NETWORK}" ]]; then
      log "Add external IP to first ${node_type}"

      #Create a Cloud Router instance
      gcloud compute routers create nat-router-us-central1 \
        --network default \
        --region us-central1

      #Configure the router for Cloud NAT
      gcloud compute routers nats create nat-config \
        --router-region us-central1 \
        --router nat-router-us-central1 \
        --nat-all-subnet-ip-ranges \
        --auto-allocate-nat-external-ips
    fi
  else
    # Check to see if first client instance has an external IP.
    # If it does, then don't attempt to add an external IP again.
    FIRST_CLIENT_IP=$(gcloud compute instances describe "${DAOS_FIRST_CLIENT}" \
      --project="${TF_VAR_project_id}" \
      --zone="${TF_VAR_zone}" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

    if [[ -z "${FIRST_CLIENT_IP}" ]]; then
      log.info "Add external IP to first ${node_type}"

      gcloud compute instances add-access-config "${DAOS_FIRST_CLIENT}" \
        --project="${TF_VAR_project_id}" \
        --zone="${TF_VAR_zone}" \
        && sleep 10

      FIRST_CLIENT_IP=$(gcloud compute instances describe "${DAOS_FIRST_CLIENT}" \
        --project="${TF_VAR_project_id}" \
        --zone="${TF_VAR_zone}" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
    fi
  fi
}

configure_ssh() {
  # TODO: Need improvements here.
  #       Using os_login is preferred but after some users ran into issues with it
  #       this turned out to be the method that worked for most users.
  #       This function generates a key pair and an ssh config file that is
  #       used to log into the first daos-client node as the 'daos-user' user.
  #       This isn't ideal in team situations where a team member who was not
  #       the one who ran this start.sh script needs to log into the instances
  #       as the 'daos-user' in order to run IO500 or do troubleshooting.
  #       If os-login was used, then project admins would be able to control
  #       who has access to the daos-* instances. Users would access the daos-*
  #       instances the same way they do all other instances in their project.

  log.section "Configure SSH on first ${node_type} instance ${DAOS_FIRST_CLIENT}"

  # Create an ssh key for the current IO500 example environment
  if [[ ! -f "${IO500_TMP}/id_rsa" ]]; then
    log.info "Generating SSH key pair"
    ssh-keygen -t rsa -b 4096 -C "${SSH_USER}" -N '' -f "${IO500_TMP}/id_rsa"
  fi
  chmod 600 "${IO500_TMP}/id_rsa"

  if [[ ! -f "${IO500_TMP}/id_rsa.pub" ]]; then
    log.error "Missing file: ${IO500_TMP}/id_rsa.pub"
    log.error "Unable to continue without id_rsa and id_rsa.pub files in ${IO500_TMP}"
    exit 1
  fi

  # Generate file containing keys which will be added to the metadata of all nodes.
  echo "${SSH_USER}:$(cat "${IO500_TMP}/id_rsa.pub")" > "${IO500_TMP}/keys.txt"

  # Only update instance meta-data once
  if ! gcloud compute instances describe "${DAOS_FIRST_CLIENT}" \
    --project="${TF_VAR_project_id}" \
    --zone="${TF_VAR_zone}" \
    --format='value[](metadata.items.ssh-keys)' | grep -q "${SSH_USER}"; then

    log.info "Disable os-login and add '${SSH_USER}' SSH key to metadata on all instances"
    for node in ${ALL_NODES}; do
      echo "Updating metadata for ${node}"
      # Disable OSLogin to be able to connect with SSH keys uploaded in next command
      gcloud compute instances add-metadata "${node}" \
        --project="${TF_VAR_project_id}" \
        --zone="${TF_VAR_zone}" \
        --metadata enable-oslogin=FALSE && \
      # Upload SSH key to instance, so that you can log into instance via SSH
      gcloud compute instances add-metadata "${node}" \
        --project="${TF_VAR_project_id}" \
        --zone="${TF_VAR_zone}" \
        --metadata-from-file ssh-keys="${IO500_TMP}/keys.txt" &
    done
    # Wait for instance meta-data updates to finish
    wait
  fi

  # Create ssh config for all instances
  cat > "${IO500_TMP}/instance_ssh_config" <<EOF
Host *
    CheckHostIp no
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
    LogLevel ERROR
EOF
  chmod 600 "${IO500_TMP}/instance_ssh_config"

  # Create local ssh config
  cat > "${SSH_CONFIG_FILE}" <<EOF
Include ~/.ssh/config
Include ~/.ssh/config.d/*

Host ${FIRST_CLIENT_IP}
    CheckHostIp no
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
    IdentitiesOnly yes
    LogLevel ERROR
    User ${SSH_USER}
    IdentityFile ${IO500_TMP}/id_rsa

EOF
  chmod 600 "${SSH_CONFIG_FILE}"

  log.info "Copy SSH key to first DAOS ${node_type} instance ${DAOS_FIRST_CLIENT}"

  # Create ~/.ssh directory on first daos-client instance
  ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
    "mkdir -m 700 -p ~/.ssh"

  # Copy SSH key pair to first daos-client instance
  scp -q -F "${SSH_CONFIG_FILE}" \
    "${IO500_TMP}/id_rsa" \
    "${IO500_TMP}/id_rsa.pub" \
    "${FIRST_CLIENT_IP}:~/.ssh/"

  # Copy SSH config to first daos-client instance and set permissions
  scp -q -F "${SSH_CONFIG_FILE}" \
    "${IO500_TMP}/instance_ssh_config" \
    "${FIRST_CLIENT_IP}:~/.ssh/config"
  ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
    "chmod -R 600 ~/.ssh/*"

  echo "#!/usr/bin/env bash
  ssh -F ./tmp/ssh_config ${FIRST_CLIENT_IP}" > "${SCRIPT_DIR}/login"
  chmod +x "${SCRIPT_DIR}/login"
}

copy_files_to_first_client() {
  # Copy the files that will be needed in order to run pdsh, clush and other
  # commands on the first daos-client instance

  log.info "Copy files to first ${node_type} ${DAOS_FIRST_CLIENT}"

  # Copy the config file for the IO500 example environment
  scp -F "${SSH_CONFIG_FILE}" \
    "${CONFIG_FILE}" \
    "${SSH_USER}"@"${FIRST_CLIENT_IP}":~/config.sh

  if ! ${HYPERCONVERGED}; then
    scp -F "${SSH_CONFIG_FILE}" \
      "${HOSTS_CLIENTS_FILE}" \
      "${HOSTS_SERVERS_FILE}" \
      "${HOSTS_ALL_FILE}" \
      "${SCRIPT_DIR}/_log.sh" \
      "${SCRIPT_DIR}/clean_storage.sh" \
      "${SCRIPT_DIR}/run_io500-sc22.sh" \
      "${SCRIPT_DIR}/io500-sc22.config-template.daos.ini" \
      "${SCRIPT_DIR}/run_ior.sh" \
      "${SCRIPT_DIR}/run_fio.sh" \
      "${SCRIPT_DIR}/create_container.sh" \
      "${SCRIPT_DIR}/destroy_container.sh" \
      "${FIRST_CLIENT_IP}:~/"
  else

    mkdir -p "${IO500_TMP}/clients_only_scripts/.ssh"
    cp -t "${IO500_TMP}/clients_only_scripts" \
      "${HOSTS_SERVERS_FILE}" \
      "${SCRIPT_DIR}/_log.sh" \
      "${SCRIPT_DIR}/clean_storage.sh" \
      "${SCRIPT_DIR}/run_io500-sc22.sh" \
      "${SCRIPT_DIR}/io500-sc22.config-template.daos.ini" \
      "${SCRIPT_DIR}/run_ior.sh" \
      "${SCRIPT_DIR}/run_fio.sh" \
      "${SCRIPT_DIR}/create_container.sh" \
      "${SCRIPT_DIR}/destroy_container.sh" \
      "${SCRIPT_DIR}/install_scripts/build_daos_el8.sh" \
      "${CONFIG_FILE}" \
      "../../../images/scripts/tune.sh"


    cp -t "${IO500_TMP}/clients_only_scripts/.ssh" \
      "${IO500_TMP}/id_rsa" \
      "${IO500_TMP}/id_rsa.pub"
      # "${IO500_TMP}/keys.txt"

    sudo cp "${IO500_TMP}/instance_ssh_config" "${IO500_TMP}/clients_only_scripts/.ssh/config"

    #chmod -R 600 "${IO500_TMP}/clients_only_scripts/.ssh/"*

    cat > "${IO500_TMP}/clients_only_scripts/startup_script.sh" <<'OUTEREOF'
#!/usr/bin/env bash

SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"
MY_DAOS_INSTALL_PATH="${MY_DAOS_INSTALL_PATH:-/usr}"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"

# Source config file to load variables
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

pushd ${MY_DAOS_INSTALL_PATH}
sudo ${SCRIPT_DIR}/build_daos_el8.sh
popd
sudo cp -r ${SCRIPT_DIR}/.ssh/* ~/.ssh

# Create agent config files from metadata
sudo mkdir -p /etc/daos

sudo bash -c 'cat > /etc/daos/daos_agent.yml' << EOF
#
# DAOS agent configuration file
#

# Management server access points
# Must have the same value for all agents and servers in a system.
access_points: [""]

transport_config:
  allow_insecure: ${DAOS_ALLOW_INSECURE}


fabric_ifaces:
- numa_node: 0
  devices:
  - iface: eth0
    domain: eth0
EOF

sudo bash -c 'cat > /etc/daos/daos_control.yml' << EOF
#
# DAOS manager (dmg) configuration file
#

hostlist: [""]

transport_config:
  allow_insecure: ${DAOS_ALLOW_INSECURE}
EOF

SERVER_LIST=$(awk -vORS=, '{ print $1 }' "${SCRIPT_DIR}/hosts_servers" | sed 's/,$/\n/')
NUM_SERVERS=$(wc -l "${SCRIPT_DIR}/hosts_servers" | cut -c 1)
if [[ ${NUM_SERVERS} -ge 3 ]]; then
  ACCESS_LIST=$(head -n 3 "${SCRIPT_DIR}/hosts_servers" | awk -vORS=, '{ print $1 }'  | sed 's/,$/\n/')
else
  ACCESS_LIST=$(head -n 1 "${SCRIPT_DIR}/hosts_servers")
fi

sudo sed -i "s/hostlist:.*/hostlist: [${SERVER_LIST}]/g" '/etc/daos/daos_control.yml'
sudo sed -i "s/access_points:.*/access_points: [${ACCESS_LIST}]/g" '/etc/daos/daos_agent.yml'
sudo chown -R daos_agent:daos_agent /etc/daos/

if [[ ! -f /usr/lib64/daos/certgen/gen_certificates.sh ]]; then
  echo "ERROR! File not found: /usr/lib64/daos/certgen/gen_certificates.sh"
  exit 1
fi
echo "Generating DAOS certificates"
sudo mkdir -p /etc/daos
FIRST_SERVER=$(head -n 1 "${SCRIPT_DIR}/hosts_servers")
ssh ${FIRST_SERVER} "sudo tar --absolute-names -czvf certs.tar.gz /etc/daos"
scp ${FIRST_SERVER}:~/certs.tar.gz ~/certs.tar.gz
sudo tar --absolute-names -xzvf ~/certs.tar.gz
rm -f ~/certs.tar.gz
ssh ${FIRST_SERVER} "rm -f ~/certs.tar.gz"

sudo systemctl enable daos_agent
sudo systemctl start daos_agent

echo "END: DAOS Client Startup Script"

OUTEREOF

  chmod +x "${IO500_TMP}/clients_only_scripts/"*.sh


    pushd "${IO500_TMP}"
    sudo tar -czvf clients_only_scripts.tar.gz "./clients_only_scripts"
    popd


    scp -F "${SSH_CONFIG_FILE}" \
      "${HOSTS_SERVERS_FILE}" \
      "${HOSTS_ALL_FILE}" \
      "${SCRIPT_DIR}/_log.sh" \
      "${SCRIPT_DIR}/config/config.sh" \
      "${SCRIPT_DIR}/install_scripts/install_devtools.sh" \
      "${SCRIPT_DIR}/install_scripts/install_intel-oneapi.sh" \
      "${SCRIPT_DIR}/install_scripts/install_io500-sc22.sh" \
      "${SCRIPT_DIR}/io500-sc22.config-template.daos.ini" \
      "${SCRIPT_DIR}/hyperconverged_scripts/"*.sh \
      "${FIRST_CLIENT_IP}:~/"

  fi


  ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
    "chmod +x ~/*.sh && chmod -x ~/config.sh"


}

copy_ssh_keys_to_all_nodes () {
  # Clear ~/.ssh/known_hosts so we don't run into any issues
  ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
    "clush --hostfile=hosts_all --dsh 'rm -f ~/.ssh/known_hosts'"

  # Copy ~/.ssh directory to all instances
  ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
    "clush --hostfile=hosts_all --dsh --copy ~/.ssh --dest ~/"
}

wait_for_startup_script_to_finish () {
  ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
    "printf 'Waiting for startup script to finish\n'
     until sudo journalctl -u google-startup-scripts.service --no-pager | grep 'Finished running startup scripts.'
     do
       printf '.'
       sleep 5
     done
     printf '\n'
    "
}

set_permissions_on_cert_files () {
  if [[ "${DAOS_ALLOW_INSECURE}" == "false" ]]; then
    ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
      "clush --hostfile=hosts_${node_type}s --dsh 'sudo chown ${SSH_USER}:${SSH_USER} /etc/daos/certs/daosCA.crt'"
    ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" \
      "clush --hostfile=hosts_${node_type}s --dsh 'sudo chown ${SSH_USER}:${SSH_USER} /etc/daos/certs/admin.*'"
  fi
}

show_instances() {
  log.section "DAOS Server and Client instances"
  DAOS_FILTER="$(echo "${DAOS_SERVER_BASE_NAME}" | sed -r 's/server/.*/g')-.*"
  gcloud compute instances list \
    --project="${TF_VAR_project_id}" \
    --zones="${TF_VAR_zone}" \
    --filter="name~'^${DAOS_FILTER}'"
}

check_gvnic() {
  DAOS_SERVER_NETWORK_TYPE=$(ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" "ssh ${DAOS_FIRST_SERVER} 'sudo lshw -class network'" | sed -n "s/^.*product: \(.*\$\)/\1/p")
  if ! ${HYPERCONVERGED}; then
    DAOS_CLIENT_NETWORK_TYPE=$(ssh -q -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" "sudo lshw -class network" | sed -n "s/^.*product: \(.*\$\)/\1/p")
  fi
  log.debug "Network adapters type:"
  log.debug "DAOS_SERVER_NETWORK_TYPE = ${DAOS_SERVER_NETWORK_TYPE}"
  log.debug "DAOS_CLIENT_NETWORK_TYPE = ${DAOS_CLIENT_NETWORK_TYPE}"
}

show_run_steps() {

   log.section "DAOS instances are ready for IO500 run"

   cat <<EOF

To run the IO500 benchmark:

1. Log into the first server
   ./login

2. Run IO500
   ./run_io500-sc22.sh

EOF

}

main() {
  check_dependencies
  opts "$@"
  create_active_config_symlink
  load_config
  create_hosts_files
  build_disk_images
  run_terraform
  configure_first_client_ip
  configure_ssh
  copy_files_to_first_client
  copy_ssh_keys_to_all_nodes
  wait_for_startup_script_to_finish
  set_permissions_on_cert_files
  show_instances
  check_gvnic
  show_run_steps
}

main "$@"
