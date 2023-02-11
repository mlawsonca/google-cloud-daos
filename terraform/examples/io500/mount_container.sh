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

####### user vars ########
DFUSE_DIR="${DFUSE_DIR:-"${HOME}/daos_fuse"}"
DAOS_POOL_LABEL="${DAOS_POOL_LABEL:-pool}"
DAOS_CONT_LABEL="${DAOS_CONT_LABEL:-cont}"
##########################

export LD_PRELOAD=/usr/lib64/libioil.so

mount_dfuse() {
  if [[ -d "${DFUSE_DIR}" ]]; then
    log.error "DFuse dir ${DFUSE_DIR} already exists."
  else
    log.info "Use dfuse to mount ${DAOS_CONT_LABEL} on ${DFUSE_DIR}"

    mkdir -p ${DFUSE_DIR}

    dfuse -S --pool=${DAOS_POOL_LABEL} --container=${DAOS_CONT_LABEL} --mountpoint=${DFUSE_DIR}

    sleep 10

    echo "DFuse mount complete!"
  fi
}


main() {
  log.section "Mount DAOS container"
  mount_dfuse
}

main
