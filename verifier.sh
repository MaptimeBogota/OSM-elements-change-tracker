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
# The file should start with diff. It is separated by underscore. The middle
# word specifies if the analisys is for: node, way, relation; only one
# type of element is possible. The final word specifies if the elements are
# retrieved with another query or a list of ids. When it is a query, the file
# should contain a valid Overpass query retrieving the ids of the elements to
# analyze; when it is a list of ids, each id of the type of element should be
# in a different line. The first line of the file contains the title of the
# analisys.
# diff_way_query : Checks the differences for the ways returned by this query.
# diff_relation_ids : Checks the differences for the ids listed in this file.
#
# To check the last execution, you can just run:
#   cd $(find /tmp/ -name "verifier_*" -type d -printf "%T@ %p\n"  | sort -n | cut -d' ' -f 2- | tail -n 1) ; tail -f verifier.log ; cd -
#
# Autor: Andres Gomez Casanova - AngocA
# Version: 2023-03-07
declare -r VERSION="2023-03-07"

#set -xv
# Fails when a variable is not initialized.
set -u
# Fails with an non-zero return code.
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

# Lock file for single execution.
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
# Differences file
declare -r DIFF_FILE=${TMP_DIR}/reportDiff.txt
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
 if [[ -f "${LOGGER_UTILITY}" ]] ; then
  # Starts the logger mechanism.
  set +e
  # shellcheck source=./bash_logger.sh
  source "${LOGGER_UTILITY}"
  local -i RET=${?}
  set -e
  if [[ "${RET}" -ne 0 ]] ; then
   printf "\nERROR: El archivo de framework de logger es inválido.\n"
   exit "${ERROR_LOGGER_UTILITY}"
  fi
  # Logger levels: TRACE, DEBUG, INFO, WARN, ERROR.
  __bl_set_log_level "${LOG_LEVEL}"
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
 echo "identifica qué se debe revisar, y después decarga cada uno de los"
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
 echo "Escrito por: Andres Gomez (AngocA)"
 echo "MaptimeBogota."
 exit "${ERROR_HELP_MESSAGE}"
}

# Checks prerequisites to run the script.
function __checkPrereqs {
 __log_start
 set +e
 # Checks prereqs.
 ## Wget
 if ! wget --version > /dev/null 2>&1 ; then
  __loge "Falta instalar wget."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## Mutt
 if ! mutt -v > /dev/null 2>&1 ; then
  __loge "Falta instalar mutt."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## git
 if ! git --version > /dev/null 2>&1 ; then
  echo "Falta instalar git."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## flock
 if ! flock --version > /dev/null 2>&1 ; then
  __loge "Falta instalar flock."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## Bash 4 or greater.
 if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] ; then
  __loge "Requiere Bash 4+."
  exit "${ERROR_MISSING_LIBRARY}"
 fi
 ## Checks if the process file exists.
 if [[ "${PROCESS_FILE}" != "" ]] && [[ ! -r "${PROCESS_FILE}" ]] ; then
  __loge "El archivo para obtener los ids no se encuentra: ${PROCESS_FILE}."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 ## Checks process file structure.
 BASE_PROCESS_FILE_NAME=$(basename -s .sh "${PROCESS_FILE}")

 if [[ "${BASE_PROCESS_FILE_NAME:0:4}" != "diff" ]] ; then
  __loge "El nombre del archivo de proceso no es correcto: ${BASE_PROCESS_FILE_NAME}."
  __logi "Debe comenzar con 'diff'."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 ELEMENT_TYPE=$(echo "${BASE_PROCESS_FILE_NAME}" | awk -F_ '{print $2}')
 METHOD_TO_GET_IDS=$(echo "${BASE_PROCESS_FILE_NAME}" | awk -F_ '{print $3}')
 if [[ "${ELEMENT_TYPE}" != "node" ]] && [[ "${ELEMENT_TYPE}" != "way" ]] \
   && [[ "${ELEMENT_TYPE}" != "relation" ]] ; then
  __loge "El nombre del archivo de proceso no es correcto: ${BASE_PROCESS_FILE_NAME}."
  __logi "Debe tener como token medio: 'node', 'way' o 'relation'."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 ## Checks process file structure.
 if [[ "${METHOD_TO_GET_IDS}" != "query" ]] \
    && [[ "${METHOD_TO_GET_IDS}" != "ids" ]] ; then
  __loge "El nombre del archivo de proceso no es correcto: ${BASE_PROCESS_FILE_NAME}."
  __logi "Debe terminar indicando el tipo para obtener ids: 'query' o 'ids'."
  exit "${ERROR_INVALID_ARGUMENT}"
 fi
 __log_finish
 set -e
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

 if [[ "${TITLE}" == "" ]] ; then
  __logw "El archivo no tiene un título."
 fi

 cat << EOF > "${REPORT}"
Reporte de modificaciones de ${ELEMENT_TYPE} en ${TITLE} en OpenStreetMap.

Hora de inicio: $(date || true).

EOF
 __log_finish
}

# Retrieves the IDs of the elements to analyze. 
function __generateIds {
 __log_start
 __logi "Obtiene los ids de las elementos."
 if [[ "${METHOD_TO_GET_IDS}" == "ids" ]] ; then
  tail -n +2 "${PROCESS_FILE}" > "${IDS_FILE}"
 else
  tail -n +2 "${PROCESS_FILE}" > "${QUERY_FILE}"
  set +e
  wget -O "${IDS_FILE}" --post-file="${QUERY_FILE}" "https://overpass-api.de/api/interpreter" >> "${LOG_FILE}" 2>&1
  RET=${?}
  set -e
  if [[ "${RET}" -ne 0 ]] ; then
   __loge "Falló la descarga de los ids."
   exit "${ERROR_DOWNLOADING_IDS}"
  fi
  tail -n +2 "${IDS_FILE}" > "${IDS_FILE}2"
  mv "${IDS_FILE}2" "${IDS_FILE}"
 fi
 __log_finish
}

# Checks the history of the given elements.
function __checkHistory {
 __log_start
 # Iterates over each element id.
 __logi "Processing elements..."
 while read -r ID ; do
  __logi "Processing ${ELEMENT_TYPE} with id ${ID}."

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
  wget -O "${ELEMENT_TYPE}-${ID}.json" --post-file="${QUERY_FILE}" "https://overpass-api.de/api/interpreter" >> "${LOG_FILE}" 2>&1

  RET=${?}
  set -e
  if [[ "${RET}" -ne 0 ]] ; then
   __logw "${ELEMENT_TYPE} falló descarga ${ID}."
   continue
  fi
 
  # Removes the date from the file.
  sed -i'' -e '/"timestamp_osm_base":/d' "${ELEMENT_TYPE}-${ID}.json"
  rm -f "${ELEMENT_TYPE}-${ID}.json-e"
  # Removes the generator value from the file.
  sed -i'' -e '/"generator":/d' "${ELEMENT_TYPE}-${ID}.json"
  rm -f "${ELEMENT_TYPE}-${ID}.json-e"

  # Process the downloaded file.
  if [[ -r "${HISTORIC_FILES_DIR}/${ELEMENT_TYPE}-${ID}.json" ]] ; then
   # If there is an historic file, it compares it with the downloaded file.
   echo "${ELEMENT_TYPE}-${ID}.json" >> "${DIFF_FILE}"
   set +e
   diff "${HISTORIC_FILES_DIR}/${ELEMENT_TYPE}-${ID}.json" "${ELEMENT_TYPE}-${ID}.json" >> "${DIFF_FILE}"
   RET=${?}
   set -e
   if [[ ${RET} -ne 0 ]] ; then
    mv "${ELEMENT_TYPE}-${ID}.json" "${HISTORIC_FILES_DIR}/"
    cd "${HISTORIC_FILES_DIR}/"
    git commit "${ELEMENT_TYPE}-${ID}.json" -m "New version of ${ELEMENT_TYPE} ${ID}." >> "${LOG_FILE}" 2>&1
    cd - > /dev/null
    echo "* Revisar https://osm.org/${ELEMENT_TYPE}/${ID}" >> "${REPORT_CONTENT}"
   else
    rm "${ELEMENT_TYPE}-${ID}.json"
   fi
  else
   # If there is no historic file, then it just moves the file in the historic.
   mv "${ELEMENT_TYPE}-${ID}.json" "${HISTORIC_FILES_DIR}/"
   cd "${HISTORIC_FILES_DIR}/"
   git add "${ELEMENT_TYPE}-${ID}.json"
   git commit "${ELEMENT_TYPE}-${ID}.json" -m "Initial version of ${ELEMENT_TYPE} ${ID}." >> "${LOG_FILE}" 2>&1
   cd - > /dev/null
  fi

  # Waits between request to prevent errors in Overpass.
  sleep "${WAIT_TIME}"

 done < "${IDS_FILE}"
 __log_finish
}

# Sends the report of the modified elements.
function __sendMail {
 __log_start
 if [[ -f "${REPORT_CONTENT}" ]] ; then
  __logi "Sending mail."
  {
   cat "${REPORT_CONTENT}"
   echo
   echo "Hora de fin: $(date || true)"
   echo
   echo "Este reporte fue creado por medio de el script verificador:"
   echo "https://github.com/MaptimeBogota/OSM-elements-change-tracker" 
  } >> "${REPORT}"
  echo "" | mutt -s "Detección de diferencias en ${TITLE}" -i "${REPORT}" -a "${DIFF_FILE}" -- "${EMAILS}" >> "${LOG_FILE}"
  __logi "Sending sent."
 fi
 __log_finish
}

# Clean unnecessary files.
function __cleanFiles {
 __log_start
 __logi "Cleaning unnecessary files."
 rm -f "${QUERY_FILE}" "${IDS_FILE}" "${REPORT}"
 __log_finish
}

######
# MAIN

# Allows to other user read the directory.
chmod go+x "${TMP_DIR}"

{
 __start_logger
 __logi "Preparing the environment."
 __logd "Output saved at: ${TMP_DIR}"
 __logi "Processing: ${PROCESS_TYPE}"
} >> "${LOG_FILE}" 2>&1

if [[ "${PROCESS_TYPE}" == "-h" ]] || [[ "${PROCESS_TYPE}" == "--help" ]]; then
 __show_help
fi
__checkPrereqs
{
 __logw "Starting process."
} >> "${LOG_FILE}" 2>&1

# Sets the trap in case of any signal.
__trapOn
exec 7> "${LOCK}"
__logw "Validating only execution." | tee -a "${LOG_FILE}"
flock -n 7

{
 __prepareEnv
 __generateIds
 set +E
 __checkHistory
 set -E
 __sendMail
 __cleanFiles
 __logw "Ending process"
} >> "${LOG_FILE}" 2>&1

