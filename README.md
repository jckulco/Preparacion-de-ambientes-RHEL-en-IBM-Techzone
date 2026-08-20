# 🚀 Scripts de Preparación de Ambiente RHEL en IBM TechZone

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![RHEL](https://img.shields.io/badge/RHEL-9.x-red.svg)](https://www.redhat.com/en/technologies/linux-platforms/enterprise-linux)
[![Bash](https://img.shields.io/badge/Bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)

Scripts automatizados para configurar y optimizar ambientes Red Hat Enterprise Linux (RHEL) en IBM TechZone, diseñados para maximizar el uso del disco adicional de 500GB y preparar el sistema para cargas de trabajo empresariales.

## 📋 Tabla de Contenidos

- [Características](#-características)
- [Requisitos Previos](#-requisitos-previos)
- [Scripts Disponibles](#-scripts-disponibles)
- [Instalación](#-instalación)
- [Uso](#-uso)
- [Qué Hace Cada Script](#-qué-hace-cada-script)
- [Estructura de Logs](#-estructura-de-logs)
- [Recuperación ante Errores](#-recuperación-ante-errores)
- [Mejores Prácticas](#-mejores-prácticas)
- [Solución de Problemas](#-solución-de-problemas)
- [Contribuir](#-contribuir)
- [Licencia](#-licencia)
- [Autor](#-autor)

## ✨ Características

- ✅ **Automatización completa**: Configuración end-to-end sin intervención manual
- 🔒 **Seguridad**: Validaciones exhaustivas y backups automáticos
- 📊 **Logging detallado**: Registro completo de todas las operaciones
- 🔄 **Recuperación automática**: Rollback en caso de errores
- 🎨 **Interfaz amigable**: Output colorizado y mensajes claros
- 🛡️ **Manejo de errores robusto**: Traps y validaciones en cada paso
- 📦 **Modular**: Dos versiones según necesidades (con/sin Docker)

## 🔧 Requisitos Previos

### Sistema Operativo
- Red Hat Enterprise Linux (RHEL) 9.x
- Acceso root o sudo
- Conexión a Internet (para instalación de Docker)

### Hardware
- Disco adicional de 500GB (típicamente `/dev/sdb` en TechZone)
- Mínimo 2GB RAM
- Espacio suficiente en disco raíz para backups temporales

### Comandos Requeridos
Los scripts verifican automáticamente la disponibilidad de:
- `parted`, `mkfs.ext4`, `blkid`, `lsblk`
- `df`, `mount`, `umount`
- `systemctl`, `grep`, `sed`, `awk`
- `curl` (solo para versión con Docker)

## 📦 Scripts Disponibles

### 1. `setup_rhel_completo.sh` (Versión Completa)
Script integral que incluye:
- ✅ Preparación y montaje del disco adicional
- ✅ Configuración de SSH y firewall
- ✅ Migración de `/opt` al disco de 500GB
- ✅ Instalación y configuración de Docker
- ✅ Instalación de Git (clonar y hacer push a repositorios en GitHub)

**Ideal para**: Ambientes de desarrollo, contenedores, microservicios

### 2. `setup_rhel_sin_docker.sh` (Versión Ligera)
Script optimizado sin Docker que incluye:
- ✅ Preparación y montaje del disco adicional
- ✅ Configuración de SSH y firewall
- ✅ Migración de `/opt` al disco de 500GB

**Ideal para**: Servidores de aplicaciones, bases de datos, ambientes sin contenedores

## 🚀 Instalación

### Opción 1: Clonar el Repositorio
```bash
git clone https://github.com/tu-usuario/preparacion-rhel-techzone.git
cd preparacion-rhel-techzone
chmod +x setup_rhel_completo.sh setup_rhel_sin_docker.sh
```

### Opción 2: Descarga Directa
```bash
# Versión completa (con Docker)
curl -O https://raw.githubusercontent.com/tu-usuario/preparacion-rhel-techzone/main/setup_rhel_completo.sh
chmod +x setup_rhel_completo.sh

# Versión sin Docker
curl -O https://raw.githubusercontent.com/tu-usuario/preparacion-rhel-techzone/main/setup_rhel_sin_docker.sh
chmod +x setup_rhel_sin_docker.sh
```

## 💻 Uso

### Ejecución Básica

**Versión Completa (con Docker):**
```bash
sudo ./setup_rhel_completo.sh
```

**Versión Sin Docker:**
```bash
sudo ./setup_rhel_sin_docker.sh
```

### Ejecución con Logging Personalizado
```bash
# Redirigir salida a archivo personalizado
sudo ./setup_rhel_completo.sh 2>&1 | tee mi_instalacion.log
```

### Modo No Interactivo (Automatización)
```bash
# Responder automáticamente "sí" a todas las preguntas
yes s | sudo ./setup_rhel_completo.sh
```

## 🔍 Qué Hace Cada Script

### Sección 0: Preparación del Disco Adicional

1. **Detección del disco**: Identifica `/dev/sdb` (disco de 500GB)
2. **Particionamiento**: Crea tabla GPT y partición primaria
3. **Formateo**: Formatea con sistema de archivos ext4
4. **Montaje**: Monta en `/mnt/second`
5. **Persistencia**: Configura `/etc/fstab` para montaje automático

```
Antes:                  Después:
/dev/sdb (sin usar)  →  /dev/sdb1 → /mnt/second (500GB disponible)
```

### Sección 1: Configuración de SSH y Firewall

1. **Firewall**: Desactiva `firewalld` (común en ambientes de desarrollo)
2. **SSH**: Configura forwarding para túneles y port forwarding
3. **Backup**: Crea respaldo de configuración original
4. **Validación**: Verifica sintaxis antes de aplicar cambios

**Configuración SSH aplicada:**
```
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
PermitOpen any
GatewayPorts no
X11Forwarding no
```

### Sección 2: Migración de /opt

1. **Copia**: Transfiere todo el contenido de `/opt` al disco de 500GB
2. **Verificación**: Valida integridad de archivos copiados
3. **Backup**: Renombra `/opt` original a `/opt_backup_*`
4. **Remontaje**: Monta el disco de 500GB en `/opt`
5. **Persistencia**: Actualiza `/etc/fstab`

```
Antes:                          Después:
/opt (disco raíz, ~50GB)    →   /opt (disco 500GB) + /opt_backup_*
```

### Sección 3: Instalación de Docker (solo `setup_rhel_completo.sh`)

1. **Limpieza**: Elimina instalaciones previas de Docker/Podman
2. **Repositorio**: Añade repositorio oficial de Docker
3. **Instalación**: Instala Docker CE, CLI, containerd y plugins
4. **Configuración**: Configura almacenamiento en `/opt/docker`
5. **Validación**: Ejecuta contenedor de prueba
6. **Docker Compose**: Instala docker-compose standalone

**Configuración Docker aplicada:**
```json
{
  "data-root": "/opt/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

### Sección 4: Instalación de Git (solo `setup_rhel_completo.sh`)

1. **Verificación**: Comprueba si Git ya está instalado
2. **Instalación**: Instala Git mediante `yum`
3. **Validación**: Verifica la versión instalada

Con Git instalado puedes clonar repositorios y hacer push a GitHub. Al finalizar, el script muestra cómo:

```bash
# Configurar tu identidad
git config --global user.name "Tu Nombre"
git config --global user.email "tu_correo@ejemplo.com"

# Generar una llave SSH para autenticar el push a GitHub
ssh-keygen -t ed25519 -C "tu_correo@ejemplo.com"
cat ~/.ssh/id_ed25519.pub  # Agrega esta llave en GitHub > Settings > SSH Keys
```

## 📁 Estructura de Logs

Los scripts generan logs detallados en `/var/log/rhel-setup/`:

```
/var/log/rhel-setup/
├── setup_completo_20260714_123456.log      # Log de versión completa
└── setup_sin_docker_20260714_123456.log    # Log de versión sin Docker
```

Además, se crean logs consolidados en `/root/`:
- `/root/rhel_setup_complete_log.txt` (versión completa)
- `/root/rhel_setup_sin_docker_log.txt` (versión sin Docker)

### Backups Creados

Los scripts crean múltiples backups para recuperación:

```
/etc/fstab.backup_disk_YYYYMMDD_HHMMSS      # Backup inicial de fstab (disco)
/etc/fstab.backup_YYYYMMDD_HHMMSS           # Backup de fstab (migración /opt)
/etc/ssh/sshd_config.backup_YYYYMMDD_HHMMSS # Backup de configuración SSH
/opt_backup_YYYYMMDD_HHMMSS/                # Backup del /opt original
```

## 🔄 Recuperación ante Errores

### Restaurar Configuración SSH
```bash
# Si SSH falla después de la configuración
sudo cp /etc/ssh/sshd_config.backup_* /etc/ssh/sshd_config
sudo systemctl restart sshd
```

### Restaurar fstab
```bash
# Si el sistema no arranca después de cambios en fstab
# Desde modo de rescate o live USB:
sudo cp /etc/fstab.backup_* /etc/fstab
sudo mount -a
```

### Restaurar /opt Original
```bash
# Si necesitas volver al /opt original
sudo umount /opt
sudo rm -rf /opt
sudo mv /opt_backup_* /opt
# Comentar entrada de /opt en /etc/fstab
sudo sed -i 's|^UUID=.*\s/opt|#&|' /etc/fstab
```

### Limpieza Automática
Los scripts incluyen traps para limpieza automática en caso de:
- Interrupción con Ctrl+C
- Señal TERM
- Errores críticos

## 🎯 Mejores Prácticas

### Antes de Ejecutar

1. **Backup completo**: Realiza snapshot o backup del sistema
2. **Verificar disco**: Confirma que `/dev/sdb` es el disco correcto
   ```bash
   lsblk
   ```
3. **Conexión estable**: Asegura conexión SSH estable (usa `screen` o `tmux`)
4. **Revisar el script**: Lee el código antes de ejecutar

### Durante la Ejecución

1. **No interrumpir**: Evita cancelar el script a menos que sea necesario
2. **Monitorear logs**: Observa los mensajes para detectar advertencias
3. **Responder prompts**: Lee cuidadosamente antes de confirmar

### Después de la Ejecución

1. **Verificar montajes**: 
   ```bash
   df -h
   mount | grep -E '/opt|/mnt/second'
   ```
2. **Probar SSH**: Abre nueva sesión SSH para verificar
3. **Verificar Docker** (si aplica):
   ```bash
   docker --version
   docker run hello-world
   ```
4. **Eliminar backups**: Después de confirmar que todo funciona
   ```bash
   sudo rm -rf /opt_backup_*
   ```

## 🐛 Solución de Problemas

### Error: "El disco /dev/sdb no existe"

**Causa**: El disco adicional no está conectado o tiene otro nombre

**Solución**:
```bash
# Listar todos los discos
lsblk

# Si el disco es /dev/sdc en lugar de /dev/sdb, edita el script:
# Cambia DISK_DEVICE="/dev/sdb" por DISK_DEVICE="/dev/sdc"
```

### Error: "Espacio insuficiente"

**Causa**: El disco de 500GB no tiene suficiente espacio

**Solución**:
```bash
# Verificar espacio
df -h /mnt/second

# Limpiar archivos innecesarios
sudo du -sh /mnt/second/* | sort -h
```

### Error: "SSH no reinicia"

**Causa**: Error de sintaxis en configuración SSH

**Solución**:
```bash
# Verificar configuración
sudo sshd -t

# Restaurar backup
sudo cp /etc/ssh/sshd_config.backup_* /etc/ssh/sshd_config
sudo systemctl restart sshd
```

### Error: "Docker no inicia"

**Causa**: Problemas con almacenamiento o configuración

**Solución**:
```bash
# Ver logs de Docker
sudo journalctl -u docker -n 50

# Verificar configuración
sudo cat /etc/docker/daemon.json

# Reiniciar Docker
sudo systemctl restart docker
```

### Sistema no arranca después de cambios

**Causa**: Error en `/etc/fstab`

**Solución**:
1. Arrancar en modo de rescate o con live USB
2. Montar partición raíz
3. Restaurar backup de fstab:
   ```bash
   cp /etc/fstab.backup_* /etc/fstab
   ```
4. Reiniciar

## 🤝 Contribuir

Las contribuciones son bienvenidas. Por favor:

1. Fork el repositorio
2. Crea una rama para tu feature (`git checkout -b feature/AmazingFeature`)
3. Commit tus cambios (`git commit -m 'Add some AmazingFeature'`)
4. Push a la rama (`git push origin feature/AmazingFeature`)
5. Abre un Pull Request

### Guías de Contribución

- Mantén el estilo de código consistente
- Añade comentarios descriptivos
- Actualiza la documentación
- Prueba en ambiente RHEL real antes de PR

## 📄 Licencia

Este proyecto está bajo la Licencia MIT. Ver archivo `LICENSE` para más detalles.

## 👤 Autor

**Julio César García Hernández**

Desarrollado con el apoyo de **IBM Bob** (AI Assistant)

---

## 📚 Referencias

- [Red Hat Enterprise Linux Documentation](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9)
- [Docker Documentation](https://docs.docker.com/)
- [IBM TechZone](https://techzone.ibm.com/)
- [Bash Best Practices](https://google.github.io/styleguide/shellguide.html)

## 🔖 Versión

**Versión actual**: 2.1

### Changelog

#### v2.1 (2026-07-30)
- ✨ Agregada Sección 4: instalación de Git en `setup_rhel_completo.sh`
- 📝 Documentadas instrucciones para configurar identidad y llave SSH para GitHub

#### v2.0 (2026-07-14)
- ✨ Agregado logging completo a archivo
- ✨ Implementado trap para limpieza automática
- ✨ Añadida validación de comandos requeridos
- ✨ Mejorado manejo de errores con `set -o pipefail`
- ✨ Agregada función de verificación de espacio en disco
- 📝 Documentación completa en README
- 🔧 Mejoras en mensajes de usuario

#### v1.0 (2026-04-08)
- 🎉 Versión inicial
- ✅ Preparación de disco adicional
- ✅ Configuración SSH y firewall
- ✅ Migración de /opt
- ✅ Instalación de Docker

---

<div align="center">

**⭐ Si este proyecto te fue útil, considera darle una estrella ⭐**

Made with ❤️ for the IBM Community

</div>
