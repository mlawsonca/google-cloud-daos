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

# Source config file to load variables
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi


####### user vars ########
DAOS_POOL_LABEL="${DAOS_POOL_LABEL:-pool}"
DAOS_CONT_LABEL="${DAOS_CONT_LABEL:-cont}"
DFUSE_DIR="${DFUSE_DIR:-"${HOME}/daos_fuse"}"
##########################

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

destroy_container() {
  log.info "Attempting to destroy DAOS container \"${DAOS_CONT_LABEL}\""
  daos container destroy ${DAOS_POOL_LABEL} ${DAOS_CONT_LABEL}
}

destroy_pool() {
  log.info "Attempting to destroy DAOS pool \"${DAOS_POOL_LABEL}\""
  dmg pool destroy ${DAOS_POOL_LABEL}
}

unmount_defuse
if [[ ${DAOS_VERSION} == "2.3.0" ]]; then
  destroy_container
fi
destroy_pool
