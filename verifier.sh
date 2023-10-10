#!/bin/bash

# Este script busca chequear las modificaciones de objetos en OpenStreetMap, y
# reportar cada vez que se detectan cambios.
# El script se apoya en Overpass para descargar los objetos, y los guarda en
# un repositorio Git. Cada vez que alguno cambia, se reportan las modificaciones
# a un conjunto de correos electrónicos.
#
# Este script es la integración del validador de ciclovías y de vías en
# construcción. Aquí se busca que sea más dinámico en todo aspecto.
#
# To change the email addresses of the recipients, the EMAILS environment
# variable can be changed like:
#   export EMAILS="maptime.bogota@gmail.com,contact@osm.org"
#
# The file should start with diff. It is separated by underscore. The middle
# word specifies if the analisys is for: node, way, relation; only one
# type of element is possible. The final word specifies if the elements are
# retrieved with a query or a list of ids. When it is a query, the file
# should contain a valid Overpass query retrieving the ids of the elements to
# analyze; when it is a list of ids, each id of the type of element should be
# in a different line. The first line of the file contains the title of the
# analisys.
#
# diff_way_query : Checks the differences for the ways returned by this query.
# diff_relation_ids : Checks the differences for the ids of the relations listed
# in this file.
#
# To check the last execution, you can just run:
#   cd $(find /tmp/ -name "verifier_*" -type d -printf "%T@ %p\n" 2> /dev/null | sort -n | cut -d' ' -f 2- | tail -n 1) ; tail -f verifier.log ; cd -
#
# The following environment variables helps to configure the script:
# * CLEAN_FILES : Cleans all files at the end.
# * EMAILS : List of emails to send the report, separated by comma.
# * LOG_LEVEL : Log level in capitals.
#
# export EMAILS="angoca@yahoo.com" ; export LOG_LEVEL=WARN; cd ~/OSM-elements-change-tracker ; ./verifier.sh examples/mosqueraCentro/diff_relation_query_todo
#
# For contributing, please execute these commands at the end:
# * shellcheck -x -o all verifier.sh
# * shfmt -w -i 1 -sr -bn verifier.sh
#
# Autor: Andres Gomez Casanova - AngocA
# Version: 2023-06-26
declare -r VERSION="2023-06-26"

#set -xv
# Fails when a variable is not initialized.
set -u
# Fails with a non-zero return code.
set -e
# Fails if the commands of a pipe return non-zero.
set -o pipefail
# Fails if an internal function fails.
set -E

# Error codes.
# 1: Help message.
declare -r ERROR_HELP_MESSAGE=1
# 241: Library or utility missing.
declare -r ERROR_MISSING_LIBRARY=241
# 242: Invalid argument for script invocation.
declare -r ERROR_INVALID_ARGUMENT=242
# 243: Logger utility is not available.
declare -r ERROR_LOGGER_UTILITY=243
# 244: Id download failed.
declare -r ERROR_DOWNLOADING_IDS=244

# Logger levels: TRACE, DEBUG, INFO, WARN, ERROR, FATAL.
declare LOG_LEVEL="${LOG_LEVEL:-ERROR}"

# Clean files.
declare CLEAN_FILES="${CLEAN_FILES:-true}"

# Base directory, where the script resides.
# Taken from https://stackoverflow.com/questions/59895/how-can-i-get-the-source-directory-of-a-bash-script-from-within-the-script-itsel
# shellcheck disable=SC2155
declare -r SCRIPT_BASE_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" \
 &> /dev/null && pwd)"

# Logger framework.
# Taken from https://github.com/DushyanthJyothi/bash-logger.
declare -r LOGGER_UTILITY="${SCRIPT_BASE_DIRECTORY}/bash_logger.sh"

# Mask for the files and directories.
umask 0000

# Name of this script.
declare BASENAME
BASENAME=$(basename -s .sh "${0}")
readonly BASENAME
# Temporal directory for all files.
declare TMP_DIR
TMP_DIR=$(mktemp -d "/tmp/${BASENAME}_XXXXXX")
readonly TMP_DIR
# Log file for output.
declare LOG_FILE
LOG_FILE="${TMP_DIR}/${BASENAME}.log"
readonly LOG_FILE

# Lock file for single git execution.
declare LOCK
LOCK="/tmp/${BASENAME}.lock"
readonly LOCK

# Type of process to run in the script.
declare -r PROCESS_TYPE=${1:-}

# Query file.
declare -r QUERY_FILE=${TMP_DIR}/query.txt
# IDs file.
declare -r IDS_FILE=${TMP_DIR}/ids.txt
# Git history directory.
declare -r HISTORIC_FILES_DIR="${SCRIPT_BASE_DIRECTORY}/history"
# Wait time between retrievals.
declare -ir WAIT_TIME=2
# Report file.
declare -r REPORT=${TMP_DIR}/report.txt
# Report content.
declare -r REPORT_CONTENT=${TMP_DIR}/reportContent.txt
# Differences file.
declare -r DIFF_FILE=${TMP_DIR}/reportDiff.txt
# Details differences.
declare -r DETAILS_DIFF=${TMP_DIR}/detailsDiff.txt
# Mails to send the report.
declare -r EMAILS="${EMAILS:-angoca@yahoo.com}"

# File that contains the ids or query to get the ids.
declare -r PROCESS_FILE=${PROCESS_TYPE}
# Name of the file only.
declare BASE_PROCESS_FILE_NAME
# Type of differences to detect.
declare TITLE
# Element type to analyze.
declare ELEMENT_TYPE
# Method to get the IDs.
declare METHOD_TO_GET_IDS
# Detail of the difference.
declare DIFFERENCE_DETAIL

###########
# FUNCTIONS

### Logger

# Loads the logger (log4j like) tool.
# It has the following functions.
# __log default.
# __logt for trace.
# __logd for debug.
# __logi for info.
# __logw for warn.
# __loge for error. Writes in standard error.
# __logf for fatal.
# Declare mock functions, in order to have them in case the logger utility
# cannot be found.
function __log() { :; }
function __logt() { :; }
function __logd() { :; }
function __logi() { :; }
function __logw() { :; }
function __loge() { :; }
function __logf() { :; }
function __log_start() { :; }
function __log_finish() { :; }

# Starts the logger utility.
function __start_logger() {
 if [[ -f "${LOGGER_UTILITY}" ]]; then
  # Starts the logger mechanism.
  set +e
  # shellcheck source=./bash_logger.sh
  source "${LOGGER_UTILITY}"
  local -i RET=${?}
  set -e
  if [[ "${RET}" -ne 0 ]]; then
   printf "\nERROR: El archivo de framework de logger es inválido.\n"
   exit "${ERROR_LOGGER_UTILITY}"
  fi
  # Logger levels: TRACE, DEBUG, INFO, WARN, ERROR.
  __set_log_level "${LOG_LEVEL}"
  __logd "Logger adicionado."
 else
  printf "\nLogger no fue encontrado.\n"
 fi
}

# Function that activates the error trap.
function __trapOn() {
 __log_start
 trap '{ printf "%s ERROR: El script no terminó correctamente. Número de línea: %d.\n" "$(date +%Y%m%d_%H:%M:%S)" "${LINENO}"; exit ;}' \
  ERR
 trap '{ printf "%s WARN: El script fue terminado.\n" "$(date +%Y%m%d_%H:%M:%S)"; exit ;}' \
  SIGINT SIGTERM
 __log_finish
}

# Shows the help information.
function __show_help {
 echo "${BASENAME} version ${VERSION}"
 echo "Este script revisa los cambios de elementos en OpenStreetMap. Primero"
 echo "identifica qué se debe revisar, y después descarga cada uno de los"
 echo "elementos. Posteriormente los compara con un histórico, y si identifica"
 echo "cambios, los reporta por medio de un mensaje de correo electrónico."
 echo
 echo "La forma para invocar este script es:"
 echo " * fileName : indica el nombre del archivo que contiene la consulta o"
 echo "   lista de ids a consultar. El nombre del archivo tiene que seguir una"
 echo "   nomenclatura."
 echo " * --help : muestra esta ayuda."
 echo
 echo "La nomenclatura del archivo tiene tres partes separadas por barra baja."
 echo " * La palabra 'diff'."
 echo " * El tipo de elemento de OSM a revisar. Los posibles valores son:"
 echo "   * node."
 echo "   * way."
 echo "   * relation."
 echo " * Forma de identificar los ids de los elementos. Hay dos tipos:"
 echo "   * ids : contiene los ids de los elementos de OSM a analizar. No"
 echo "     requiere hacer consulta."
 echo "   * query : Consulta de overpass que retorna la lista de ids de objetos"
 echo "     a analizar."
 echo "La primera línea del archivo contiene el título de la operación de"
 echo "análisis, la cual será usada para enviar mensaje de correo electrónico."
 echo
 echo "Para cambiar los destinatarios del reporte enviado por correo"
 echo "electrónico, se modifica la variable de entorno EMAILS:"
 echo "  export EMAILS=\"maptime.bogota@gmail.com,contact@osm.org\""
 echo
 echo "Escrito por: Andres Gomez (AngocA)"
 echo "MaptimeBogota."
 exit "${ERROR_HELP_MESSAGE}"
}

# Checks prerequisites to run the script.
function __checkPrereqs {
 __log_start
 set +e
 # Checks prereqs.
 ## Wget.
 if ! wget --version > /dev/null 2>&1; then
  __loge "Falta instalar wget."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## Mutt.
 if ! mutt -v > /dev/null 2>&1; then
  __loge "Falta instalar mutt."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## git.
 if ! git --version > /dev/null 2>&1; then
  echo "Falta instalar git."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## flock.
 if ! flock --version > /dev/null 2>&1; then
  __loge "Falta instalar flock."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## Bash 4 or greater.
 if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  __loge "Requiere Bash 4+."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## Checks if the process file exists.
 if [[ "${PROCESS_FILE}" != "" ]] && [[ ! -r "${PROCESS_FILE}" ]]; then
  __loge "El archivo para obtener los ids no se encuentra: ${PROCESS_FILE}."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 ## Checks process file structure.
 BASE_PROCESS_FILE_NAME=$(basename -s .sh "${PROCESS_FILE}")

 if [[ "${BASE_PROCESS_FILE_NAME:0:4}" != "diff" ]]; then
  __loge "El nombre del archivo de proceso no es correcto: ${BASE_PROCESS_FILE_NAME}."
  __logi "Debe comenzar con 'diff'."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 ELEMENT_TYPE=$(echo "${BASE_PROCESS_FILE_NAME}" | awk -F_ '{print $2}')
 METHOD_TO_GET_IDS=$(echo "${BASE_PROCESS_FILE_NAME}" | awk -F_ '{print $3}')
 if [[ "${ELEMENT_TYPE}" != "node" ]] && [[ "${ELEMENT_TYPE}" != "way" ]] \
  && [[ "${ELEMENT_TYPE}" != "relation" ]]; then
  __loge "El nombre del archivo de proceso no es correcto: ${BASE_PROCESS_FILE_NAME}."
  __logi "Debe tener como token medio: 'node', 'way' o 'relation'."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 ## Checks process file structure.
 if [[ "${METHOD_TO_GET_IDS}" != "query" ]] \
  && [[ "${METHOD_TO_GET_IDS}" != "ids" ]]; then
  __loge "El nombre del archivo de proceso no es correcto: ${BASE_PROCESS_FILE_NAME}."
  __logi "Debe terminar indicando el tipo para obtener ids: 'query' o 'ids'."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 __log_finish
 set -e
}

# Puts a lock for the git commands.
function __put_lock {
 __log_start
 __logw "Validando una sola ejecución de git."
 flock -n 7
 __log_finish
}

# Releases the lock after the git commands.
function __release_lock {
 __log_start
 __logw "Liberando candado para una sola ejecución de git."
 flock -u 7
 __log_finish
}

# Prepares and checks the environment to keep the history of the elements.
function __prepareEnv {
 __log_start
 mkdir -p "${HISTORIC_FILES_DIR}" > /dev/null
 cd "${HISTORIC_FILES_DIR}/"
 git init >> "${LOG_FILE}" 2>&1
 git config user.email "maptime.bogota@gmail.com"
 git config user.name "Bot de chequeo cambios de elementos en OSM"
 cd - > /dev/null
 rm -f "${DIFF_FILE}"
 touch "${DIFF_FILE}"
 TITLE=$(head -1 "${PROCESS_FILE}")

 if [[ "${TITLE}" == "" ]]; then
  __logw "El archivo no tiene un título."
 fi

 cat << EOF > "${REPORT}"
Reporte de modificaciones de ${ELEMENT_TYPE} en ${TITLE} en OpenStreetMap.

Hora de inicio: $(date || true).

EOF
 __log_finish
}

# Gets a details of the differences for an element.
function __getDifferenceType {
 __log_start
 set +e
 diff "${HISTORIC_FILES_DIR}/${FILE}" "${TMP_DIR}/${FILE}" > "${DETAILS_DIFF}"
 set -e
 DIFFERENCE_DETAIL=""
 # Nodes
 if [[ "${FILE:0:4}" == "node" ]]; then
  __logd "Diferencias para nodos."
  set +e
  LAT_DIFF_QTY=$(grep -c '^[<>]   "lat": ' "${DETAILS_DIFF}")
  LON_DIFF_QTY=$(grep -c '^[<>]   "lon": ' "${DETAILS_DIFF}")
  TAGS_DIFF_QTY=$(grep -c '^[<>]     ".*": ' "${DETAILS_DIFF}")
  set -e
  DIFFERENCE_DETAIL="Cambios en "
  if [[ "${LAT_DIFF_QTY}" -ne 0 ]] && [[ "${LON_DIFF_QTY}" -ne 0 ]]; then
   __logd "Diferencia de coordenadas."
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} coordenadas "
  elif [[ "${LAT_DIFF_QTY}" -ne 0 ]] && [[ "${LON_DIFF_QTY}" -eq 0 ]]; then
   __logd "Diferencia de latitud."
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} latitud "
  elif [[ "${LAT_DIFF_QTY}" -eq 0 ]] && [[ "${LON_DIFF_QTY}" -ne 0 ]]; then
   __logd "Diferencia de longitud."
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} longitud "
  fi
  if [[ "${TAGS_DIFF_QTY}" -ne 0 ]]; then
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} etiquetas."
  fi
 fi
 if [[ "${FILE:0:3}" == "way" ]]; then
  __logd "Diferencias para vías."
  set +e
  NODES_DIFF_QTY=$(grep -c '^[<>]     \d,' "${DETAILS_DIFF}")
  TAGS_DIFF_QTY=$(grep -c '^[<>]     ".*": ' "${DETAILS_DIFF}")
  set -e
  DIFFERENCE_DETAIL="Cambios en "
  if [[ "${NODES_DIFF_QTY}" -ne 0 ]]; then
   __logd "Diferencia de cantidad de nodos."
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} cantidad de nodos "
  fi
  if [[ "${TAGS_DIFF_QTY}" -ne 0 ]]; then
   __logd "Diferencia de etiquetas."
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} etiquetas."
  fi
 fi
 if [[ "${FILE:0:8}" == "relation" ]]; then
  __logd "Diferencias para relaciones."
  set +e
  NODES_OR_WAYS_DIFF_QTY=$(grep '^[<>]     \d,' "${DETAILS_DIFF}")
  TAGS_DIFF_QTY=$(grep -c '^[<>]     ".*": ' "${DETAILS_DIFF}")
  ROLES_DIFF_QTY=$(grep -c '^[<>]       "role": ' "${DETAILS_DIFF}")
  set -e
  DIFFERENCE_DETAIL="Cambios en "
  if [[ "${NODES_OR_WAYS_DIFF_QTY}" -ne 0 ]]; then
   __logd "Diferencia de cantidad de nodos o vías."
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} cantidad de nodos o vías "
  fi
  if [[ "${TAGS_DIFF_QTY}" -ne 0 ]]; then
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} etiquetas "
   __logd "Diferencia de etiquetas."
  fi
  if [[ "${ROLES_DIFF_QTY}" -ne 0 ]]; then
   __logd "Diferencia de roles."
   DIFFERENCE_DETAIL="${DIFFERENCE_DETAIL} roles."
  fi
 fi
 __log_finish
}

# Adds a file to the history.
function __addFile {
 __log_start
 local FILE="${1}"

 if [[ -r "${HISTORIC_FILES_DIR}/${FILE}" ]]; then
  __logd "Se puede leer el archivo, entonces se procesa."
  # If there is an historic file, it compares it with the downloaded file.
  echo "${TMP_DIR}/${FILE}" >> "${DIFF_FILE}"
  set +e
  diff "${HISTORIC_FILES_DIR}/${FILE}" "${TMP_DIR}/${FILE}" >> "${DIFF_FILE}"
  RET=${?}
  set -e
  if [[ ${RET} -ne 0 ]]; then
   __logd "Hay diferencias en la nueva versión."

   # Getting details about the difference.
   if [[ -n "${ID:-}" ]]; then
    __getDifferenceType
    echo "* Revisar https://osm.org/${ELEMENT_TYPE}/${ID}" >> "${REPORT_CONTENT}"
    echo "${DIFFERENCE_DETAIL}" >> "${REPORT_CONTENT}"
   else
    set +e
    sdiff "${HISTORIC_FILES_DIR}/${FILE}" "${TMP_DIR}/${FILE}" >> "${DIFF_FILE}"
    set -e
    echo "* Diferencias en el conjunto de IDs." >> "${REPORT_CONTENT}"
   fi

   mv "${TMP_DIR}/${FILE}" "${HISTORIC_FILES_DIR}/"
   cd "${HISTORIC_FILES_DIR}/"

   # Adds the new file version to git.
   if [[ -n "${ID:-}" ]]; then
    __logd "Agregando una nueva versión de un elemento."
    # Validates concurrency, only one git process.
    __put_lock
    git commit "${FILE}" -m "New version of ${ELEMENT_TYPE} ${ID}." >> "${LOG_FILE}" 2>&1
    __release_lock
   else
    __logd "Agregando una nueva versión de lista de IDs."
    # Validates concurrency, only one git process.
    __put_lock
    git commit "${FILE}" -m "New version of ${FILE}." >> "${LOG_FILE}" 2>&1
    __release_lock
   fi
   cd - > /dev/null
  else
   __logd "No hay diferencias entre la versión guardada y la descargada."
   # The file is the same - no changes in the OSM element.
   rm "${TMP_DIR}/${FILE}"
  fi
 else
  __logd "Agregando un nuevo archivo."
  # If there is no historic file, then it just moves the file in the historic.
  mv "${TMP_DIR}/${FILE}" "${HISTORIC_FILES_DIR}/"
  cd "${HISTORIC_FILES_DIR}/"
  # Validates concurrency, only one git process.
  __put_lock
  git add "${FILE}"
  __release_lock
  if [[ -n "${ID:-}" ]]; then
   __logd "Agregando un nuevo archivo de un elemento."
   __put_lock
   git commit "${FILE}" -m "Initial version of ${ELEMENT_TYPE} ${ID}." >> "${LOG_FILE}" 2>&1
   __release_lock
   cd - > /dev/null
   # Include new files into the report.
   echo "Nuevo https://osm.org/${ELEMENT_TYPE}/${ID}" >> "${REPORT_CONTENT}"
  else
   __logd "Agregando un nuevo archivo de lista de IDs."
   __put_lock
   git commit "${FILE}" -m "Initial version of ${FILE}." >> "${LOG_FILE}" 2>&1
   __release_lock
   cd - > /dev/null
   # Include new files into the report.
   echo "Nuevo conjunto de IDs." >> "${REPORT_CONTENT}"
  fi
  cat "${HISTORIC_FILES_DIR}/${FILE}" >> "${DIFF_FILE}"
 fi
 __log_finish
}

# Retrieves the IDs of the elements to analyze.
function __generateIds {
 __log_start
 __logi "Obtiene los ids de las elementos."
 if [[ "${METHOD_TO_GET_IDS}" == "ids" ]]; then
  __logd "Lista de IDs definida."
  tail -n +2 "${PROCESS_FILE}" > "${IDS_FILE}"
 else
  __logd "IDs por query."
  tail -n +2 "${PROCESS_FILE}" > "${QUERY_FILE}"
  wget -O "${IDS_FILE}" --post-file="${QUERY_FILE}" "https://overpass-api.de/api/interpreter" >> "${LOG_FILE}" 2>&1
  RET=${?}
  if [[ "${RET}" -ne 0 ]]; then
   __loge "Falló la descarga de los ids."
   exit "${ERROR_DOWNLOADING_IDS}"
  fi
  tail -n +2 "${IDS_FILE}" > "${IDS_FILE}2"
  mv "${IDS_FILE}2" "${IDS_FILE}"
 fi
 __logi "Ids para: ${TITLE}."
 __logw "${PROCESS_FILE}"
 cat "${IDS_FILE}" >> "${LOG_FILE}"

 # Adds the IDs list in a file, to keep track of the monitored elements.
 TITLE_NO_SPACES="ids-${TITLE// /}.txt"
 cp "${IDS_FILE}" "${TMP_DIR}"/"${TITLE_NO_SPACES}"
 set +E
 __addFile "${TITLE_NO_SPACES}"
 set -E
 __log_finish
}

# Checks the history of the given elements.
function __checkHistory {
 __log_start
 # Iterates over each element id.
 __logi "Procesando elementos..."
 while read -r ID; do
  __logi "Procesando ${ELEMENT_TYPE} con id ${ID}."

  # Query to retrieve the element.
  cat << EOF > "${QUERY_FILE}"
[out:json];
${ELEMENT_TYPE}(${ID});
(._;>;);
out; 
EOF
  cat "${QUERY_FILE}" >> "${LOG_FILE}"

  # Gets the geometry of the element.
  set +e
  wget -O "${TMP_DIR}/${ELEMENT_TYPE}-${ID}.json" --post-file="${QUERY_FILE}" "https://overpass-api.de/api/interpreter" >> "${LOG_FILE}" 2>&1
  RET=${?}
  set -e
  # Checks if the downloaded element was successful.
  if [[ "${RET}" -ne 0 ]]; then
   __logw "${ELEMENT_TYPE} falló descarga ${ID}."
   continue
  fi
  set +e
  ERROR_QTY=$(grep -c Error "${TMP_DIR}/${ELEMENT_TYPE}-${ID}.json")
  set -e

  # Checks if the downloaded element contains errors.
  if [[ "${ERROR_QTY}" -ne 0 ]]; then
   __logw "Hubo un error en la descaga del elemento ${ELEMENT_TYPE} con id ${ID}."
   __logi "$(cat "${TMP_DIR}/${ELEMENT_TYPE}-${ID}.json" || true)"
   continue
  fi

  # Removes the date from the file.
  sed -i'' -e '/"timestamp_osm_base":/d' "${TMP_DIR}/${ELEMENT_TYPE}-${ID}.json"
  rm -f "${TMP_DIR}/${ELEMENT_TYPE}-${ID}.json-e"
  # Removes the generator value from the file.
  sed -i'' -e '/"generator":/d' "${TMP_DIR}/${ELEMENT_TYPE}-${ID}.json"
  rm -f "i${TMP_DIR}/${ELEMENT_TYPE}-${ID}.json-e"

  # Process the downloaded file.
  set +E
  __addFile "${ELEMENT_TYPE}-${ID}.json"
  set -E

  # Waits between request to prevent errors in Overpass.
  sleep "${WAIT_TIME}"

 done < "${IDS_FILE}"
 __log_finish
}

# Sends the report of the modified elements.
function __sendMail {
 __log_start
 if [[ -f "${REPORT_CONTENT}" ]]; then
  __logi "Enviando mensaje por correo electrónico."
  {
   cat "${REPORT_CONTENT}"
   echo
   echo "Hora de fin: $(date || true)"
   echo
   echo "Este reporte fue creado por medio del script verificador:"
   echo "https://github.com/MaptimeBogota/OSM-elements-change-tracker"
  } >> "${REPORT}"
  echo "" | mutt -s "Detección de diferencias en ${TITLE}" -i "${REPORT}" -a "${DIFF_FILE}" -- "${EMAILS}" >> "${LOG_FILE}"
  __logi "Mensaje enviado."
 fi
 __log_finish
}

# Clean unnecessary files.
function __cleanFiles {
 __log_start
 if [[ "${CLEAN_FILES}" = "true" ]]; then
  __logi "Limpiando archivos innecesarios."
  rm -f "${QUERY_FILE}" "${IDS_FILE}" "${REPORT}" "${DETAILS_DIFF}"
 fi
 __log_finish
}

######
# MAIN

# Allows to other user read the directory.
chmod go+x "${TMP_DIR}"

 __start_logger
if [ ! -t 1 ] ; then
 __set_log_file "${LOG_FILE}"
fi
 __logi "Preparando el ambiente."
 __logd "Salida guardada en: ${TMP_DIR}."
 __logi "Procesando tipo de elemento: ${PROCESS_TYPE}."

if [[ "${PROCESS_TYPE}" == "-h" ]] || [[ "${PROCESS_TYPE}" == "--help" ]]; then
 __show_help
fi
__checkPrereqs
 __logw "Comenzando el proceso."

# Sets the trap in case of any signal.
__trapOn
exec 7> "${LOCK}"

 __prepareEnv
 __generateIds
 set +E
 __checkHistory
 set -E
 __sendMail
 __cleanFiles
 __logw "Proceso terminado."
