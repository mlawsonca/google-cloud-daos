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
# Cleans DAOS storage and runs an IO500 benchmark
#
# Instructions that were referenced to create this script are at
# https://daosio.atlassian.net/wiki/spaces/DC/pages/11167301633/IO-500+SC22
#

set -eo pipefail
trap 'echo "Hit an unexpected and unchecked error. Unmounting and exiting."; unmount' ERR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

# shellcheck source=_log.sh
source "${SCRIPT_DIR}/_log.sh"
export LOG_LEVEL=INFO

IO500_VERSION_TAG="io500-sc22"
IO500_DIR="${IO500_DIR:-"/opt/${IO500_VERSION_TAG}"}"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"

# Source config file to load variables
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

####### user vars ########
OCLASS_1="S1"
OCLASS_X="SX"
DAOS_CONT_REPLICATION_FACTOR="rf:0"
TEST_CONFIG_ID="${BASE_CONFIG_ID}-rf0-hyper-io500"
#OCLASS_1="EC_2P1G1"
#OCLASS_X="EC_2P1GX"
#DAOS_CONT_REPLICATION_FACTOR="rf:1,ec_cell_sz:131072"
#TEST_CONFIG_ID="${BASE_CONFIG_ID}-rf1-hyper-io500"

IO500_STONEWALL_TIME=60
IO500_INI="io500-sc22.config-template.daos.ini"
##########################

# Comma separated list of servers needed for the dmg command
# TODO: Figure out a better way for this script to get the list of servers
#       Requiring the hosts_servers file is not ideal
SERVER_LIST=$(awk -vORS=, '{ print $1 }' "${SCRIPT_DIR}/hosts_servers" | sed 's/,$/\n/')

IO500_STONEWALL_TIME="${IO500_STONEWALL_TIME:-5}"

IO500_DFUSE_DIR="${IO500_DFUSE_DIR:-"${HOME}/daos_fuse/${IO500_VERSION_TAG}"}"
IO500_RESULTS_DFUSE_DIR="${IO500_RESULTS_DFUSE_DIR:-"${IO500_DFUSE_DIR}/results"}"
IO500_DATAFILES_DFUSE_DIR="${IO500_DATAFILES_DFUSE_DIR:-"/datafiles"}"

IO500_RESULTS_DIR="${IO500_RESULTS_DIR:-"${HOME}/${IO500_VERSION_TAG}/results"}"

DAOS_POOL_LABEL="${DAOS_POOL_LABEL:-io500_pool}"
DAOS_CONT_LABEL="${DAOS_CONT_LABEL:-io500_cont}"

unmount_defuse() {
  log.info "Attempting to unmount DFuse mountpoint ${IO500_DFUSE_DIR}"
  if findmnt --target "${IO500_DFUSE_DIR}" > /dev/null; then
    log.info "Unmount DFuse mountpoint ${IO500_DFUSE_DIR}"

    clush --hostfile=hosts_servers --dsh \
      "sudo fusermount3 -u ${IO500_DFUSE_DIR}"

    clush --hostfile=hosts_servers --dsh \
      "rm -r ${IO500_DFUSE_DIR}"

    clush --hostfile=hosts_servers --dsh \
      "mount | sort | grep dfuse || true"

    log.info "fusermount3 complete!"
  fi
}

cleanup(){
  log.info "Clean up DAOS storage"
  unmount_defuse
  if [[ "${USE_PROMETHEUS}" = true ]]; then
    SERVER_LIST=$(awk -vORS=, '{ print $1 }' "${SCRIPT_DIR}/hosts_servers" | sed 's/,$/\n/')
    if [[ ! -f "${SCRIPT_DIR}/prometheus" ]]; then
      SERVER_LIST=$(awk -vORS=, '{ print $1 }' "${SCRIPT_DIR}/hosts_servers" | sed 's/,$/\n/')
      sudo sed -i "s/hostlist:.*/hostlist: [${SERVER_LIST}]/g" '/etc/daos/daos_control.yml'
      #we just want to install it once or we run into hitting the maximum number of git requests per hour
      dmg telemetry config --install-dir="${SCRIPT_DIR}"

      while IFS= read -r dest; do
        scp "${SCRIPT_DIR}/prometheus" "${SCRIPT_DIR}/.prometheus.yml" "$dest:"
      done <"${SCRIPT_DIR}/hosts_servers"
    fi
  fi
  "${SCRIPT_DIR}/clean_storage.sh"
}

storage_scan() {
  log.info "Run DAOS storage scan"
  log.debug "COMMAND: dmg -l \"${SERVER_LIST}\" storage scan --verbose"
  dmg -l "${SERVER_LIST}" storage scan --verbose
}

format_storage() {
  log.info "Format DAOS storage"
  log.debug "COMMAND: dmg -l \"${SERVER_LIST}\" storage format"
  dmg -l "${SERVER_LIST}" storage format

  log.info "Waiting for DAOS storage format to finish"
  echo "Formatting"
  while true
  do
    if [[ $(dmg system query -v | grep -c -i joined) -eq ${DAOS_SERVER_INSTANCE_COUNT} ]]; then
      printf "\n"
      log.info "DAOS storage format finished"
      dmg system query -v
      break
    fi
    printf "%s" "."
    sleep 5
  done
}

show_storage_usage() {
  log.info "Display storage usage"
  log.debug "COMMAND: dmg storage query usage"
  dmg storage query usage
}

create_pool() {
  log.info "Create pool: label=${DAOS_POOL_LABEL} size=${DAOS_POOL_SIZE}"

  # TODO: Don't hardcode tier-ratio to 2 (-t 2)
  dmg pool create -z "${DAOS_POOL_SIZE}" -t 2 -u "${USER}" --label="${DAOS_POOL_LABEL}"

  echo "Set pool property: reclaim=disabled"
  dmg pool set-prop "${DAOS_POOL_LABEL}" --name=reclaim --value=disabled

  echo "Pool created successfully"
  dmg pool query "${DAOS_POOL_LABEL}"
}

create_container() {
  log.info "Create container: label=${DAOS_CONT_LABEL}"
  log.debug "COMMAND: daos container create --type=POSIX --properties=\"${DAOS_CONT_REPLICATION_FACTOR}\" --label=\"${DAOS_CONT_LABEL}\" \"${DAOS_POOL_LABEL}\""
  if [[ ${DAOS_VERSION} == "2.3.0" ]]; then
    daos container create --type=POSIX --properties="${DAOS_CONT_REPLICATION_FACTOR}" "${DAOS_POOL_LABEL}" "${DAOS_CONT_LABEL}"
  else
    daos container create --type=POSIX --properties="${DAOS_CONT_REPLICATION_FACTOR}" "${DAOS_POOL_LABEL}" --label="${DAOS_CONT_LABEL}"
  fi

  log.info "Show container properties"
  log.debug "COMMAND: daos cont get-prop \"${DAOS_POOL_LABEL}\" \"${DAOS_CONT_LABEL}\""
  daos cont get-prop "${DAOS_POOL_LABEL}" "${DAOS_CONT_LABEL}"
}

mount_dfuse() {
  if [[ -d "${IO500_DFUSE_DIR}" ]]; then
    log.error "DFuse dir ${IO500_DFUSE_DIR} already exists."
  else
    log.info "Use dfuse to mount ${DAOS_CONT_LABEL} on ${IO500_DFUSE_DIR}"

    clush --hostfile=hosts_servers --dsh \
      "mkdir -p ${IO500_DFUSE_DIR}"

    clush --hostfile=hosts_servers --dsh \
      "dfuse -S --pool=${DAOS_POOL_LABEL} --container=${DAOS_CONT_LABEL} --mountpoint=${IO500_DFUSE_DIR}"

    sleep 10

    echo "DFuse mount complete!"
  fi
}

io500_prepare() {
  log.info "Load Intel MPI"
  export I_MPI_OFI_LIBRARY_INTERNAL=0
  export I_MPI_OFI_PROVIDER="tcp;ofi_rxm"
  source /opt/intel/oneapi/setvars.sh

  export PATH=$PATH:${IO500_DIR}/bin
  export LD_LIBRARY_PATH=/usr/local/mpifileutils/install/lib64/:$LD_LIBRARY_PATH

  log.info "Prepare config file 'temp.ini' for IO500"

  export DAOS_POOL="${DAOS_POOL_LABEL}"
  export DAOS_CONT="${DAOS_CONT_LABEL}"
  export MFU_POSIX_TS=1
  export IO500_PPN=4
  export IO500_NP=$((IO500_PPN * ${DAOS_SERVER_INSTANCE_COUNT}))
  export I_MPI_PIN_PROCESSOR_LIST=0,1,22,23
  export MPI_RUN_OPTS=""


  # shellcheck disable=SC2153
  envsubst < "${IO500_INI}" > temp.ini
  sed -i "s|^datadir.*|datadir = ${IO500_DATAFILES_DFUSE_DIR}|g" temp.ini
  sed -i "s|^resultdir.*|resultdir = ${IO500_RESULTS_DFUSE_DIR}|g" temp.ini
  sed -i "s/^stonewall-time.*/stonewall-time = ${IO500_STONEWALL_TIME}/g" temp.ini
  sed -i "s/^transferSize.*/transferSize = 4m/g" temp.ini
  sed -i "s/^filePerProc.*/filePerProc = TRUE /g" temp.ini
  sed -i "s/^nproc.*/nproc = ${IO500_NP}/g" temp.ini
  sed -i "s/oclass=S1/oclass=${OCLASS_1}/g" temp.ini
  sed -i "s/oclass=SX/oclass=${OCLASS_X}/g" temp.ini

  # Prepare final results directory for the current run
  TIMESTAMP=$(date "+%Y-%m-%d_%H%M%S")
  IO500_RESULTS_DIR_TIMESTAMPED="${IO500_RESULTS_DIR}/${TIMESTAMP}"
  log.info "Creating directory for results ${IO500_RESULTS_DIR_TIMESTAMPED}"
  mkdir -p "${IO500_RESULTS_DIR_TIMESTAMPED}"

}

run_io500() {
  echo "IO500_NP: ${IO500_NP}"
  echo "IO500_PPN: ${IO500_PPN}"
  mpirun -np ${IO500_NP} -ppn ${IO500_PPN} \
   --hostfile "${SCRIPT_DIR}/hosts_servers" \
    ${MPI_RUN_OPTS} "${IO500_DIR}/io500" temp.ini
  log.info "IO500 run complete!"
}

show_pool_state() {
  log.info "Query pool state"
  dmg pool query "${DAOS_POOL_LABEL}"
}

process_results() {
  log.info "Copy results from ${IO500_RESULTS_DFUSE_DIR} to ${IO500_RESULTS_DIR_TIMESTAMPED}"

  cp config.sh "${IO500_RESULTS_DIR_TIMESTAMPED}/"
  cp hosts* "${IO500_RESULTS_DIR_TIMESTAMPED}/"

  echo "${TIMESTAMP}" > "${IO500_RESULTS_DIR_TIMESTAMPED}/io500_run_timestamp.txt"

  FIRST_SERVER=$(echo "${SERVER_LIST}" | cut -d, -f1)
  ssh "${FIRST_SERVER}" 'daos_server version' > \
    "${IO500_RESULTS_DIR_TIMESTAMPED}/daos_server_version.txt"

  RESULT_SERVER_FILES_DIR="${IO500_RESULTS_DIR_TIMESTAMPED}/server_files"
  # shellcheck disable=SC2013
  for server in $(cat hosts_servers);do
    SERVER_FILES_DIR="${RESULT_SERVER_FILES_DIR}/${server}"
    mkdir -p "${SERVER_FILES_DIR}/etc/daos"
    scp "${server}:/etc/daos/*.yml" "${SERVER_FILES_DIR}/etc/daos/"
    mkdir -p "${SERVER_FILES_DIR}/var/daos"
    scp "${server}:/var/daos/*.log*" "${SERVER_FILES_DIR}/var/daos/"
    ssh "${server}" 'daos_server version' > "${SERVER_FILES_DIR}/daos_server_version.txt"
    if [ "${USE_PROMETHEUS}" = true ];  then
      mkdir -p "${IO500_RESULTS_DIR_TIMESTAMPED}/prometheus/${server}"
      scp -r "${server}:~/data/*" "${IO500_RESULTS_DIR_TIMESTAMPED}/prometheus/${server}"
    fi
  done

  # Save a copy of the environment variables for the IO500 run
  printenv | sort > "${IO500_RESULTS_DIR_TIMESTAMPED}/env.sh"

  # Copy results from dfuse mount to another directory so we don't lose them
  # when the dfuse mount is removed
  rsync -avh "${IO500_RESULTS_DFUSE_DIR}/" "${IO500_RESULTS_DIR_TIMESTAMPED}/"
  cp temp.ini "${IO500_RESULTS_DIR_TIMESTAMPED}/"

  # Save output from "dmg pool query"
  # shellcheck disable=SC2024
  dmg pool query "${DAOS_POOL_LABEL}" > \
    "${IO500_RESULTS_DIR_TIMESTAMPED}/dmg_pool_query_${DAOS_POOL_LABEL}.txt"

  log.info "Results files located in ${IO500_RESULTS_DIR_TIMESTAMPED}"

  RESULTS_TAR_FILE="${TEST_CONFIG_ID}_${TIMESTAMP}.tar.gz"

  log.info "Creating '${IO500_RESULTS_DIR}/${RESULTS_TAR_FILE}' file with contents of ${IO500_RESULTS_DIR_TIMESTAMPED} directory"
  pushd "${IO500_RESULTS_DIR}"
  tar -czf "${IO500_RESULTS_DIR}/${RESULTS_TAR_FILE}" ./${TIMESTAMP}
  log.info "Results tar file: ${IO500_RESULTS_DIR}/${RESULTS_TAR_FILE}"
  popd
}

main() {
  log.section "Prepare for IO500 run"
  cleanup
  storage_scan
  format_storage
  show_storage_usage
  create_pool
  create_container
  mount_dfuse
  io500_prepare

  log.section "Run IO500"
  run_io500
  process_results
  unmount_defuse
}

main
