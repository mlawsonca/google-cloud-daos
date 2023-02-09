#!/bin/bash

# runas root

yum -y install dnf git virtualenv

dnf -y install epel-release dnf-plugins-core
dnf config-manager --enable powertools
# dnf group -y install "Development Tools"
dnf -y install clustershell

git clone --recurse-submodules https://github.com/daos-stack/daos.git  # --branch v2.2.0

pushd daos

git checkout c63f9536

#git rev-parse HEAD
dnf config-manager --save --setopt=assumeyes=True
utils/scripts/install-el8.sh

virtualenv myproject
source myproject/bin/activate
pip install --upgrade pip
pip install defusedxml \
  distro \
  jira \
  junit_xml \
  meson \
  ninja \
  pyelftools \
  pyxattr \
  pyyaml \
  scons    \
  tabulate \
  wheel
# pip install -r requirements.txt

# --no-rpath
scons --jobs="$(nproc --all)" --build-deps=only PREFIX=/usr TARGET_TYPE=release BUILD_TYPE=release

ln -s /usr/prereq/release/spdk/lib/librte_eal.so.22.0 /usr/lib/librte_eal.so.22
ln -s /usr/prereq/release/spdk/lib/librte_kvargs.so.22.0 /usr/lib/librte_kvargs.so.22
ln -s /usr/prereq/release/spdk/lib/librte_telemetry.so.22.0 /usr/lib/librte_telemetry.so.22
ln -s /usr/prereq/release/spdk/lib/librte_ring.so.22.0 /usr/lib/librte_ring.so.22
ln -s /usr/prereq/release/spdk/lib/librte_pci.so.22.0 /usr/lib/librte_pci.so.22

# --no-rpath
scons --jobs="$(nproc --all)" install PREFIX=/usr TARGET_TYPE=release BUILD_TYPE=release CONF_DIR=/etc/daos

cp utils/systemd/daos_agent.service /etc/systemd/system
cp utils/systemd/daos_server.service /etc/systemd/system

popd

useradd --no-log-init --user-group --create-home --shell /bin/bash daos_server
echo "daos_server:daos_server" | chpasswd
useradd --no-log-init --user-group --create-home --shell /bin/bash daos_agent
echo "daos_agent:daos_agent" | chpasswd
echo "daos_server ALL=(root) NOPASSWD: ALL" >> /etc/sudoers.d/daos_sudo_setup

mkdir -p /var/run/daos_server
mkdir -p /var/run/daos_agent
chown -R daos_server.daos_server /var/run/daos_server
chown daos_agent.daos_agent /var/run/daos_agent

yum -y install kmod pciutils
/usr/prereq/release/spdk/share/spdk/scripts/setup.sh
