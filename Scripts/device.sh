#!/system/bin/sh
# ============================================================
#  device.sh - Script para Android TV Box
#
#  Uso:  sh device.sh <funcion> [parametros...]
#        sh device.sh help
#
#  El script se re-lanza solo en segundo plano (desacoplado del
#  proceso que lo llamo), asi que sigue vivo aunque la app se cierre.
#  Para forzar primer plano:  SYNC=1 sh device.sh <funcion> ...
# ============================================================

# ---------- Configuracion ----------
WORKDIR="${WORKDIR:-/data/local/tmp/device}"
mkdir -p "$WORKDIR" 2>/dev/null

# Funciones disponibles (las usa el despachador y la ayuda)
FUNCTIONS="help run_cmd run_silent run_delayed run_as_root enable_root \
install_apk uninstall_app launch_app stop_app clear_app_data app_installed list_apps open_url \
device_info get_prop set_prop reboot_device shutdown_device \
screen_on screen_off send_key input_text tap screenshot volume_up volume_down mute \
get_ip wifi_enable wifi_disable ping_host wait_network download_file \
file_exists read_file write_file append_file delete_file list_dir copy_file \
memory_info disk_usage cpu_temp list_processes kill_process get_logcat \
job_status job_result job_list job_kill job_clean"

# Funciones que siempre corren en primer plano (consultas)
FOREGROUND_FUNCTIONS="help job_status job_result job_list job_kill job_clean"

# ---------- Utilidades ----------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

help() {
    echo "Uso: sh device.sh <funcion> [parametros...]"
    echo ""
    echo "EJECUCION"
    echo "  run_cmd <cmd...>              Ejecuta y DEVUELVE el resultado"
    echo "  run_silent <cmd...>           Ejecuta SIN devolver resultado"
    echo "  run_delayed <seg> <cmd...>    Espera N segundos y ejecuta"
    echo "  run_as_root <cmd...>          Ejecuta con su -c y devuelve resultado"
    echo "  enable_root                   Activa root: imprime true o false"
    echo "APLICACIONES"
    echo "  install_apk <ruta.apk>        uninstall_app <paquete>"
    echo "  launch_app <paquete>          stop_app <paquete>"
    echo "  clear_app_data <paquete>      app_installed <paquete>"
    echo "  list_apps [filtro]            open_url <url>"
    echo "DISPOSITIVO"
    echo "  device_info                   get_prop <clave>   set_prop <clave> <valor>"
    echo "  reboot_device [recovery]      shutdown_device"
    echo "PANTALLA / CONTROL"
    echo "  screen_on  screen_off         send_key <KEYCODE>   input_text <texto>"
    echo "  tap <x> <y>                   screenshot [ruta.png]"
    echo "  volume_up  volume_down  mute"
    echo "RED"
    echo "  get_ip  wifi_enable  wifi_disable"
    echo "  ping_host <host>              wait_network [segundos]"
    echo "  download_file <url> <destino>"
    echo "ARCHIVOS"
    echo "  file_exists <ruta>            read_file <ruta>"
    echo "  write_file <ruta> <texto>     append_file <ruta> <texto>"
    echo "  delete_file <ruta>            list_dir <ruta>"
    echo "  copy_file <origen> <destino>"
    echo "SISTEMA"
    echo "  memory_info  disk_usage  cpu_temp  list_processes [filtro]"
    echo "  kill_process <nombre>         get_logcat [lineas]"
    echo "TRABAJOS EN SEGUNDO PLANO"
    echo "  job_status <id>  job_result <id>  job_list  job_kill <id>  job_clean"
}

# ============================================================
#  EJECUCION DE COMANDOS
# ============================================================

# Ejecuta cualquier comando y DEVUELVE el resultado (stdout + stderr).
# Ejemplo: sh device.sh run_cmd "ls -la /sdcard | grep Download"
run_cmd() {
    [ $# -eq 0 ] && { echo "run_cmd: falta el comando"; return 2; }
    _out=$(eval "$*" 2>&1)
    _code=$?
    echo "$_out"
    echo "EXIT_CODE=$_code"
    return $_code
}

# Ejecuta cualquier comando SIN devolver nada.
# Ejemplo: sh device.sh run_silent "am force-stop com.ejemplo.app"
run_silent() {
    [ $# -eq 0 ] && return 2
    eval "$*" >/dev/null 2>&1
    return $?
}

# Espera N segundos y ejecuta el comando (sin devolver resultado).
# Ejemplo: sh device.sh run_delayed 30 "reboot"
run_delayed() {
    _secs="$1"; shift
    [ $# -eq 0 ] && { echo "run_delayed: uso -> run_delayed <segundos> <comando>"; return 2; }
    log "Esperando ${_secs}s antes de ejecutar: $*"
    sleep "$_secs"
    run_silent "$@"
}

# Activa el acceso root. Imprime "true" si se obtuvo root o "false" si no.
# Codigo de salida: 0 = true, 1 = false.
# Orden de intentos:
#   1) Ya se esta ejecutando como root (uid 0)
#   2) su -c "id -u"   (Magisk, SuperSU, su del firmware)
#   3) su 0 id -u      (su de builds userdebug/eng)
# Ejemplo: sh device.sh enable_root
enable_root() {
    # 1) Ya es root
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
        echo "true"; return 0
    fi

    # Sin binario su no hay forma de elevar desde este script
    if ! command -v su >/dev/null 2>&1; then
        echo "false"; return 1
    fi

    # Evita que se cuelgue esperando el popup de permisos (maximo 15 s)
    _to=""
    command -v timeout >/dev/null 2>&1 && _to="timeout 15"

    # 2) su -c
    _uid=$($_to su -c "id -u" 2>/dev/null </dev/null)
    if [ "$_uid" = "0" ]; then
        echo "true"; return 0
    fi

    # 3) su 0
    _uid=$($_to su 0 id -u 2>/dev/null </dev/null)
    if [ "$_uid" = "0" ]; then
        echo "true"; return 0
    fi

    echo "false"
    return 1
}

# Ejecuta un comando como root y devuelve el resultado.
# Si el script ya es root, lo ejecuta directamente sin su.
run_as_root() {
    [ $# -eq 0 ] && { echo "run_as_root: falta el comando"; return 2; }
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
        run_cmd "$*"
    else
        run_cmd "su -c \"$*\""
    fi
}

# ============================================================
#  APLICACIONES
# ============================================================

install_apk() {
    [ -f "$1" ] || { echo "install_apk: no existe el archivo '$1'"; return 1; }
    run_cmd "pm install -r '$1'"
}

uninstall_app() {
    [ -z "$1" ] && { echo "uninstall_app: falta el paquete"; return 2; }
    run_cmd "pm uninstall '$1'"
}

# Abre una app por nombre de paquete.
launch_app() {
    [ -z "$1" ] && { echo "launch_app: falta el paquete"; return 2; }
    run_cmd "monkey -p '$1' -c android.intent.category.LAUNCHER 1"
}

stop_app() {
    [ -z "$1" ] && { echo "stop_app: falta el paquete"; return 2; }
    run_cmd "am force-stop '$1'"
}

clear_app_data() {
    [ -z "$1" ] && { echo "clear_app_data: falta el paquete"; return 2; }
    run_cmd "pm clear '$1'"
}

# Devuelve 0 si la app esta instalada, 1 si no.
app_installed() {
    [ -z "$1" ] && { echo "app_installed: falta el paquete"; return 2; }
    if pm list packages 2>/dev/null | grep -q "package:$1\$"; then
        echo "instalada"; return 0
    else
        echo "no instalada"; return 1
    fi
}

# Lista paquetes instalados, con filtro opcional.
list_apps() {
    if [ -n "$1" ]; then
        pm list packages 2>/dev/null | sed 's/^package://' | grep -i "$1"
    else
        pm list packages 2>/dev/null | sed 's/^package://'
    fi
}

open_url() {
    [ -z "$1" ] && { echo "open_url: falta la URL"; return 2; }
    run_cmd "am start -a android.intent.action.VIEW -d '$1'"
}

# ============================================================
#  DISPOSITIVO
# ============================================================

device_info() {
    echo "Marca    : $(getprop ro.product.brand)"
    echo "Modelo   : $(getprop ro.product.model)"
    echo "Android  : $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
    echo "Build    : $(getprop ro.build.display.id)"
    echo "Arquitec.: $(getprop ro.product.cpu.abi)"
    echo "Serial   : $(getprop ro.serialno)"
    echo "IP wlan0 : $(ip -f inet addr show wlan0 2>/dev/null | grep inet | awk '{print $2}')"
    echo "IP eth0  : $(ip -f inet addr show eth0 2>/dev/null | grep inet | awk '{print $2}')"
    echo "Uptime   : $(uptime 2>/dev/null)"
}

get_prop() {
    [ -z "$1" ] && { echo "get_prop: falta la clave"; return 2; }
    getprop "$1"
}

# Requiere permisos de shell/root segun la propiedad.
set_prop() {
    [ $# -lt 2 ] && { echo "set_prop: uso -> set_prop <clave> <valor>"; return 2; }
    setprop "$1" "$2"
}

# reboot_device            -> reinicio normal
# reboot_device recovery   -> reinicia a recovery
reboot_device() {
    log "Reiniciando dispositivo..."
    if [ -n "$1" ]; then reboot "$1"; else reboot; fi
}

shutdown_device() {
    log "Apagando dispositivo..."
    reboot -p 2>/dev/null || svc power shutdown
}

# ============================================================
#  PANTALLA / CONTROL REMOTO
# ============================================================

# Enciende la pantalla (KEYCODE_WAKEUP).
screen_on() {
    run_silent "input keyevent 224"
}

# Apaga la pantalla (KEYCODE_SLEEP).
screen_off() {
    run_silent "input keyevent 223"
}

# Envia una tecla. Ej: send_key 3 (HOME) | send_key KEYCODE_BACK
send_key() {
    [ -z "$1" ] && { echo "send_key: falta el keycode"; return 2; }
    run_silent "input keyevent '$1'"
}

# Escribe texto (los espacios se envian como %s).
input_text() {
    [ -z "$1" ] && { echo "input_text: falta el texto"; return 2; }
    _txt=$(echo "$*" | sed 's/ /%s/g')
    run_silent "input text '$_txt'"
}

tap() {
    [ $# -lt 2 ] && { echo "tap: uso -> tap <x> <y>"; return 2; }
    run_silent "input tap $1 $2"
}

# Captura de pantalla. Por defecto en $WORKDIR.
screenshot() {
    _dest="${1:-$WORKDIR/screenshot_$(date +%Y%m%d_%H%M%S).png}"
    if screencap -p "$_dest" 2>/dev/null; then
        echo "Captura guardada en: $_dest"
    else
        echo "screenshot: no se pudo capturar la pantalla"; return 1
    fi
}

volume_up()   { run_silent "input keyevent 24"; }
volume_down() { run_silent "input keyevent 25"; }
mute()        { run_silent "input keyevent 164"; }

# ============================================================
#  RED
# ============================================================

get_ip() {
    for _if in wlan0 eth0; do
        _ip=$(ip -f inet addr show "$_if" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
        [ -n "$_ip" ] && echo "$_if: $_ip"
    done
}

wifi_enable()  { run_cmd "svc wifi enable"; }
wifi_disable() { run_cmd "svc wifi disable"; }

ping_host() {
    [ -z "$1" ] && { echo "ping_host: falta el host"; return 2; }
    run_cmd "ping -c 3 '$1'"
}

# Espera a que haya Internet (maximo N segundos, por defecto 60).
wait_network() {
    _max="${1:-60}"
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "Red disponible tras ${_i}s"; return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    echo "wait_network: sin red tras ${_max}s"
    return 1
}

# Descarga un archivo (usa curl, wget o toybox wget segun disponibilidad).
download_file() {
    [ $# -lt 2 ] && { echo "download_file: uso -> download_file <url> <destino>"; return 2; }
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$2" "$1"
    else
        echo "download_file: no hay curl ni wget disponibles"; return 1
    fi
}

# ============================================================
#  ARCHIVOS
# ============================================================

file_exists() {
    [ -z "$1" ] && { echo "file_exists: falta la ruta"; return 2; }
    if [ -e "$1" ]; then echo "existe"; return 0; else echo "no existe"; return 1; fi
}

read_file() {
    [ -f "$1" ] || { echo "read_file: no existe '$1'"; return 1; }
    cat "$1"
}

# Sobrescribe el archivo con el texto.
write_file() {
    [ $# -lt 2 ] && { echo "write_file: uso -> write_file <ruta> <texto>"; return 2; }
    _f="$1"; shift
    echo "$*" > "$_f"
}

# Agrega el texto al final del archivo.
append_file() {
    [ $# -lt 2 ] && { echo "append_file: uso -> append_file <ruta> <texto>"; return 2; }
    _f="$1"; shift
    echo "$*" >> "$_f"
}

delete_file() {
    [ -z "$1" ] && { echo "delete_file: falta la ruta"; return 2; }
    rm -rf "$1"
}

list_dir() {
    ls -la "${1:-.}"
}

copy_file() {
    [ $# -lt 2 ] && { echo "copy_file: uso -> copy_file <origen> <destino>"; return 2; }
    cp -r "$1" "$2"
}

# ============================================================
#  SISTEMA
# ============================================================

memory_info() {
    grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
}

disk_usage() {
    df -h 2>/dev/null || df
}

# Temperatura de las zonas termicas (en grados C).
cpu_temp() {
    _found=0
    for _z in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$_z" ] || continue
        _found=1
        _t=$(cat "$_z" 2>/dev/null)
        _n=$(cat "$(dirname "$_z")/type" 2>/dev/null)
        [ -n "$_t" ] && echo "$_n: $((_t / 1000)) C"
    done
    [ "$_found" -eq 0 ] && echo "cpu_temp: sin sensores termicos accesibles"
}

list_processes() {
    if [ -n "$1" ]; then ps -A 2>/dev/null | grep -i "$1" || ps | grep -i "$1"
    else ps -A 2>/dev/null || ps
    fi
}

kill_process() {
    [ -z "$1" ] && { echo "kill_process: falta el nombre"; return 2; }
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "$1" && echo "Proceso(s) '$1' terminado(s)"
    else
        _pids=$(ps -A 2>/dev/null | grep "$1" | grep -v grep | awk '{print $2}')
        [ -z "$_pids" ] && { echo "kill_process: no se encontro '$1'"; return 1; }
        kill $_pids && echo "Proceso(s) '$1' terminado(s)"
    fi
}

get_logcat() {
    logcat -d -t "${1:-100}" 2>&1
}

# ============================================================
#  TRABAJOS EN SEGUNDO PLANO
# ============================================================

job_status() {
    [ -z "$1" ] && { echo "job_status: falta job_id"; return 2; }
    if [ -f "$WORKDIR/$1.exit" ]; then
        echo "finished (exit=$(cat "$WORKDIR/$1.exit"))"
    elif [ -f "$WORKDIR/$1.pid" ] && kill -0 "$(cat "$WORKDIR/$1.pid")" 2>/dev/null; then
        echo "running (pid=$(cat "$WORKDIR/$1.pid"))"
    else
        echo "unknown"
    fi
}

job_result() {
    [ -z "$1" ] && { echo "job_result: falta job_id"; return 2; }
    if [ -f "$WORKDIR/$1.out" ]; then cat "$WORKDIR/$1.out"
    else echo "sin salida para el job $1"; return 1
    fi
}

# Lista todos los trabajos con su estado.
job_list() {
    _any=0
    for _p in "$WORKDIR"/*.pid; do
        [ -f "$_p" ] || continue
        _any=1
        _id=$(basename "$_p" .pid)
        echo "$_id -> $(job_status "$_id")"
    done
    [ "$_any" -eq 0 ] && echo "no hay trabajos"
}

# Termina un trabajo en ejecucion.
job_kill() {
    [ -z "$1" ] && { echo "job_kill: falta job_id"; return 2; }
    [ -f "$WORKDIR/$1.pid" ] || { echo "job_kill: job no encontrado"; return 1; }
    kill "$(cat "$WORKDIR/$1.pid")" 2>/dev/null && echo "Job $1 terminado" \
        || echo "Job $1 no estaba en ejecucion"
}

# Borra archivos de trabajos ya finalizados.
job_clean() {
    for _e in "$WORKDIR"/*.exit; do
        [ -f "$_e" ] || continue
        _id=$(basename "$_e" .exit)
        rm -f "$WORKDIR/$_id".out "$WORKDIR/$_id".pid "$WORKDIR/$_id".exit
    done
    echo "Trabajos finalizados eliminados"
}

# ============================================================
#  DESPACHADOR
# ============================================================
main() {
    _fn="$1"
    [ -z "$_fn" ] && { help; return 1; }
    shift
    case " $FUNCTIONS " in
        *" $_fn "*) "$_fn" "$@" ;;
        *) echo "Funcion desconocida: $_fn (usa 'help')"; return 127 ;;
    esac
}

# ============================================================
#  EJECUCION INDEPENDIENTE (desacoplada de la app que lo llamo)
# ============================================================
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) ;;
    *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
esac

# Las funciones de consulta corren en primer plano.
_FOREGROUND=0
case " $FOREGROUND_FUNCTIONS " in
    *" $1 "*) _FOREGROUND=1 ;;
esac
[ -z "$1" ] && _FOREGROUND=1

if [ "$_DEVICE_CHILD" != "1" ] && [ "$SYNC" != "1" ] && [ "$_FOREGROUND" != "1" ]; then
    # ---- PROCESO LANZADOR: se re-lanza desacoplado y termina ----
    JOB_ID="$(date +%s)_$$"
    export _DEVICE_CHILD=1 JOB_ID WORKDIR

    if command -v setsid >/dev/null 2>&1; then
        setsid nohup sh "$SCRIPT_PATH" "$@" >"$WORKDIR/$JOB_ID.out" 2>&1 </dev/null &
    else
        nohup sh "$SCRIPT_PATH" "$@" >"$WORKDIR/$JOB_ID.out" 2>&1 </dev/null &
    fi
    echo "$!" > "$WORKDIR/$JOB_ID.pid"

    echo "JOB_ID=$JOB_ID"
    echo "Salida   : $WORKDIR/$JOB_ID.out"
    exit 0
fi

# ---- PROCESO REAL: ignora HUP (cierre de la app/terminal) ----
trap '' HUP

main "$@"
_RC=$?

# Si corre como trabajo en segundo plano, guarda el codigo de salida.
[ -n "$JOB_ID" ] && [ "$_DEVICE_CHILD" = "1" ] && echo "$_RC" > "$WORKDIR/$JOB_ID.exit"
exit $_RC