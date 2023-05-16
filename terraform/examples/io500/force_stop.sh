source ./config/config.sh
DAOS_PROJECT_NAME=$(gcloud config get project)
GCP_ZONE="${GCP_ZONE:-$(gcloud config list --format='value(compute.zone)')}"

secrets=$(gcloud secrets list --project="${DAOS_PROJECT_NAME}"  --format="value(name)" --filter="name~${DAOS_SERVER_BASE_NAME}" | sed -z 's/\n/ /g')

clients=$(gcloud compute instances list --project="${DAOS_PROJECT_NAME}"  --format="value(name)" --filter="name~${DAOS_CLIENT_BASE_NAME}" | sed -z 's/\n/ /g')

servers=$(gcloud compute instances list --project="${DAOS_PROJECT_NAME}"  --format="value(name)" --filter="name~${DAOS_SERVER_BASE_NAME}" | sed -z 's/\n/ /g')



#echo "DAOS_SERVER_BASE_NAME: $DAOS_SERVER_BASE_NAME"
echo "secrets: ${secrets}"
echo "clients: ${clients}"
echo "servers: ${servers}"


if [[ -n ${secrets} ]]; then
    gcloud secrets delete ${secrets} --quiet --project="${DAOS_PROJECT_NAME}"
fi

if [[ -n ${clients} ]]; then
    gcloud compute instances delete $clients --quiet --zone="${GCP_ZONE}" --project="${DAOS_PROJECT_NAME}"
fi

if [[ -n ${servers} ]]; then
    gcloud compute instances delete $servers --quiet --zone="${GCP_ZONE}" --project="${DAOS_PROJECT_NAME}"
fi

### typically these will already be cleaned up once the nodes that use the boot disks are deleted

compute_disks_clients=$(gcloud compute disks list --project="${DAOS_PROJECT_NAME}"  --format="value(name)" --filter="name~${DAOS_CLIENT_BASE_NAME}" | sed -z 's/\n/ /g')

compute_disks_servers=$(gcloud compute disks list --project="${DAOS_PROJECT_NAME}"  --format="value(name)" --filter="name~${DAOS_SERVER_BASE_NAME}" | sed -z 's/\n/ /g')


echo "compute_disks_clients: ${compute_disks_clients}"
echo "compute_disks_servers: ${compute_disks_servers}"

if [[ -n ${compute_disks_clients} ]]; then
  gcloud compute disks delete $compute_disks_clients --quiet --zone="${GCP_ZONE}" --project="${DAOS_PROJECT_NAME}"
fi

if [[ -n ${compute_disks_servers} ]]; then
  gcloud compute disks delete $compute_disks_servers --quiet --zone="${GCP_ZONE}" --project="${DAOS_PROJECT_NAME}"
fi

