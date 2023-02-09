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
OCLASS_1="S1"
OCLASS_X="SX"
DAOS_CONT_REPLICATION_FACTOR="rf:0"
TEST_CONFIG_ID="${BASE_CONFIG_ID}-rf0-fio"

#OCLASS_1="EC_2P1G1"
#OCLASS_X="EC_2P1GX"
#DAOS_CONT_REPLICATION_FACTOR="rf:1,ec_cell_sz:131072"
#TEST_CONFIG_ID="${BASE_CONFIG_ID}-rf1-fio"
##########################

DFUSE_DIR="${DFUSE_DIR:-"${HOME}/daos_fuse"}"
DAOS_POOL_LABEL="${DAOS_POOL_LABEL:-pool}"
DAOS_CONT_LABEL="${DAOS_CONT_LABEL:-cont}"
export POOL="${DAOS_POOL_LABEL}"
export CONT="${DAOS_CONT_LABEL}"

unmount_defuse() {
  log.info "Attempting to unmount DFuse mountpoint ${DFUSE_DIR}"
  if findmnt --target "${DFUSE_DIR}" > /dev/null; then
    log.info "Unmount DFuse mountpoint ${DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "sudo fusermount3 -u ${DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "rm -r ${DFUSE_DIR}"

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
    daos container create --oclass="${OCLASS_1}" --dir_oclass="${OCLASS_X}" --type=POSIX --properties="${DAOS_CONT_REPLICATION_FACTOR}" "${DAOS_POOL_LABEL}" "${DAOS_CONT_LABEL}"
  else
    daos container create --oclass="${OCLASS_X}" --type=POSIX --properties="${DAOS_CONT_REPLICATION_FACTOR}" "${DAOS_POOL_LABEL}" --label="${DAOS_CONT_LABEL}"
  fi

  log.info "Show container properties"
  log.debug "COMMAND: daos cont get-prop \"${DAOS_POOL_LABEL}\" \"${DAOS_CONT_LABEL}\""
  daos cont get-prop "${DAOS_POOL_LABEL}" "${DAOS_CONT_LABEL}"
}

mount_dfuse() {
  if [[ -d "${DFUSE_DIR}" ]]; then
    log.error "DFuse dir ${DFUSE_DIR} already exists."
  else
    log.info "Use dfuse to mount ${DAOS_CONT_LABEL} on ${DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "mkdir -p ${DFUSE_DIR}"

    clush --hostfile=hosts_clients --dsh \
      "dfuse -S --pool=${DAOS_POOL_LABEL} --container=${DAOS_CONT_LABEL} --mountpoint=${DFUSE_DIR}"

    sleep 10

    echo "DFuse mount complete!"
  fi
}


main() {
  log.section "Set up DAOS cluster and container"
  cleanup
  storage_scan
  format_storage
  show_storage_usage
  create_pool
  create_container
  mount_dfuse
}

main
