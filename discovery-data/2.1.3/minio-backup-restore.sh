#!/bin/bash
set -euo pipefail

ROOT_DIR_MINIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

source "${ROOT_DIR_MINIO}/lib/restore-updates.bash"
source "${ROOT_DIR_MINIO}/lib/function.bash"

# Setup the minio directories needed to create the backup file
KUBECTL_ARGS="" 
MINIO_BACKUP="/tmp/minio_backup.tar.gz"
MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-minio_backup}"
MINIO_FORWARD_PORT=${MINIO_FORWARD_PORT:-39001}
TMP_WORK_DIR="tmp/minio_workspace"
MINIO_ELASTIC_BACKUP=${MINIO_ELASTIC_BACKUP:-false}
ELASTIC_BACKUP_BUCKET="elastic-backup"
SED_REG_OPT="`get_sed_reg_opt`"
SCRIPT_DIR=${ROOT_DIR_MINIO}

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

COMMAND=$1
shift
RELEASE_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done

echo "Release name: $RELEASE_NAME"

MINIO_SVC=`kubectl ${KUBECTL_ARGS} get svc -l release=${RELEASE_NAME},helm.sh/chart=minio -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep headless`
MINIO_PORT=`kubectl ${KUBECTL_ARGS} get svc ${MINIO_SVC} -o jsonpath="{.spec.ports[0].port}"`
MINIO_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${RELEASE_NAME} -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep minio`
MINIO_ACCESS_KEY=`kubectl get ${KUBECTL_ARGS} secret ${MINIO_SECRET} --template '{{.data.accesskey}}' | base64 --decode`
MINIO_SECRET_KEY=`kubectl get ${KUBECTL_ARGS} secret ${MINIO_SECRET} --template '{{.data.secretkey}}' | base64 --decode`
MINIO_ENDPOINT_URL=${MINIO_ENDPOINT_URL:-https://localhost:$MINIO_FORWARD_PORT}

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}/.mc
mkdir -p ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}
if [ -n "${MC_COMMAND+UNDEF}" ] ; then
  MC=${MC_COMMAND}
else
  get_mc ${TMP_WORK_DIR}
  MC=${PWD}/${TMP_WORK_DIR}/mc
fi
export MINIO_CONFIG_DIR=${TMP_WORK_DIR}/.mc

# backup
if [ "${COMMAND}" = "backup" ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"minio_`date "+%Y%m%d_%H%M%S"`.tar.gz"}
  echo "Start backup minio..."
  start_minio_port_forward
  ${MC} --quiet --insecure config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  EXCLUDE_OBJECTS=`cat "${ROOT_DIR_MINIO}/src/minio_exclude_paths"`
  for bucket in `${MC} --insecure ls wdminio | sed ${SED_REG_OPT} "s|.*[0-9]+B\ (.*)/.*|\1|g" | grep -v ${ELASTIC_BACKUP_BUCKET}`
  do
    EXTRA_MC_MIRROR_COMMAND=""
    ORG_IFS=${IFS}
    IFS=$'\n'
    for line in ${EXCLUDE_OBJECTS}
    do
      if [[ ${line} == ${bucket}* ]] ; then
        EXTRA_MC_MIRROR_COMMAND="--exclude ${line#$bucket } ${EXTRA_MC_MIRROR_COMMAND}"
      fi
    done
    IFS=${ORG_IFS}
    cd ${TMP_WORK_DIR}
    ${MC} --quiet --insecure mirror ${EXTRA_MC_MIRROR_COMMAND} wdminio/${bucket} ${MINIO_BACKUP_DIR}/${bucket} > /dev/null
    cd - > /dev/null
  done
  stop_minio_port_forward
  tar zcf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR} .
  echo "Done: ${BACKUP_FILE}"
fi

# restore
if [ "${COMMAND}" = "restore" ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    echo "no such file: ${BACKUP_FILE}" >&2
    echo "Nothing to Restore" >&2
    echo
    exit 1
  fi
  echo "Start restore minio: ${BACKUP_FILE}"
  tar xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}
  start_minio_port_forward
  ${MC} --quiet --insecure config host add wdminio ${MINIO_ENDPOINT_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} > /dev/null
  for bucket in `ls ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}`
  do
    if ${MC} --insecure ls wdminio | grep ${bucket} > /dev/null ; then
      ${MC} --quiet --insecure rm --recursive --force --dangerous "wdminio/${bucket}/" > /dev/null
      ${MC} --quiet --insecure mirror ${TMP_WORK_DIR}/${MINIO_BACKUP_DIR}/${bucket} wdminio/${bucket} > /dev/null
    fi
  done
  stop_minio_port_forward
  echo "Done"
  echo "Applying updates"
  . ./lib/restore-updates.bash
  minio_updates
  echo "Completed Updates"
  echo
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi