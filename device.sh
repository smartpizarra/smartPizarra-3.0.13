#!/system/bin/sh
# ==============================================================================
# device.sh
# ------------------------------------------------------------------------------
# Script de utilidades para administrar un dispositivo Android desde la shell
# (pensado para ejecutarse localmente en el dispositivo, vía ADB, Termux o un
# entorno con acceso a /system/bin/sh).
#
# Funciona como un "router" de comandos: el primer argumento ($1) indica que
# funcion ejecutar, y el resto de los argumentos se le pasan a esa funcion.
#
# USO GENERAL:
#   ./device.sh <comando> [opciones...]
#
# COMANDOS DISPONIBLES:
#   runCode      Ejecuta cualquier comando y muestra su salida normalmente.
#   run_silent   Ejecuta cualquier comando ocultando toda su salida.
#   run_delayed  Espera N segundos y luego ejecuta un comando.
#   run_as_root  Ejecuta un comando con privilegios de root (su).
#   set_prop     Establece una propiedad del sistema Android (setprop).
#   get_prop     Lee una propiedad del sistema Android (getprop).
#   send_nc      Envia un comando de texto a un socket local (toybox nc).
#   deviceInfo   Muestra informacion completa del dispositivo en formato JSON.
#   license      Valida (check) o genera (gen) la clave de licencia del equipo.
#   isReady      Imprime "true" si el script esta operativo.
#   help         Muestra esta ayuda.
#
# EJEMPLOS:
#   ./device.sh isReady
#   ./device.sh runCode ls -la /sdcard
#   ./device.sh run_silent reboot
#   ./device.sh run_delayed 5 echo "hola"
#   ./device.sh run_as_root settings put global airplane_mode_on 1
#   ./device.sh set_prop persist.sys.timezone America/Santo_Domingo
#   ./device.sh get_prop ro.product.model
#   ./device.sh send_nc 40000 settings put global hdmi_control_enabled 0
#   ./device.sh deviceInfo
#   ./device.sh license id
#   ./device.sh license check A1B2-C3D4-E5F6-0718
#   ./device.sh license gen <device_id>
# ==============================================================================


# ==============================================================================
# SECCION 1: HELPERS GENERICOS
# ------------------------------------------------------------------------------
# Funciones pequeñas de uso comun, reutilizadas por el resto del script para
# evitar repetir la misma logica (validaciones, mensajes de error, etc.).
# ==============================================================================

# err <mensaje>
# Imprime un mensaje de error con formato consistente ("Error: ...").
err() {
    echo "Error: $1"
}

# check_args <minimo_requerido> <cantidad_actual> <mensaje_si_falla>
# Valida que se haya recibido una cantidad minima de argumentos.
# Devuelve 1 (falla) e imprime el mensaje de error si no se cumple.
# Uso tipico dentro de una funcion:
#   check_args 2 "$#" "Uso: miFuncion <algo>" || return 1
check_args() {
    minimo="$1"
    actual="$2"
    mensaje="$3"
    if [ "$actual" -lt "$minimo" ]; then
        err "$mensaje"
        return 1
    fi
}

# is_number <valor>
# Devuelve 0 (verdadero) si el valor son solo digitos, 1 si no.
is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)           return 0 ;;
    esac
}

# json_escape <texto>
# Escapa barras invertidas y comillas dobles para incrustar el texto
# de forma segura dentro de un valor de cadena JSON, y elimina saltos de
# linea/tabuladores. Si el texto no tiene nada que escapar, lo devuelve
# directamente sin lanzar sed (ahorra procesos en TV box lentos).
json_escape() {
    case "$1" in
        *[\\\"]*|*"
"*)
            printf '%s' "$1" | tr -d '\r\n\t' | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
        *)
            printf '%s' "$1" ;;
    esac
}

# sh_quote <argumentos...>
# Convierte los argumentos en un texto seguro para "sh -c", poniendo cada
# uno entre comillas simples (y escapando las comillas simples internas).
# Asi "su" recibe los argumentos con espacios o comillas sin romperse.
sh_quote() {
    out=""
    for a in "$@"; do
        case "$a" in
            *\'*) a=$(printf '%s' "$a" | sed "s/'/'\\\\''/g") ;;
        esac
        out="${out:+$out }'$a'"
    done
    printf '%s' "$out"
}

# prop <nombre_propiedad>
# Lee una propiedad Android con getprop pensada para usarse DENTRO del JSON
# de deviceInfo: si esta vacia devuelve "N/A" y siempre escapa el resultado.
# (Para uso general de lectura de propiedades, ver la funcion get_prop).
prop() {
    v=$(getprop "$1")
    [ -z "$v" ] && v="N/A"
    json_escape "$v"
}

# _su <comando...>
# Ejecuta un comando como root. Es un helper interno, usado por run_as_root
# y set_prop para no repetir la misma llamada.
# Detecta una sola vez el tipo de "su" del firmware:
#   - Magisk/SuperSU/KernelSU:  su -c "<comando>"
#   - AOSP (builds userdebug):  su 0 sh -c "<comando>"  (no acepta -c)
# Con un solo argumento se pasa tal cual (permite tuberias: "ls | head");
# con varios, cada argumento se protege con sh_quote.
_su() {
    if [ -z "$SU_MODE" ]; then
        if su -c true >/dev/null 2>&1; then
            SU_MODE="c"
        elif su 0 true >/dev/null 2>&1; then
            SU_MODE="0"
        else
            SU_MODE="none"
        fi
    fi

    if [ "$#" -eq 1 ]; then
        cmd="$1"
    else
        cmd=$(sh_quote "$@")
    fi

    case "$SU_MODE" in
        c) su -c "$cmd" ;;
        0) su 0 sh -c "$cmd" ;;
        *) err "su no disponible (dispositivo sin root)"; return 1 ;;
    esac
}


# ==============================================================================
# SECCION 2: EJECUCION DE COMANDOS
# ------------------------------------------------------------------------------
# Funciones para ejecutar comandos arbitrarios de distintas formas:
# normal, en silencio, con retraso, o como root.
# ==============================================================================

# _exec_shift <subcomando> <comando...>
# Helper interno: descarta el primer argumento (el nombre del subcomando,
# ej. "runCode") y ejecuta el resto como un comando.
_exec_shift() {
    shift
    "$@"
}

# isReady
# Comprueba que el script esta operativo (copiado, con permisos y ejecutable
# por la shell). Imprime "true" y termina con codigo 0. Si el archivo no
# existe o no se puede ejecutar, la app no recibira "true".
# Ejemplo: ./device.sh isReady
isReady() {
    echo "true"
    return 0
}

# runCode <comando...>
# Ejecuta cualquier comando y deja ver su salida (stdout/stderr) normalmente.
# Ejemplo: ./device.sh runCode ls -la /sdcard
runCode() {
    check_args 2 "$#" "No se proporciono comando" || return 1
    _exec_shift "$@"
}

# run_silent <comando...>
# Ejecuta cualquier comando ocultando toda su salida (stdout y stderr).
# Util para comandos donde solo interesa el efecto, no el texto que imprimen.
# Ejemplo: ./device.sh run_silent reboot
run_silent() {
    check_args 2 "$#" "No se proporciono comando" || return 1
    _exec_shift "$@" >/dev/null 2>&1
}

# run_delayed <segundos> <comando...>
# Espera la cantidad de segundos indicada y luego ejecuta el comando.
# Ejemplo: ./device.sh run_delayed 5 echo "hola despues de 5s"
run_delayed() {
    check_args 3 "$#" "Uso: run_delayed <segundos> <comando>" || return 1

    sec="$2"
    is_number "$sec" || { err "segundos debe ser numerico"; return 1; }

    shift 2          # elimina "run_delayed" y "<segundos>", deja solo el comando
    sleep "$sec"
    "$@"
}

# run_as_root <comando...>
# Ejecuta cualquier comando con privilegios de root usando "su".
# Requiere que el dispositivo este rooteado (Magisk, KernelSU, etc.).
# Ejemplo: ./device.sh run_as_root settings put global airplane_mode_on 1
run_as_root() {
    check_args 2 "$#" "No se proporciono comando" || return 1
    shift
    _su "$@"
}


# ==============================================================================
# SECCION 3: PROPIEDADES DEL SISTEMA (getprop / setprop)
# ------------------------------------------------------------------------------
# Funciones para leer y escribir propiedades del sistema Android.
# Las propiedades son pares clave-valor usados por Android para configuracion
# interna (ej. ro.product.model, persist.sys.timezone, debug.*, etc.).
# ==============================================================================

# set_prop <propiedad> <valor>
# Establece el valor de una propiedad Android.
# Primero intenta sin privilegios elevados; si falla, reintenta con "su",
# ya que la mayoria de las propiedades del sistema requieren root.
# Ejemplo: ./device.sh set_prop persist.sys.timezone America/Santo_Domingo
set_prop() {
    check_args 3 "$#" "Uso: set_prop <propiedad> <valor>" || return 1

    propiedad="$2"
    valor="$3"
    [ -z "$propiedad" ] && { err "El nombre de la propiedad no puede estar vacio"; return 1; }

    # Se verifica con getprop despues de cada intento, porque en Android
    # antiguo setprop puede devolver 0 aunque no haya cambiado nada.

    # Intento 1: sin privilegios especiales
    setprop "$propiedad" "$valor" 2>/dev/null
    if [ "$(getprop "$propiedad")" = "$valor" ]; then
        echo "OK: $propiedad=$valor"
        return 0
    fi

    # Intento 2: con privilegios de root
    _su setprop "$propiedad" "$valor" >/dev/null 2>&1
    if [ "$(getprop "$propiedad")" = "$valor" ]; then
        echo "OK (root): $propiedad=$valor"
        return 0
    fi

    err "No se pudo establecer la propiedad (sin permisos)"
    return 1
}

# get_prop <propiedad>
# Lee y muestra el valor de una propiedad Android.
# No requiere root para la gran mayoria de las propiedades.
# Ejemplo: ./device.sh get_prop ro.product.model
get_prop() {
    check_args 2 "$#" "Uso: get_prop <propiedad>" || return 1

    propiedad="$2"
    [ -z "$propiedad" ] && { err "El nombre de la propiedad no puede estar vacio"; return 1; }

    valor=$(getprop "$propiedad" 2>/dev/null)
    if [ -z "$valor" ]; then
        err "Propiedad no encontrada o vacia: $propiedad"
        return 1
    fi

    echo "$valor"
}


# ==============================================================================
# SECCION 4: COMUNICACION VIA SOCKET LOCAL (nc)
# ------------------------------------------------------------------------------
# Para dispositivos que corren un demonio local escuchando en un puerto TCP
# (ej. 127.0.0.1:40000) que ejecuta comandos con privilegios elevados sin
# necesidad de invocar "su" cada vez.
# ==============================================================================

# send_nc <puerto> <comando...>
# Envia un comando de texto a un socket local (127.0.0.1:<puerto>) via
# "toybox nc". Equivale a: echo "<comando>" | toybox nc 127.0.0.1 <puerto>
# Ejemplo: ./device.sh send_nc 40000 settings put global hdmi_control_enabled 0
send_nc() {
    check_args 3 "$#" "Uso: send_nc <puerto> <comando>" || return 1

    puerto="$2"
    is_number "$puerto" || { err "el puerto debe ser numerico"; return 1; }

    shift 2           # elimina "send_nc" y "<puerto>", deja solo el comando
    [ "$#" -eq 0 ] && { err "No se proporciono comando a enviar"; return 1; }

    # Preferir "toybox nc"; si no existe, usar "nc" (busybox u otro)
    if command -v toybox >/dev/null 2>&1; then
        echo "$*" | toybox nc 127.0.0.1 "$puerto"
    elif command -v nc >/dev/null 2>&1; then
        echo "$*" | nc 127.0.0.1 "$puerto"
    else
        err "nc no esta disponible en este dispositivo"
        return 1
    fi
}


# ==============================================================================
# SECCION 5: HELPERS DE RED
# ------------------------------------------------------------------------------
# Funciones auxiliares usadas por deviceInfo para obtener datos de la
# conexion de red activa: interfaz, IP, MAC, mascara, puerta de enlace y DNS.
# Ninguna de estas funciones se invoca directamente desde la linea de
# comandos; son utilizadas internamente por deviceInfo.
# ==============================================================================

# ROUTE_INFO
# Cache de "ip route get 1.1.1.1" (la ruta hacia internet). Se llena una
# sola vez con load_route y la reutilizan get_iface, get_ip y get_gateway,
# en vez de ejecutar "ip route get" tres veces.
ROUTE_INFO=""

# load_route
# Llena ROUTE_INFO si aun esta vacio. Ej. de contenido:
#   "1.1.1.1 via 192.168.1.1 dev wlan0 table 1021 src 192.168.1.50 uid 0"
load_route() {
    [ -z "$ROUTE_INFO" ] && ROUTE_INFO=$(ip route get 1.1.1.1 2>/dev/null | head -n 1)
}

# get_iface
# Devuelve el nombre de la interfaz de red usada por la ruta por defecto
# (la que se usa para salir a internet). Ej: "wlan0", "eth0".
get_iface() {
    load_route
    i=$(printf '%s' "$ROUTE_INFO" | sed -n 's/.* dev \([^ ]*\).*/\1/p')

    # Respaldo: buscar la interfaz en la tabla de rutas si el metodo anterior falla
    [ -z "$i" ] && i=$(ip route 2>/dev/null | sed -n 's/^default .* dev \([^ ]*\).*/\1/p' | head -n 1)

    printf '%s' "$i"
}

# get_ip [interfaz]
# Devuelve la IP local actual. Intenta primero via la ruta por defecto;
# si no hay resultado, intenta leerla directamente de la interfaz dada.
get_ip() {
    load_route
    a=$(printf '%s' "$ROUTE_INFO" | sed -n 's/.* src \([0-9.]*\).*/\1/p')

    if [ -z "$a" ] && [ -n "$1" ]; then
        a=$(ip -f inet addr show "$1" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)
    fi

    [ -z "$a" ] && a="N/A"
    printf '%s' "$a"
}

# get_mac <interfaz>
# Devuelve la direccion MAC de la interfaz indicada.
# Nota: en Android 10+ el Wi-Fi suele usar MAC aleatoria por red, asi que
# este valor puede no coincidir con la MAC "de fabrica" del dispositivo.
get_mac() {
    m=""
    if [ -n "$1" ]; then
        m=$(cat "/sys/class/net/$1/address" 2>/dev/null)

        # Respaldo si el archivo sysfs no existe o esta vacio
        [ -z "$m" ] && m=$(ip link show "$1" 2>/dev/null | sed -n 's/.*link\/ether \([0-9a-fA-F:]*\).*/\1/p' | head -n 1)
    fi
    [ -z "$m" ] && m="N/A"
    printf '%s' "$m"
}

# prefix_to_mask <prefijo_cidr>
# Convierte un prefijo CIDR (ej. 24) a su mascara decimal equivalente
# (ej. 255.255.255.0). "ip" solo entrega el prefijo, no la mascara,
# por eso se necesita esta conversion.
prefix_to_mask() {
    p="$1"
    mask=""
    n=0
    while [ "$n" -lt 4 ]; do
        if [ "$p" -ge 8 ]; then
            o=255
            p=$((p - 8))
        elif [ "$p" -gt 0 ]; then
            o=$((256 - (1 << (8 - p))))
            p=0
        else
            o=0
        fi
        mask="${mask:+$mask.}$o"   # concatena con "." solo si ya hay contenido previo
        n=$((n + 1))
    done
    printf '%s' "$mask"
}

# get_netmask <interfaz>
# Devuelve la mascara de red de la interfaz indicada, en formato decimal.
get_netmask() {
    pf=""
    [ -n "$1" ] && pf=$(ip -f inet addr show "$1" 2>/dev/null | sed -n 's/.*inet [0-9.]*\/\([0-9]*\).*/\1/p' | head -n 1)

    if [ -z "$pf" ]; then
        printf 'N/A'
    else
        prefix_to_mask "$pf"
    fi
}

# get_gateway
# Devuelve la puerta de enlace (gateway) usada por la ruta por defecto.
get_gateway() {
    load_route
    g=$(printf '%s' "$ROUTE_INFO" | sed -n 's/.* via \([0-9.]*\).*/\1/p')

    # Respaldo: buscar directamente en la tabla de rutas
    [ -z "$g" ] && g=$(ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n 1)

    [ -z "$g" ] && g="N/A"
    printf '%s' "$g"
}

# get_dns <interfaz>
# Devuelve los servidores DNS configurados, separados por espacios.
# Primero intenta leer propiedades del sistema; si estan vacias (comun en
# Android moderno), recurre a "dumpsys connectivity" como respaldo.
get_dns() {
    list=""

    # Intento 1: propiedades clasicas de DNS
    for k in net.dns1 net.dns2 net.dns3 net.dns4 "dhcp.$1.dns1" "dhcp.$1.dns2"; do
        d=$(getprop "$k")
        [ -z "$d" ] && continue
        case " $list " in *" $d "*) continue ;; esac   # evita duplicados
        list="$list $d"
    done

    # Intento 2 (respaldo): extraer DNS desde dumpsys connectivity
    if [ -z "$list" ]; then
        raw=$(dumpsys connectivity 2>/dev/null \
            | sed -n 's/.*DnsAddresses: \[\([^]]*\)\].*/\1/p' | head -n 1 \
            | tr -d '/' | tr ',' ' ')
        for d in $raw; do
            case " $list " in *" $d "*) continue ;; esac
            list="$list $d"
        done
    fi

    printf '%s' "$list"
}

# dns_to_json_array <lista_dns_separada_por_espacios>
# Convierte una lista de IPs de DNS (separadas por espacios) en un arreglo
# JSON valido, ej: "8.8.8.8 1.1.1.1" -> ["8.8.8.8", "1.1.1.1"]
dns_to_json_array() {
    arr=""
    for d in $1; do
        arr="${arr:+$arr, }\"$d\""
    done
    printf '[%s]' "$arr"
}


# ==============================================================================
# SECCION 6: HELPERS DE UPTIME Y MEMORIA
# ------------------------------------------------------------------------------
# Funciones auxiliares usadas por deviceInfo para calcular tiempo encendido
# y uso de memoria RAM. Se leen directamente de archivos del kernel en /proc.
# ==============================================================================

# get_uptime
# Devuelve el tiempo que lleva encendido el dispositivo, en segundos.
get_uptime() {
    secs=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    [ -z "$secs" ] && secs=0
    printf '%s' "$secs"
}

# format_uptime <segundos>
# Convierte segundos a un formato legible "XXd XXh XXm".
format_uptime() {
    s="$1"
    printf '%sd %sh %sm' "$((s / 86400))" "$(((s % 86400) / 3600))" "$(((s % 3600) / 60))"
}

# meminfo_mb <campo>
# Lee un campo de /proc/meminfo (ej. "MemTotal", "MemAvailable")
# y devuelve su valor convertido de KB a MB.
meminfo_mb() {
    kb=$(sed -n "s/^$1:[[:space:]]*\([0-9]*\) kB.*/\1/p" /proc/meminfo 2>/dev/null)
    [ -z "$kb" ] && kb=0
    printf '%s' "$((kb / 1024))"
}


# ==============================================================================
# SECCION 7: IDENTIFICADOR UNICO Y PERSISTENTE DEL DISPOSITIVO
# ------------------------------------------------------------------------------
# Genera un identificador (device_id) que permite reconocer de forma unica
# a un dispositivo, incluso despues de un restablecimiento de fabrica.
#
# A diferencia de ANDROID_ID (que SI cambia al restaurar de fabrica), este
# identificador se basa en datos de hardware que normalmente permanecen
# fijos durante toda la vida util del dispositivo:
#   - Numero de serie (ro.serialno / ro.boot.serialno / ro.vendor.serialno)
#   - Numero de serie del SoC (chip) via sysfs o /proc/cpuinfo
#
# Si ninguno de esos datos esta disponible, se usa un metodo de respaldo
# (MAC + marca + modelo + hardware), menos fiable porque la MAC de Wi-Fi
# puede ser aleatoria en Android moderno.
# ==============================================================================

# IMPORTANTE: no cambiar este valor una vez el sistema este en produccion.
# Si se modifica, TODOS los device_id generados cambiaran, perdiendo la
# capacidad de reconocer dispositivos ya identificados anteriormente.
ID_SALT="devid-v1"

# valid_id <valor>
# Determina si un valor leido (serial, etc.) es realmente utilizable como
# identificador, descartando vacios, placeholders comunes y "todo ceros"
# (frecuentes en emuladores o dispositivos con firmware defectuoso).
valid_id() {
    case "$1" in
        ''|unknown|UNKNOWN|null|NULL|0123456789ABCDEF|1234567890ABCDEF|none|None|N/A)
            return 1 ;;
    esac
    case "$1" in
        *[!0]*) return 0 ;;   # tiene al menos un caracter distinto de "0" -> valido
        *)      return 1 ;;   # son puros ceros -> invalido
    esac
}

# hash_str <texto>
# Calcula un hash SHA-256 del texto dado (con respaldo a MD5 si sha256sum
# no esta disponible en el dispositivo). Se usa para no exponer el serial
# real del dispositivo en el device_id final.
hash_str() {
    h=$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1)
    [ -z "$h" ] && h=$(printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1)
    printf '%s' "$h"
}

# make_short_id <device_id_largo>
# Deriva un identificador corto de 8 caracteres hexadecimales en mayusculas
# a partir del device_id completo. Util para mostrar en pantalla, soporte
# tecnico o etiquetas, pero NO se recomienda para identificacion estricta
# (mayor probabilidad de colision que el device_id completo).
make_short_id() {
    case "$1" in
        ''|N/A) printf 'N/A'; return ;;
    esac
    printf '%s' "$1" | cut -c1-8 | tr 'a-f' 'A-F'
}

# first_valid_prop "<lista de propiedades separadas por espacio>"
# Recorre una lista de nombres de propiedades y devuelve el primer valor
# valido encontrado (segun valid_id). Si ninguna es valida, falla (return 1).
first_valid_prop() {
    for k in $1; do
        v=$(getprop "$k")
        if valid_id "$v"; then
            printf '%s' "$v"
            return 0
        fi
    done
    return 1
}

# get_hw_serial
# Intenta obtener el numero de serie de hardware del dispositivo probando
# varias propiedades conocidas, en orden de preferencia.
get_hw_serial() {
    first_valid_prop "ro.serialno ro.boot.serialno ro.vendor.serialno"
}

# get_soc_serial
# Intenta obtener el numero de serie del System-on-Chip (SoC/CPU),
# como fuente alterna de identificacion de hardware.
get_soc_serial() {
    v=$(cat /sys/devices/soc0/serial_number 2>/dev/null)
    if valid_id "$v"; then
        printf '%s' "$v"
        return 0
    fi

    v=$(sed -n 's/^Serial[[:space:]]*:[[:space:]]*\(.*\)$/\1/p' /proc/cpuinfo 2>/dev/null | head -n 1)
    if valid_id "$v"; then
        printf '%s' "$v"
        return 0
    fi

    return 1
}

# compute_device_id
# Calcula el identificador unico del dispositivo y deja el resultado en
# variables globales para que deviceInfo las use directamente:
#   ID_VALUE     -> device_id completo (hash SHA-256/MD5)
#   ID_SHORT     -> version corta de 8 caracteres
#   ID_SOURCE    -> que datos se usaron para generarlo (para diagnostico)
#   ID_RELIABLE  -> "true" si se uso hardware real, "false" si fue respaldo
compute_device_id() {
    hw_serial=$(get_hw_serial)
    soc_serial=$(get_soc_serial)

    if [ -n "$hw_serial" ] || [ -n "$soc_serial" ]; then
        # Caso normal: al menos un serial de hardware esta disponible
        raw="$ID_SALT|serial:$hw_serial|soc:$soc_serial"

        ID_SOURCE=""
        [ -n "$hw_serial" ]  && ID_SOURCE="serial"
        [ -n "$soc_serial" ] && ID_SOURCE="${ID_SOURCE:+$ID_SOURCE+}soc_serial"
        ID_RELIABLE="true"
    else
        # Caso de respaldo: no hay serial de hardware disponible/legible
        fb_mac=$(cat /sys/class/net/wlan0/address 2>/dev/null)
        raw="$ID_SALT|mac:$fb_mac|brand:$(getprop ro.product.brand)|model:$(getprop ro.product.model)|hw:$(getprop ro.hardware)"

        ID_SOURCE="respaldo_mac_modelo"
        ID_RELIABLE="false"
    fi

    ID_VALUE=$(hash_str "$raw")
    [ -z "$ID_VALUE" ] && ID_VALUE="N/A"
    ID_SHORT=$(make_short_id "$ID_VALUE")
}


# ==============================================================================
# SECCION 8: INFORMACION COMPLETA DEL DISPOSITIVO (deviceInfo)
# ------------------------------------------------------------------------------
# Funcion principal que recopila todos los datos del dispositivo (usando los
# helpers de las secciones anteriores) y los imprime como texto plano con
# estructura de JSON.
# ==============================================================================

# deviceInfo
# Muestra informacion completa del dispositivo: identificacion, hardware,
# sistema operativo, red, uptime, memoria, almacenamiento y bateria.
# Salida: JSON en texto plano (no requiere herramientas externas como jq).
# Ejemplo: ./device.sh deviceInfo
deviceInfo() {
    uptime_s=$(get_uptime)
    compute_device_id   # llena ID_VALUE, ID_SHORT, ID_SOURCE, ID_RELIABLE

    # --- Datos de red ---
    # load_route se llama aqui (no dentro de $(...)) para que ROUTE_INFO
    # quede en este shell y la compartan todos los helpers de red.
    load_route
    iface=$(get_iface)
    net_ip=$(get_ip "$iface")
    net_mac=$(get_mac "$iface")
    net_mask=$(get_netmask "$iface")
    net_gw=$(get_gateway)
    net_dns=$(dns_to_json_array "$(get_dns "$iface")")
    [ -z "$iface" ] && iface="N/A"

    # --- Almacenamiento de /data (en MB) ---
    # "set --" reasigna $1 $2 $3... a las columnas de la salida de df:
    # Filesystem, 1K-blocks (total), Used, Available
    set -- $(df -k /data 2>/dev/null | tail -n 1)
    st_total=$(( ${2:-0} / 1024 ))
    st_used=$(( ${3:-0} / 1024 ))
    st_free=$(( ${4:-0} / 1024 ))

    # --- Bateria ---
    # Puede requerir permisos elevados en algunos dispositivos; si da 0
    # de forma persistente, probar con: run_as_root ./device.sh deviceInfo
    bat=$(dumpsys battery 2>/dev/null | sed -n 's/^[[:space:]]*level: \([0-9]*\).*/\1/p' | head -n 1)
    [ -z "$bat" ] && bat=0

    # --- Construccion del JSON (texto plano) ---
    printf '{\n'

    printf '  "identificacion": {\n'
    printf '    "device_id": "%s",\n' "$ID_VALUE"
    printf '    "id_corto": "%s",\n'  "$ID_SHORT"
    printf '    "fuente": "%s",\n'    "$ID_SOURCE"
    printf '    "persistente": %s\n' "$ID_RELIABLE"
    printf '  },\n'

    printf '  "dispositivo": {\n'
    printf '    "marca": "%s",\n'         "$(prop ro.product.brand)"
    printf '    "fabricante": "%s",\n'    "$(prop ro.product.manufacturer)"
    printf '    "modelo": "%s",\n'        "$(prop ro.product.model)"
    printf '    "nombre_codigo": "%s",\n' "$(prop ro.product.device)"
    printf '    "hardware": "%s",\n'      "$(prop ro.hardware)"
    printf '    "arquitectura": "%s"\n'   "$(prop ro.product.cpu.abi)"
    printf '  },\n'

    printf '  "sistema": {\n'
    printf '    "android": "%s",\n'          "$(prop ro.build.version.release)"
    printf '    "sdk": "%s",\n'              "$(prop ro.build.version.sdk)"
    printf '    "parche_seguridad": "%s",\n' "$(prop ro.build.version.security_patch)"
    printf '    "build_id": "%s",\n'         "$(prop ro.build.id)"
    printf '    "fingerprint": "%s",\n'      "$(prop ro.build.fingerprint)"
    printf '    "kernel": "%s"\n'            "$(json_escape "$(uname -r)")"
    printf '  },\n'

    printf '  "red": {\n'
    printf '    "interfaz": "%s",\n'      "$(json_escape "$iface")"
    printf '    "ip": "%s",\n'            "$net_ip"
    printf '    "mac": "%s",\n'           "$net_mac"
    printf '    "mascara": "%s",\n'       "$net_mask"
    printf '    "puerta_enlace": "%s",\n' "$net_gw"
    printf '    "dns": %s\n'              "$net_dns"
    printf '  },\n'

    printf '  "uptime": {\n'
    printf '    "segundos": %s,\n' "$uptime_s"
    printf '    "formato": "%s"\n' "$(format_uptime "$uptime_s")"
    printf '  },\n'

    printf '  "memoria_mb": {\n'
    printf '    "total": %s,\n'     "$(meminfo_mb MemTotal)"
    printf '    "disponible": %s\n' "$(meminfo_mb MemAvailable)"
    printf '  },\n'

    printf '  "almacenamiento_mb": {\n'
    printf '    "total": %s,\n' "$st_total"
    printf '    "usado": %s,\n' "$st_used"
    printf '    "libre": %s\n'  "$st_free"
    printf '  },\n'

    printf '  "bateria": {\n'
    printf '    "nivel": %s\n' "$bat"
    printf '  }\n'

    printf '}\n'
}


# ==============================================================================
# SECCION 9: LICENCIA DEL DISPOSITIVO
# ------------------------------------------------------------------------------
# Cada equipo tiene una clave unica derivada de su device_id (Seccion 7) y de
# un secreto: clave = SHA-256(LIC_VERSION|LIC_SECRET|device_id), primeros 16
# caracteres en mayusculas, con formato XXXX-XXXX-XXXX-XXXX.
#
# FLUJO CON KODULAR:
#   1. La app ejecuta "device.sh license id" y muestra el device_id al
#      cliente (o lo envia a tu servidor).
#   2. Tu generas la clave con "device.sh license gen <device_id>" (en tu PC
#      o en un equipo de prueba) y se la entregas al cliente.
#   3. La app guarda la clave (TinyDB) y en cada inicio ejecuta
#      "device.sh license check <clave>"; solo permite el uso si el JSON
#      devuelto trae "status":"valid" (el codigo de salida tambien es 0).
#
# SALIDA (una sola linea JSON, para JsonTextDecode/diccionarios de Kodular):
#   {"origin":"device","action":"license","status":"valid","device_id":"...",
#    "id_corto":"...","persistente":true}
#   status: "valid"   -> clave correcta para este equipo
#           "invalid" -> clave incorrecta o de otro equipo
#           "no_key"  -> no se recibio clave (usar para mostrar el device_id)
#           "no_id"   -> no se pudo calcular el device_id del equipo
#
# LIMITACIONES:
#   - El secreto queda dentro del script: quien lo lea puede generar claves.
#     Para mas seguridad, validar en un servidor propio.
#   - El device_id debe calcularse siempre en el mismo contexto (la app de
#     Kodular), ya que desde "adb shell" puede salir distinto (ro.serialno).
#   - Si el equipo no tiene sha256sum, hash_str usa md5sum y la clave no
#     coincidira con una generada en un equipo con sha256sum.
# ==============================================================================

# IMPORTANTE: cambiar LIC_SECRET por un valor propio ANTES de distribuir y
# no cambiarlo despues, o todas las licencias entregadas dejaran de valer.
# Cambiar LIC_VERSION invalida a proposito todas las claves anteriores.
LIC_SECRET="CAMBIA-ESTE-SECRETO"
LIC_VERSION="lic-v1"

# normalize_key <clave>
# Pasa la clave a mayusculas y quita guiones, espacios y cualquier otro
# caracter que no sea hexadecimal, para comparar sin importar el formato.
normalize_key() {
    printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -cd '0-9A-F'
}

# license_key <device_id>
# Calcula la clave de licencia que corresponde a un device_id.
# Ejemplo: license_key 3f9a...  ->  3F9A-11C2-0B7D-E845
license_key() {
    case "$1" in
        ''|N/A) return 1 ;;
    esac
    h=$(hash_str "$LIC_VERSION|$LIC_SECRET|$1")
    [ -z "$h" ] && return 1
    printf '%s' "$h" | cut -c1-16 | tr 'a-f' 'A-F' \
        | sed 's/\(....\)\(....\)\(....\)\(....\)/\1-\2-\3-\4/'
}

# license_check <clave>
# Compara la clave recibida con la que corresponde a ESTE equipo e imprime
# el resultado en JSON. Devuelve 0 solo si la licencia es valida.
license_check() {
    compute_device_id   # llena ID_VALUE, ID_SHORT, ID_RELIABLE

    clave=$(normalize_key "$1")
    lic_status="invalid"

    if [ "$ID_VALUE" = "N/A" ]; then
        lic_status="no_id"
    elif [ -z "$clave" ]; then
        lic_status="no_key"
    else
        esperada=$(normalize_key "$(license_key "$ID_VALUE")")
        [ -n "$esperada" ] && [ "$clave" = "$esperada" ] && lic_status="valid"
    fi

    printf '{"origin":"device","action":"license","status":"%s","device_id":"%s","id_corto":"%s","persistente":%s}\n' \
        "$lic_status" "$ID_VALUE" "$ID_SHORT" "$ID_RELIABLE"

    [ "$lic_status" = "valid" ]
}

# license <check|id|gen> [clave|device_id]
# Punto de entrada de los subcomandos de licencia.
#   license check <clave>     -> valida la clave en este equipo (JSON)
#   license id                -> igual que check sin clave: devuelve el
#                                device_id con status "no_key"
#   license gen <device_id>   -> imprime la clave para ese device_id
#                                (uso del vendedor, no de la app)
license() {
    case "$2" in
        check) license_check "$3" ;;
        id)    license_check "" ; return 0 ;;
        gen)
            check_args 3 "$#" "Uso: license gen <device_id>" || return 1
            k=$(license_key "$3") || { err "No se pudo generar la clave"; return 1; }
            echo "$k"
            ;;
        *)
            err "Uso: license [check <clave>|id|gen <device_id>]"
            return 1
            ;;
    esac
}


# ==============================================================================
# SECCION 10: DISPATCHER (punto de entrada del script)
# ------------------------------------------------------------------------------
# Lee el primer argumento ($1) y lo redirige a la funcion correspondiente.
# Si el comando no coincide con ninguno conocido, muestra el modo de uso
# y termina con codigo de salida 1.
#
# MODO LIBRERIA: si se carga con DEVICE_SH_LIB=1, solo se definen las
# funciones y no se ejecuta el dispatcher (util para probar los helpers):
#   DEVICE_SH_LIB=1 . ./device.sh; get_iface
# ==============================================================================

[ -n "$DEVICE_SH_LIB" ] && return 0 2>/dev/null

case "$1" in
    runCode)     runCode "$@" ;;
    run_silent)  run_silent "$@" ;;
    run_delayed) run_delayed "$@" ;;
    run_as_root) run_as_root "$@" ;;
    set_prop)    set_prop "$@" ;;
    get_prop)    get_prop "$@" ;;
    send_nc)     send_nc "$@" ;;
    deviceInfo)  deviceInfo ;;
    license)     license "$@" ;;
    isReady)     isReady ;;
    help|-h|--help)
        sed -n '12,40s/^# \{0,1\}//p' "$0"
        ;;
    *)
        echo "Uso: ./device.sh [runCode|run_silent|run_delayed|run_as_root|set_prop|get_prop|send_nc|deviceInfo|license|isReady|help] [opciones] [comando]"
        exit 1
        ;;
esac