sudo yum install -y nano
while IFS= read -r dest; do
  scp install_* "$dest:"
done <hosts_servers

clush --hostfile=hosts_servers --dsh "sudo ./install_devtools.sh && sudo ./install_intel-oneapi.sh && sudo ./install_io500-sc22.sh"
