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
# Cleans DAOS storage and runs an FIO benchmark
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
CONFIG_FILE="${SCRIPT_DIR}/config.sh"



# Comma separated list of servers needed for the dmg command
# TODO: Figure out a better way for this script to get the list of servers
#       Requiring the hosts_servers file is not ideal
SERVER_LIST=$(awk -vORS=, '{ print $1 }' "${SCRIPT_DIR}/hosts_servers" | sed 's/,$/\n/')

# Source config file to load variables
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

####### user vars ########
FILE_OCLASS="S1"
DIR_OCLASS="SX"
DAOS_CONT_REPLICATION_FACTOR="rf:0"
TEST_CONFIG_ID="${BASE_CONFIG_ID}-rf0-fio"

#FILE_OCLASS="EC_2P1G1"
#DIR_OCLASS="RP_2G1"
#DAOS_CONT_REPLICATION_FACTOR="rf:1,ec_cell_sz:131072"
#TEST_CONFIG_ID="${BASE_CONFIG_ID}-rf1-fio"

DAOS_CHUNK_SIZE="1048576"

FIO_DFUSE_DIR="${FIO_DFUSE_DIR:-"${HOME}/daos_fuse/${IO500_VERSION_TAG}"}"
FIO_RESULTS_DIR="${FIO_RESULTS_DIR:-"${HOME}/${IO500_VERSION_TAG}/results"}"

DAOS_POOL_LABEL="${DAOS_POOL_LABEL:-fio_pool}"
DAOS_CONT_LABEL="${DAOS_CONT_LABEL:-fio_cont}"
##########################

RESULT_FILE_PREFIX=""
if [[ "${DAOS_CONT_REPLICATION_FACTOR}" == "rf:0" ]]; then
  RESULT_FILE_PREFIX="client_rf0"
else
  RESULT_FILE_PREFIX="client_rf1"
fi

FIO_FILE="${FIO_DFUSE_DIR}/fio-file.dat"

export POOL="${DAOS_POOL_LABEL}"
export CONT="${DAOS_CONT_LABEL}"

unmount_defuse() {
  log.info "Attempting to unmount DFuse mountpoint ${FIO_DFUSE_DIR}"
  if findmnt --target "${FIO_DFUSE_DIR}" > /dev/null; then
    log.info "Unmount DFuse mountpoint ${FIO_DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "sudo fusermount3 -u ${FIO_DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "rm -r ${FIO_DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "mount | sort | grep dfuse || true"

    log.info "fusermount3 complete!"
  fi
}

cleanup(){
  log.info "Clean up DAOS storage"
  unmount_defuse
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

  if [[ ${DAOS_VERSION} == "2.3.0" ]]; then
    # TODO: Don't hardcode tier-ratio to 2 (-t 2)
    dmg pool create -z "${DAOS_POOL_SIZE}" -t 2 -u "${USER}" "${DAOS_POOL_LABEL}"

    echo "Set pool property: reclaim=disabled"
    dmg pool set-prop "${DAOS_POOL_LABEL}" "reclaim:disabled"
  else
    # TODO: Don't hardcode tier-ratio to 2 (-t 2)
    dmg pool create -z "${DAOS_POOL_SIZE}" -t 2 -u "${USER}" --label="${DAOS_POOL_LABEL}"

    echo "Set pool property: reclaim=disabled"
    dmg pool set-prop "${DAOS_POOL_LABEL}" --name=reclaim --value=disabled
  fi

  echo "Pool created successfully"
  dmg pool query "${DAOS_POOL_LABEL}"
}

create_container() {
  log.info "Create container: label=${DAOS_CONT_LABEL}"
  log.debug "COMMAND: daos container create --type=POSIX --properties=\"${DAOS_CONT_REPLICATION_FACTOR}\" --label=\"${DAOS_CONT_LABEL}\" \"${DAOS_POOL_LABEL}\""
  if [[ ${DAOS_VERSION} == "2.3.0" ]]; then
    daos container create --chunk-size="${DAOS_CHUNK_SIZE}" --file-oclass="${FILE_OCLASS}" --dir-oclass="${DIR_OCLASS}" --type=POSIX --properties="${DAOS_CONT_REPLICATION_FACTOR}" "${DAOS_POOL_LABEL}" "${DAOS_CONT_LABEL}"
  else
    daos container create --chunk-size="${DAOS_CHUNK_SIZE}" --oclass="${FILE_OCLASS}" --type=POSIX --properties="${DAOS_CONT_REPLICATION_FACTOR}" "${DAOS_POOL_LABEL}" --label="${DAOS_CONT_LABEL}"
  fi
  log.info "Show container properties"
  log.debug "COMMAND: daos cont get-prop \"${DAOS_POOL_LABEL}\" \"${DAOS_CONT_LABEL}\""
  daos cont get-prop "${DAOS_POOL_LABEL}" "${DAOS_CONT_LABEL}"
}

mount_dfuse() {
  if [[ -d "${FIO_DFUSE_DIR}" ]]; then
    log.error "DFuse dir ${FIO_DFUSE_DIR} already exists."
  else
    log.info "Use dfuse to mount ${DAOS_CONT_LABEL} on ${FIO_DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "mkdir -p ${FIO_DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "dfuse -S --pool=${DAOS_POOL_LABEL} --container=${DAOS_CONT_LABEL} --mountpoint=${FIO_DFUSE_DIR}"

    sleep 10

    echo "DFuse mount complete!"
  fi
}

fio_prepare() {
  # Prepare final results directory for the current run
  TIMESTAMP=$(date "+%Y-%m-%d_%H%M%S")
  FIO_RESULTS_DIR_TIMESTAMPED="${FIO_RESULTS_DIR}/${TIMESTAMP}"
  log.info "Creating directory for results ${FIO_RESULTS_DIR_TIMESTAMPED}"
  mkdir -p "${FIO_RESULTS_DIR_TIMESTAMPED}"
}

install_fio() {
  if [[ ! -d $HOME/fio ]]; then
    pushd $HOME
    git clone http://git.kernel.dk/fio.git
    cd fio
    ./configure
    sudo make install
    popd
  fi
}


run_fio() {
  fio \
    --ioengine=dfs \
    --pool="${DAOS_POOL_LABEL}" --cont="${DAOS_CONT_LABEL}" \
    --time_based --name=benchmark --size=1T --runtime=60 \
    --randrepeat=0 --iodepth=1 --direct=1 \
    --invalidate=1 --verify=0 --verify_fatal=0 --numjobs=1 \
    --rw=readwrite --blocksize=4k --group_reporting --norandommap \
    --output-format=json --output="${FIO_RESULTS_DIR_TIMESTAMPED}/${RESULT_FILE_PREFIX}_fio.json"
}

show_pool_state() {
  log.info "Query pool state"
  dmg pool query "${DAOS_POOL_LABEL}"
}

process_results() {

  cp config.sh "${FIO_RESULTS_DIR_TIMESTAMPED}/"
  cp hosts* "${FIO_RESULTS_DIR_TIMESTAMPED}/"

  echo "${TIMESTAMP}" > "${FIO_RESULTS_DIR_TIMESTAMPED}/fio_run_timestamp.txt"

  FIRST_SERVER=$(echo "${SERVER_LIST}" | cut -d, -f1)
  ssh "${FIRST_SERVER}" 'daos_server version' > \
    "${FIO_RESULTS_DIR_TIMESTAMPED}/daos_server_version.txt"

  RESULT_SERVER_FILES_DIR="${FIO_RESULTS_DIR_TIMESTAMPED}/server_files"
  # shellcheck disable=SC2013
  for server in $(cat hosts_servers);do
    SERVER_FILES_DIR="${RESULT_SERVER_FILES_DIR}/${server}"
    mkdir -p "${SERVER_FILES_DIR}/etc/daos"
    scp "${server}:/etc/daos/*.yml" "${SERVER_FILES_DIR}/etc/daos/"
    mkdir -p "${SERVER_FILES_DIR}/var/daos"
    scp "${server}:/var/daos/*.log*" "${SERVER_FILES_DIR}/var/daos/"
    ssh "${server}" 'daos_server version' > "${SERVER_FILES_DIR}/daos_server_version.txt"
  done

  # Save a copy of the environment variables for the FIO run
  printenv | sort > "${FIO_RESULTS_DIR_TIMESTAMPED}/env.sh"

  # Save output from "dmg pool query"
  # shellcheck disable=SC2024
  dmg pool query "${DAOS_POOL_LABEL}" > \
    "${FIO_RESULTS_DIR_TIMESTAMPED}/dmg_pool_query_${DAOS_POOL_LABEL}.txt"

  log.info "Results files located in ${FIO_RESULTS_DIR_TIMESTAMPED}"

  RESULTS_TAR_FILE="${TEST_CONFIG_ID}_${TIMESTAMP}.tar.gz"

  log.info "Creating '${FIO_RESULTS_DIR}/${RESULTS_TAR_FILE}' file with contents of ${FIO_RESULTS_DIR_TIMESTAMPED} directory"
  pushd "${FIO_RESULTS_DIR}"
  tar -czf "${FIO_RESULTS_DIR}/${RESULTS_TAR_FILE}" ./${TIMESTAMP}
  log.info "Results tar file: ${FIO_RESULTS_DIR}/${RESULTS_TAR_FILE}"
  popd
}

main() {
  log.section "Prepare for FIO run"
  cleanup
  storage_scan
  format_storage
  show_storage_usage
  create_pool
  create_container
  mount_dfuse
  fio_prepare
  install_fio

  log.section "Run FIO"
  run_fio
  process_results
  unmount_defuse
}

main
