#!/bin/bash

# Script: setup_rhel_completo.sh
# Descripción: Script unificado para preparar ambiente RHEL en Techzone
#              0. Prepara y monta el disco adicional (autodetectado: sdb, vdc, nvme...)
#              1. Configura SSH y desactiva firewall
#              2. Mueve /opt al disco de 500GB
#              3. Instala Docker con almacenamiento en /opt
#              4. Instala Git para clonar y hacer push a repositorios en GitHub
# Autor: Julio César García Hernández con apoyo de IBM Bob
# Fecha: 2026
# Versión: 2.2

set -o pipefail  # Capturar errores en pipes

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Función para imprimir mensajes con timestamp
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Función para imprimir éxito
success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# Función para imprimir advertencias
warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Función para imprimir errores y salir
error_exit() {
    echo -e "${RED}❌ ERROR: $1${NC}" >&2
    exit 1
}

# Función para verificar si el comando anterior fue exitoso
check_status() {
    if [ $? -eq 0 ]; then
        success "$1"
    else
        error_exit "$2"
    fi
}

# Función para imprimir separador de sección
print_section() {
    echo
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} $1"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

# Función de limpieza en caso de error crítico
cleanup_on_error() {
    warn "Ejecutando limpieza de emergencia..."
    # Restaurar backups si existen
    if [ -f "$FSTAB_BACKUP" ]; then
        cp "$FSTAB_BACKUP" /etc/fstab 2>/dev/null
    fi
    if [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" /etc/ssh/sshd_config 2>/dev/null
        systemctl restart sshd 2>/dev/null
    fi
}

# Configurar trap para limpieza en caso de interrupción
trap cleanup_on_error INT TERM

# Función para verificar espacio en disco
check_disk_space() {
    local path=$1
    local required_gb=$2
    local available_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ -z "$available_gb" ]; then
        warn "No se pudo verificar espacio en $path"
        return 1
    fi
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        warn "Espacio insuficiente en $path: ${available_gb}GB disponible, ${required_gb}GB requerido"
        return 1
    fi
    
    success "Espacio suficiente en $path: ${available_gb}GB disponible"
    return 0
}

# Verificar que el script se ejecute como root
if [ "$EUID" -ne 0 ]; then 
    error_exit "Este script debe ejecutarse como root. Usa: sudo $0"
fi

# Verificar comandos requeridos
REQUIRED_COMMANDS="parted mkfs.ext4 blkid lsblk df mount umount systemctl grep sed awk curl"
for cmd in $REQUIRED_COMMANDS; do
    if ! command -v $cmd &> /dev/null; then
        error_exit "Comando requerido no encontrado: $cmd. Instala los paquetes necesarios."
    fi
done
success "Todos los comandos requeridos están disponibles"

# Crear directorio de logs
LOG_DIR="/var/log/rhel-setup"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup_completo_$(date +%Y%m%d_%H%M%S).log"

# Redirigir salida a log y consola
exec > >(tee -a "$LOG_FILE")
exec 2>&1

log "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
log "${GREEN}║  PREPARACIÓN COMPLETA DE AMBIENTE RHEL EN TECHZONE               ║${NC}"
log "${GREEN}║  Versión 2.2                                                      ║${NC}"
log "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo
log "Log de ejecución: $LOG_FILE"
echo
log "Este script realizará las siguientes tareas:"
log "  0. Preparar y montar el disco adicional (autodetectado)"
log "  1. Configurar SSH y desactivar firewall"
log "  2. Mover /opt al disco de 500GB (/mnt/second)"
log "  3. Instalar Docker con almacenamiento en /opt"
log "  4. Instalar Git para clonar y hacer push a repositorios en GitHub"
echo

# Verificar sistema operativo
if [ -f /etc/redhat-release ]; then
    OS_VERSION=$(cat /etc/redhat-release)
    log "Sistema operativo detectado: $OS_VERSION"
else
    warn "No se detectó RHEL. El script puede no funcionar correctamente."
fi
echo

read -p "¿Deseas continuar? (s/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    error_exit "Operación cancelada por el usuario"
fi

#############################################################################
# SECCIÓN 0: PREPARAR Y MONTAR DISCO ADICIONAL
#############################################################################

print_section "SECCIÓN 0: PREPARACIÓN DEL DISCO ADICIONAL"

log "Verificando disponibilidad del disco adicional..."

MOUNT_POINT="/mnt/second"
MIN_DISK_GB=400          # Tamaño mínimo esperado del disco adicional (500GB nominales)
SKIP_DISK_PREP="false"

# DETECCIÓN DEL DISCO ADICIONAL
# El nombre del dispositivo varía según el tipo de VM en Techzone (sdb, vdb, vdc, nvme1n1...).
# Se puede forzar manualmente con:  DISK_DEVICE=/dev/xxx ./script.sh
#
# Ruta A: el disco ya viene montado en /mnt/second (aprovisionado por Techzone) -> se omite la Sección 0
# Ruta B: el disco existe pero sin montar/particionar -> se autodetecta y se prepara
# Ruta C: no se encuentra ningún disco candidato -> error con diagnóstico

if [ -z "$DISK_DEVICE" ] && mountpoint -q "$MOUNT_POINT"; then
    EXISTING_DEV=$(findmnt -n -o SOURCE "$MOUNT_POINT")
    EXISTING_SIZE_GB=$(df -BG "$MOUNT_POINT" | awk 'NR==2 {gsub("G","",$2); print $2}')
    log "$MOUNT_POINT ya está montado desde $EXISTING_DEV (${EXISTING_SIZE_GB}GB)"
    if [ "$EXISTING_SIZE_GB" -ge "$MIN_DISK_GB" ]; then
        success "El disco adicional ya está listo en $MOUNT_POINT. Se omite la preparación (Sección 0)"
        SKIP_DISK_PREP="true"
    else
        error_exit "$MOUNT_POINT ya está montado pero solo tiene ${EXISTING_SIZE_GB}GB (se esperaban >= ${MIN_DISK_GB}GB). Revisa con: lsblk; df -h"
    fi
fi

if [ "$SKIP_DISK_PREP" != "true" ]; then
    if [ -z "$DISK_DEVICE" ]; then
        log "Autodetectando disco adicional (>= ${MIN_DISK_GB}GB, sin particiones del sistema)..."
        CANDIDATES=()
        while read -r DNAME DSIZE DTYPE; do
            [ "$DTYPE" = "disk" ] || continue
            [ $((DSIZE/1024/1024/1024)) -ge "$MIN_DISK_GB" ] || continue
            # Descartar discos que contengan /, /boot, /boot/efi o swap
            if lsblk -rno MOUNTPOINT "/dev/$DNAME" | grep -qE '^(/|/boot|/boot/efi|\[SWAP\])$'; then
                continue
            fi
            CANDIDATES+=("/dev/$DNAME")
        done < <(lsblk -b -dn -o NAME,SIZE,TYPE)

        if [ ${#CANDIDATES[@]} -eq 1 ]; then
            DISK_DEVICE="${CANDIDATES[0]}"
            success "Disco adicional detectado: $DISK_DEVICE"
        elif [ ${#CANDIDATES[@]} -eq 0 ]; then
            lsblk
            error_exit "No se encontró un disco adicional >= ${MIN_DISK_GB}GB sin uso. Revisa 'lsblk'; si el disco tiene otro nombre ejecuta: DISK_DEVICE=/dev/xxx $0"
        else
            lsblk
            error_exit "Se encontraron varios discos candidatos (${CANDIDATES[*]}). Indica cuál usar: DISK_DEVICE=/dev/xxx $0"
        fi
    fi

    # Nombre de la partición: nvme0n1 -> nvme0n1p1, sdb -> sdb1, vdc -> vdc1
    if [[ "$DISK_DEVICE" =~ [0-9]$ ]]; then
        PARTITION="${DISK_DEVICE}p1"
    else
        PARTITION="${DISK_DEVICE}1"
    fi
fi

if [ "$SKIP_DISK_PREP" = "true" ]; then
    :  # Sección 0 omitida: disco ya montado
else

# PASO 0.1: Verificar que el disco existe
log "${BLUE}PASO 0.1: Verificando existencia del disco $DISK_DEVICE${NC}"

if [ ! -b "$DISK_DEVICE" ]; then
    error_exit "El disco $DISK_DEVICE no existe. Verifica que el disco adicional esté conectado."
fi
success "Disco $DISK_DEVICE encontrado"

# Mostrar información del disco
DISK_SIZE=$(lsblk -b -d -n -o SIZE $DISK_DEVICE 2>/dev/null | awk '{printf "%.0f GB", $1/1024/1024/1024}')
log "Tamaño del disco: $DISK_SIZE"

# PASO 0.2: Verificar si el disco ya tiene particiones
log "${BLUE}PASO 0.2: Verificando estado del disco${NC}"

EXISTING_PARTITIONS=$(lsblk -n -o NAME $DISK_DEVICE | grep -v "^$(basename $DISK_DEVICE)$" | wc -l)

if [ $EXISTING_PARTITIONS -gt 0 ]; then
    warn "El disco $DISK_DEVICE ya tiene particiones:"
    lsblk $DISK_DEVICE
    read -p "¿Deseas ELIMINAR todas las particiones existentes y crear una nueva? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        error_exit "Operación cancelada por el usuario"
    fi
    
    # Desmontar cualquier partición del disco que esté montada (en cualquier punto, ej /opt o /mnt/second)
    log "Desmontando particiones existentes de $DISK_DEVICE..."
    for MOUNTED_PART in $(lsblk -rno NAME,MOUNTPOINT $DISK_DEVICE | awk '$2!="" {print $1}'); do
        MOUNTPOINTS=$(lsblk -rno MOUNTPOINT "/dev/$MOUNTED_PART")
        for MP in $MOUNTPOINTS; do
            log "Desmontando /dev/$MOUNTED_PART de $MP..."
            umount "$MP" 2>/dev/null
        done
    done
    # Por si /opt quedó apuntando al disco vía bind/otro path, forzar también por dispositivo
    umount -f $DISK_DEVICE* 2>/dev/null

    # Quitar del fstab cualquier entrada previa de este disco (por device, por UUID de sus particiones,
    # o por los puntos de montaje típicos usados por este script) para que no se re-monte solo
    if [ -f /etc/fstab ]; then
        cp /etc/fstab /etc/fstab.bak_disk_cleanup_$(date +%Y%m%d_%H%M%S)
        for PART_UUID in $(lsblk -rno UUID $DISK_DEVICE 2>/dev/null | grep -v '^$'); do
            sed -i "\|$PART_UUID|d" /etc/fstab
        done
        sed -i "\|$DISK_DEVICE|d" /etc/fstab
        sed -i "\|[[:space:]]/mnt/second[[:space:]]|d" /etc/fstab
        sed -i "\|[[:space:]]/opt[[:space:]]|d" /etc/fstab
    fi

    # Limpiar particiones existentes
    log "Limpiando particiones existentes..."
    wipefs -a $DISK_DEVICE
    check_status "Particiones eliminadas" "Error al limpiar el disco"
fi

# PASO 0.3: Crear nueva partición
log "${BLUE}PASO 0.3: Creando partición en $DISK_DEVICE${NC}"

# Usar parted para crear una partición que ocupe todo el disco
parted -s $DISK_DEVICE mklabel gpt
check_status "Tabla de particiones GPT creada" "Error al crear tabla de particiones"

parted -s $DISK_DEVICE mkpart primary ext4 0% 100%
check_status "Partición primaria creada" "Error al crear partición"

# Esperar a que el kernel reconozca la nueva partición
sleep 2
partprobe $DISK_DEVICE
sleep 2

# Verificar que la partición fue creada
if [ ! -b "$PARTITION" ]; then
    error_exit "La partición $PARTITION no fue creada correctamente"
fi
success "Partición $PARTITION creada exitosamente"

# PASO 0.4: Formatear la partición
log "${BLUE}PASO 0.4: Formateando partición $PARTITION con ext4${NC}"

mkfs.ext4 -F $PARTITION
check_status "Partición formateada con ext4" "Error al formatear la partición"

# Obtener UUID de la nueva partición
PARTITION_UUID=$(blkid -s UUID -o value $PARTITION)
if [ -z "$PARTITION_UUID" ]; then
    warn "No se pudo obtener el UUID de $PARTITION"
else
    success "UUID de la partición: $PARTITION_UUID"
fi

# PASO 0.5: Crear punto de montaje
log "${BLUE}PASO 0.5: Creando punto de montaje $MOUNT_POINT${NC}"

if [ -d "$MOUNT_POINT" ]; then
    warn "El directorio $MOUNT_POINT ya existe"
else
    mkdir -p $MOUNT_POINT
    check_status "Directorio $MOUNT_POINT creado" "Error al crear directorio de montaje"
fi

# PASO 0.6: Montar la partición
log "${BLUE}PASO 0.6: Montando $PARTITION en $MOUNT_POINT${NC}"

mount $PARTITION $MOUNT_POINT
check_status "Partición montada" "Error al montar la partición"

# PASO 0.7: Verificar montaje
log "${BLUE}PASO 0.7: Verificando montaje${NC}"

if mountpoint -q $MOUNT_POINT; then
    success "$MOUNT_POINT está montado correctamente"
    df -h $MOUNT_POINT
else
    error_exit "Fallo al verificar el montaje de $MOUNT_POINT"
fi

# Verificar que el punto de montaje es escribible
touch $MOUNT_POINT/.test_write 2>/dev/null
if [ $? -eq 0 ]; then
    rm -f $MOUNT_POINT/.test_write
    success "El punto de montaje es escribible"
else
    error_exit "El punto de montaje no es escribible"
fi

# PASO 0.8: Configurar montaje permanente en fstab
log "${BLUE}PASO 0.8: Configurando montaje permanente en /etc/fstab${NC}"

# Crear backup de fstab
FSTAB_BACKUP="/etc/fstab.backup_disk_$(date +%Y%m%d_%H%M%S)"
cp /etc/fstab $FSTAB_BACKUP
check_status "Backup de fstab creado: $FSTAB_BACKUP" "Error al crear backup de fstab"

# Verificar si ya existe una entrada para este punto de montaje
if grep -q "$MOUNT_POINT" /etc/fstab; then
    warn "Ya existe una entrada para $MOUNT_POINT en /etc/fstab"
    read -p "¿Deseas reemplazarla? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        # Comentar la entrada existente
        sed -i "s|^[^#].*$MOUNT_POINT|#&|" /etc/fstab
        success "Entrada anterior comentada"
    fi
fi

# Añadir nueva entrada a fstab
if [ -n "$PARTITION_UUID" ]; then
    echo "" >> /etc/fstab
    echo "# Añadido por setup_rhel_completo.sh - $(date)" >> /etc/fstab
    echo "UUID=$PARTITION_UUID $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
    success "Entrada añadida a fstab usando UUID: $PARTITION_UUID"
else
    warn "Usando dispositivo $PARTITION en lugar de UUID (menos seguro)"
    echo "" >> /etc/fstab
    echo "# Añadido por setup_rhel_completo.sh - $(date)" >> /etc/fstab
    echo "$PARTITION $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
fi

# PASO 0.9: Probar configuración de fstab
log "${BLUE}PASO 0.9: Probando configuración de fstab${NC}"

# Desmontar y volver a montar usando fstab
umount $MOUNT_POINT
check_status "Punto de montaje desmontado" "Error al desmontar"

mount -a
check_status "Configuración de fstab aplicada" "Error al aplicar fstab"

# Verificar que quedó montado
if mountpoint -q $MOUNT_POINT; then
    success "$MOUNT_POINT montado correctamente desde fstab"
    df -h $MOUNT_POINT
else
    error_exit "Fallo al montar desde fstab. Restaurando backup..."
    cp $FSTAB_BACKUP /etc/fstab
    mount $PARTITION $MOUNT_POINT
    exit 1
fi

success "✓ Sección 0 completada: Disco preparado y montado en $MOUNT_POINT"

fi  # fin de SKIP_DISK_PREP

#############################################################################
# SECCIÓN 1: CONFIGURAR SSH Y FIREWALL
#############################################################################

print_section "SECCIÓN 1: CONFIGURACIÓN DE SSH Y FIREWALL"

log "Verificando requisitos previos..."

# Verificar que el archivo sshd_config existe
if [ ! -f /etc/ssh/sshd_config ]; then
    error_exit "No se encuentra /etc/ssh/sshd_config"
fi

# PASO 1.1: Desactivar firewalld
log "${BLUE}PASO 1.1: Desactivando firewalld${NC}"

if command -v firewall-cmd &> /dev/null; then
    systemctl stop firewalld
    check_status "firewalld detenido" "Error al detener firewalld"
    
    systemctl disable firewalld
    check_status "firewalld deshabilitado" "Error al deshabilitar firewalld"
    
    if systemctl is-active --quiet firewalld; then
        warn "firewalld sigue activo. Verifica manualmente"
    else
        success "firewalld desactivado correctamente"
    fi
else
    warn "firewalld no está instalado, continuando..."
fi

# PASO 1.2: Hacer backup del archivo sshd_config
log "${BLUE}PASO 1.2: Creando backup de sshd_config${NC}"
BACKUP_FILE="/etc/ssh/sshd_config.backup_$(date +%Y%m%d_%H%M%S)"
cp /etc/ssh/sshd_config $BACKUP_FILE
check_status "Backup creado en $BACKUP_FILE" "Error al crear backup"

# PASO 1.3: Modificar sshd_config
log "${BLUE}PASO 1.3: Configurando SSH para permitir forwarding${NC}"

if grep -q "^AllowTcpForwarding" /etc/ssh/sshd_config; then
    sed -i 's/^AllowTcpForwarding/#AllowTcpForwarding/' /etc/ssh/sshd_config
    success "Línea AllowTcpForwarding comentada"
else
    warn "No se encontró 'AllowTcpForwarding' en el archivo"
fi

cat >> /etc/ssh/sshd_config << EOF

# Configuración agregada por script setup_rhel_completo.sh - $(date)
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
PermitOpen any
GatewayPorts no
X11Forwarding no
EOF

success "Bloque de configuración agregado"

# PASO 1.4: Verificar la configuración de SSH
log "${BLUE}PASO 1.4: Verificando configuración de SSH${NC}"
sshd -t
if [ $? -eq 0 ]; then
    success "Configuración de SSH válida"
else
    error_exit "Error en la configuración de SSH. Restaurando backup..."
    cp $BACKUP_FILE /etc/ssh/sshd_config
    exit 1
fi

# PASO 1.5: Reiniciar SSH
log "${BLUE}PASO 1.5: Reiniciando servicio SSH${NC}"
systemctl restart sshd
if [ $? -eq 0 ]; then
    success "SSH reiniciado correctamente"
else
    error_exit "Error al reiniciar SSH. Restaurando backup..."
    cp $BACKUP_FILE /etc/ssh/sshd_config
    exit 1
fi

# Verificar que SSH está activo
if systemctl is-active --quiet sshd; then
    success "SSH está activo y funcionando"
else
    error_exit "SSH no está activo después del reinicio"
fi

success "✓ Sección 1 completada: SSH y firewall configurados"

#############################################################################
# SECCIÓN 2: MOVER /opt AL DISCO DE 500GB
#############################################################################

print_section "SECCIÓN 2: MIGRACIÓN DE /opt AL DISCO DE 500GB"

if mountpoint -q /opt; then
    success "/opt ya es un punto de montaje ($(findmnt -n -o SOURCE /opt)). Se omite la migración (Sección 2)"
    df -h /opt
else

log "Verificando requisitos previos..."

# Verificar que el disco destino existe y está montado
if ! mountpoint -q /mnt/second; then
    error_exit "/mnt/second no está montado. Verifica que el disco de 500GB esté disponible."
fi
success "/mnt/second está montado correctamente"

# Verificar espacio disponible en disco destino
DEST_AVAIL=$(df -BG /mnt/second | awk 'NR==2 {print $4}' | sed 's/G//')
if [ $DEST_AVAIL -lt 450 ]; then
    warn "Espacio disponible en /mnt/second: ${DEST_AVAIL}GB"
    warn "Asegúrate de tener suficiente espacio para los datos de /opt"
    read -p "¿Continuar de todas formas? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        error_exit "Operación cancelada por el usuario"
    fi
fi

# Verificar tamaño de /opt actual
OPT_SIZE=$(du -sh /opt 2>/dev/null | cut -f1)
log "Tamaño actual de /opt: $OPT_SIZE"

# Verificar que el disco de destino tiene un sistema de archivos válido
FS_TYPE=$(df -T /mnt/second | awk 'NR==2 {print $2}')
log "Sistema de archivos en /mnt/second: $FS_TYPE"

# Obtener información de la partición destino
DEST_DEV=$(df /mnt/second | awk 'NR==2 {print $1}')
DEST_UUID=$(blkid -s UUID -o value $DEST_DEV 2>/dev/null)

if [ -z "$DEST_UUID" ]; then
    warn "No se pudo obtener el UUID de $DEST_DEV. Se usará el nombre del dispositivo."
    DEST_UUID=""
fi

# PASO 2.1: Crear directorio temporal
log "${BLUE}PASO 2.1: Creando directorio temporal en disco destino${NC}"
TEMP_DIR="/mnt/second/opt_temp_$(date +%Y%m%d_%H%M%S)"
mkdir -p $TEMP_DIR
check_status "Directorio temporal creado: $TEMP_DIR" "No se pudo crear directorio temporal"

# PASO 2.2: Copiar datos
log "${BLUE}PASO 2.2: Copiando /opt a disco destino (esto puede tomar varios minutos)${NC}"
cp -a /opt/. $TEMP_DIR/
check_status "Copia completada" "Error durante la copia de archivos"

# Verificar integridad básica
ORIG_COUNT=$(find /opt -type f 2>/dev/null | wc -l)
DEST_COUNT=$(find $TEMP_DIR -type f 2>/dev/null | wc -l)

if [ $ORIG_COUNT -eq $DEST_COUNT ]; then
    success "Verificación de integridad: $ORIG_COUNT archivos copiados correctamente"
else
    warn "Discrepancia en número de archivos: Original: $ORIG_COUNT, Destino: $DEST_COUNT"
    read -p "¿Continuar de todas formas? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        error_exit "Operación cancelada por el usuario"
    fi
fi

# PASO 2.3: Preparar sistema
log "${BLUE}PASO 2.3: Preparando sistema para el cambio${NC}"

# Renombrar directorio temporal a 'opt' en el disco destino
rm -rf /mnt/second/opt 2>/dev/null
mv $TEMP_DIR /mnt/second/opt
check_status "Directorio renombrado a /mnt/second/opt" "Error al renombrar directorio"

# Mover /opt original a backup
mv /opt /opt_backup_$(date +%Y%m%d_%H%M%S)
check_status "Backup de /opt original creado" "Error al crear backup"

# Crear nuevo directorio /opt
mkdir /opt
check_status "Nuevo directorio /opt creado" "Error al crear /opt"

# PASO 2.4: Montar disco en /opt
log "${BLUE}PASO 2.4: Montando disco en /opt${NC}"

# Desmontar /mnt/second temporalmente para poder montar en /opt
umount /mnt/second
check_status "/mnt/second desmontado" "Error al desmontar /mnt/second"

# Montar en /opt
mount $DEST_DEV /opt
check_status "Disco montado en /opt" "Error al montar disco en /opt"

# Verificar montaje
if mountpoint -q /opt; then
    success "/opt montado correctamente"
    df -h /opt
else
    error_exit "Fallo al verificar montaje de /opt"
fi

# Verificar que los archivos están accesibles
if [ -d "/opt" ] && [ "$(ls -A /opt)" ]; then
    success "Archivos accesibles en el nuevo /opt"
else
    error_exit "El directorio /opt está vacío después del montaje"
fi

# PASO 2.5: Configurar montaje permanente
log "${BLUE}PASO 2.5: Configurando montaje permanente en /etc/fstab${NC}"

# Crear backup de fstab
cp /etc/fstab /etc/fstab.backup_$(date +%Y%m%d_%H%M%S)
check_status "Backup de fstab creado" "Error al crear backup de fstab"

# Añadir entrada a fstab
if [ -n "$DEST_UUID" ]; then
    echo "# Añadido por script setup_rhel_completo.sh - $(date)" >> /etc/fstab
    echo "UUID=$DEST_UUID /opt $FS_TYPE defaults 0 2" >> /etc/fstab
    success "Entrada añadida a fstab usando UUID: $DEST_UUID"
else
    warn "Usando dispositivo $DEST_DEV en lugar de UUID (menos seguro)"
    echo "# Añadido por script setup_rhel_completo.sh - $(date)" >> /etc/fstab
    echo "$DEST_DEV /opt $FS_TYPE defaults 0 2" >> /etc/fstab
fi

# Probar la nueva configuración de fstab
mount -a
if [ $? -eq 0 ]; then
    success "Configuración de fstab probada correctamente"
else
    error_exit "Error en fstab. Restaurando backup..."
    cp /etc/fstab.backup_* /etc/fstab
    mount -a
    exit 1
fi

success "✓ Sección 2 completada: /opt migrado al disco de 500GB"

fi  # fin de la guarda de /opt ya montado

#############################################################################
# SECCIÓN 3: INSTALAR DOCKER EN /opt
#############################################################################

print_section "SECCIÓN 3: INSTALACIÓN DE DOCKER CON ALMACENAMIENTO EN /opt"

log "Verificando requisitos previos..."

# Verificar sistema operativo
if [ ! -f /etc/redhat-release ]; then
    warn "Este script está diseñado para RHEL 9.7, pero continuará de todas formas"
fi

# Verificar espacio en disco para /opt
OPT_AVAIL=$(df -BG /opt | awk 'NR==2 {print $4}' | sed 's/G//')
if [ $OPT_AVAIL -lt 10 ]; then
    warn "Espacio disponible en /opt: ${OPT_AVAIL}GB"
    warn "Se recomienda al menos 10GB para Docker"
    read -p "¿Continuar de todas formas? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        error_exit "Operación cancelada por el usuario"
    fi
fi

# PASO 3.1: Limpiar instalaciones previas
log "${BLUE}PASO 3.1: Limpiando instalaciones previas de Docker${NC}"

systemctl stop docker docker.socket 2>/dev/null

yum remove -y docker \
    docker-client \
    docker-client-latest \
    docker-common \
    docker-latest \
    docker-latest-logrotate \
    docker-logrotate \
    docker-engine \
    podman \
    runc 2>/dev/null

check_status "Instalaciones previas eliminadas" "Error al eliminar paquetes previos (puede ignorarse si no existían)"

# PASO 3.2: Actualizar el sistema
log "${BLUE}PASO 3.2: Actualizando el sistema${NC}"
yum update -y --skip-broken --nobest
check_status "Sistema actualizado" "Error al actualizar el sistema"

# PASO 3.3: Instalar dependencias
log "${BLUE}PASO 3.3: Instalando dependencias necesarias${NC}"
yum install -y yum-utils device-mapper-persistent-data lvm2
check_status "Dependencias instaladas" "Error al instalar dependencias"

# PASO 3.4: Añadir repositorio de Docker
log "${BLUE}PASO 3.4: Añadiendo repositorio oficial de Docker${NC}"
yum-config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
check_status "Repositorio añadido" "Error al añadir repositorio de Docker"

# PASO 3.5: Crear directorio de almacenamiento
log "${BLUE}PASO 3.5: Creando directorio de almacenamiento en /opt/docker${NC}"
mkdir -p /opt/docker
check_status "Directorio /opt/docker creado" "Error al crear directorio /opt/docker"

# PASO 3.6: Configurar Docker para usar /opt/docker
log "${BLUE}PASO 3.6: Configurando Docker para usar /opt/docker${NC}"
mkdir -p /etc/docker

cat > /etc/docker/daemon.json << EOF
{
  "data-root": "/opt/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
check_status "Archivo de configuración creado" "Error al crear /etc/docker/daemon.json"

# PASO 3.7: Instalar Docker
log "${BLUE}PASO 3.7: Instalando Docker Engine${NC}"
yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
check_status "Docker instalado" "Error al instalar Docker"

# PASO 3.8: Iniciar y habilitar Docker
log "${BLUE}PASO 3.8: Iniciando Docker y habilitando inicio automático${NC}"
systemctl start docker
check_status "Docker iniciado" "Error al iniciar Docker"

systemctl enable docker
check_status "Docker habilitado para inicio automático" "Error al habilitar Docker"

# PASO 3.9: Verificar instalación
log "${BLUE}PASO 3.9: Verificando instalación${NC}"
docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
if [ -n "$docker_version" ]; then
    success "Docker versión $docker_version instalado correctamente"
else
    error_exit "No se pudo verificar la instalación de Docker"
fi

# PASO 3.10: Verificar ubicación de almacenamiento
log "${BLUE}PASO 3.10: Verificando ubicación de almacenamiento${NC}"
docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
if [ "$docker_root" = "/opt/docker" ]; then
    success "Docker está usando /opt/docker para almacenamiento"
else
    warn "Docker está usando $docker_root en lugar de /opt/docker"
    warn "Verifica manualmente la configuración"
fi

# PASO 3.11: Probar con contenedor de prueba
log "${BLUE}PASO 3.11: Probando con contenedor hello-world${NC}"
docker run hello-world 2>/dev/null | grep -q "Hello from Docker"
if [ $? -eq 0 ]; then
    success "Contenedor de prueba ejecutado correctamente"
else
    warn "El contenedor de prueba no funcionó, verifica manualmente"
fi

# PASO 3.12: Instalar docker-compose standalone
log "${BLUE}PASO 3.12: Instalando docker-compose standalone${NC}"
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

docker_compose_version=$(docker-compose --version 2>/dev/null)
if [ -n "$docker_compose_version" ]; then
    success "docker-compose instalado: $docker_compose_version"
else
    warn "docker-compose no se instaló correctamente"
fi

success "✓ Sección 3 completada: Docker instalado y configurado"

#############################################################################
# SECCIÓN 4: INSTALAR GIT
#############################################################################

print_section "SECCIÓN 4: INSTALACIÓN DE GIT"

log "Verificando requisitos previos..."

# PASO 4.1: Verificar si Git ya está instalado
log "${BLUE}PASO 4.1: Verificando instalación previa de Git${NC}"

if command -v git &> /dev/null; then
    warn "Git ya está instalado: $(git --version)"
else
    log "Git no está instalado, procediendo con la instalación"
fi

# PASO 4.2: Instalar Git
log "${BLUE}PASO 4.2: Instalando Git${NC}"
yum install -y git
check_status "Git instalado" "Error al instalar Git"

# PASO 4.3: Verificar instalación
log "${BLUE}PASO 4.3: Verificando instalación de Git${NC}"
git_version=$(git --version 2>/dev/null)
if [ -n "$git_version" ]; then
    success "$git_version instalado correctamente"
else
    error_exit "No se pudo verificar la instalación de Git"
fi

success "✓ Sección 4 completada: Git instalado y listo para clonar/hacer push a repositorios en GitHub"

#############################################################################
# RESUMEN FINAL
#############################################################################

print_section "RESUMEN FINAL DE LA INSTALACIÓN"

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ PREPARACIÓN DE AMBIENTE RHEL COMPLETADA CON ÉXITO            ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📋 SECCIÓN 0: PREPARACIÓN DEL DISCO${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  💾 Disco: ${YELLOW}$DISK_DEVICE${NC}"
echo -e "  📦 Partición: ${YELLOW}$PARTITION${NC}"
echo -e "  🆔 UUID: ${YELLOW}${PARTITION_UUID:-No disponible}${NC}"
echo -e "  📍 Punto de montaje: ${YELLOW}$MOUNT_POINT${NC}"
echo -e "  📁 Sistema de archivos: ${YELLOW}ext4${NC}"
echo -e "  💾 Backup de fstab: ${YELLOW}$FSTAB_BACKUP${NC}"
echo -e "  📊 Espacio disponible:"
df -h $MOUNT_POINT | sed 's/^/     /'
echo

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📋 SECCIÓN 1: SSH Y FIREWALL${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  📍 Firewalld: ${YELLOW}$(systemctl is-active firewalld 2>/dev/null || echo 'inactivo/desinstalado')${NC}"
echo -e "  🔧 Backup de sshd_config: ${YELLOW}$BACKUP_FILE${NC}"
echo -e "  🔄 SSH: ${YELLOW}$(systemctl is-active sshd)${NC}"
echo -e "  📝 Configuración SSH:"
grep -E "AllowTcpForwarding|AllowStreamLocalForwarding|PermitOpen|GatewayPorts|X11Forwarding" /etc/ssh/sshd_config | grep -v "^#" | sed 's/^/     /'
echo

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📋 SECCIÓN 2: MIGRACIÓN DE /opt${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  📍 Punto de montaje: ${YELLOW}/opt${NC}"
echo -e "  💾 Dispositivo: ${YELLOW}$DEST_DEV${NC}"
echo -e "  📁 Sistema de archivos: ${YELLOW}$FS_TYPE${NC}"
echo -e "  🆔 UUID: ${YELLOW}${DEST_UUID:-No disponible}${NC}"
echo -e "  📦 Backup del antiguo /opt: ${YELLOW}/opt_backup_*${NC}"
echo -e "  💾 Backup de fstab: ${YELLOW}/etc/fstab.backup_*${NC}"
echo -e "  📊 Espacio en /opt:"
df -h /opt | sed 's/^/     /'
echo

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📋 SECCIÓN 3: DOCKER${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  📍 Versión de Docker: ${YELLOW}$docker_version${NC}"
echo -e "  💾 Almacenamiento: ${YELLOW}$docker_root${NC}"
echo -e "  📁 Directorio de datos: ${YELLOW}/opt/docker${NC}"
echo -e "  🔧 docker-compose: ${YELLOW}$(docker-compose --version 2>/dev/null || echo 'No instalado')${NC}"
echo -e "  📊 Uso de Docker:"
docker system df 2>/dev/null | sed 's/^/     /'
echo

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}📋 SECCIÓN 4: GIT${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  📍 Versión de Git: ${YELLOW}$git_version${NC}"
echo

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  NOTAS IMPORTANTES${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${YELLOW}📌 Preparación del Disco:${NC}"
echo "   • El disco $DISK_DEVICE ha sido particionado y formateado"
echo "   • Montado permanentemente en $MOUNT_POINT"
echo "   • Si necesitas revertir, restaura el fstab:"
echo "     sudo cp $FSTAB_BACKUP /etc/fstab"
echo
echo -e "${YELLOW}📌 SSH y Firewall:${NC}"
echo "   • Si algo falla al reconectar, restaura el backup:"
echo "     cp $BACKUP_FILE /etc/ssh/sshd_config && systemctl restart sshd"
echo "   • Log guardado en: /root/ssh_config_log.txt"
echo
echo -e "${YELLOW}📌 Migración de /opt:${NC}"
echo "   • Puedes eliminar el backup cuando confirmes que todo funciona:"
echo "     sudo rm -rf /opt_backup_*"
echo "   • Si algo falla al reiniciar, restaura el fstab:"
echo "     sudo cp /etc/fstab.backup_* /etc/fstab"
echo
echo -e "${YELLOW}📌 Docker:${NC}"
echo "   • Para usar Docker sin sudo, agrega tu usuario al grupo docker:"
echo "     sudo usermod -aG docker \$USER"
echo "     (Cierra sesión y vuelve a entrar para que surta efecto)"
echo "   • Log guardado en: /root/docker_install_log.txt"
echo
echo -e "${YELLOW}📌 Git:${NC}"
echo "   • Configura tu identidad antes de hacer commits:"
echo "     git config --global user.name \"Tu Nombre\""
echo "     git config --global user.email \"tu_correo@ejemplo.com\""
echo "   • Para hacer push a GitHub, genera una llave SSH y agrégala a tu cuenta:"
echo "     ssh-keygen -t ed25519 -C \"tu_correo@ejemplo.com\""
echo "     cat ~/.ssh/id_ed25519.pub  # Copia esto en GitHub > Settings > SSH Keys"
echo "   • También puedes usar un Personal Access Token para HTTPS en lugar de SSH"
echo

# Guardar logs consolidados
cat > /root/rhel_setup_complete_log.txt << EOF
═══════════════════════════════════════════════════════════════════
PREPARACIÓN COMPLETA DE AMBIENTE RHEL EN TECHZONE
Creado por: Julio César García Hernández con apoyo de IBM Bob
═══════════════════════════════════════════════════════════════════
Fecha de instalación: $(date)

SECCIÓN 0: PREPARACIÓN DEL DISCO
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Disco: $DISK_DEVICE
Partición: $PARTITION
UUID: ${PARTITION_UUID:-No disponible}
Punto de montaje: $MOUNT_POINT
Sistema de archivos: ext4
Backup fstab: $FSTAB_BACKUP
Espacio disponible:
$(df -h $MOUNT_POINT)

SECCIÓN 1: SSH Y FIREWALL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Firewalld: $(systemctl is-active firewalld 2>/dev/null || echo 'inactivo/desinstalado')
Backup sshd_config: $BACKUP_FILE
SSH Status: $(systemctl is-active sshd)
Configuración SSH:
$(grep -E "AllowTcpForwarding|AllowStreamLocalForwarding|PermitOpen|GatewayPorts|X11Forwarding" /etc/ssh/sshd_config | grep -v "^#")

SECCIÓN 2: MIGRACIÓN DE /opt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Dispositivo: $DEST_DEV
Sistema de archivos: $FS_TYPE
UUID: ${DEST_UUID:-No disponible}
Backup /opt: /opt_backup_*
Backup fstab: /etc/fstab.backup_*
Espacio en /opt:
$(df -h /opt)

SECCIÓN 3: DOCKER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Versión Docker: $docker_version
Almacenamiento: $docker_root
docker-compose: $(docker-compose --version 2>/dev/null || echo 'No instalado')
Uso de Docker:
$(docker system df 2>/dev/null)

SECCIÓN 4: GIT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Versión Git: $git_version
EOF

success "Log consolidado guardado en /root/rhel_setup_complete_log.txt"

echo
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  🎉 ¡PROCESO COMPLETADO CON ÉXITO!                               ║${NC}"
echo -e "${GREEN}║  El ambiente RHEL está listo para usar                           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo

# Made with Bob