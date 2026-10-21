#!/usr/bin/env bash
# steamdeck-fix-all.sh — полный фикс для Steam Deck на Arch linux-zen 7.x
# 1) I2C PSP-семафор (DKMS, уникальное имя, без конфликта со встроенным)
# 2) Демон кулера v2 (rpm/pwm/state, гистерезис, рампа, подшипник-щадящий)
# Идемпотентен. Ядро и GRUB НЕ трогает.
set -euo pipefail

# ===== конфигурация =====
SRC_ORIG="${1:-/mnt/sdcard/55/FUCK MY BRAIN STEAM/drivers/i2c/busses}"
BUILD_DIR="/usr/src/steamdeck-i2c-fix-1.0"
MOD="i2c-designware-platform-pspfix"
DRV_BUILTIN="i2c_designware"
DRV_OURS="i2c_designware_pspfix"
DEV="AMDI0010:00"
WARMUP_SEC="${WARMUP_SEC:-8}"
FAN_HW="hwmon6"
TEMP_HW="hwmon5"
# ========================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

[[ $EUID -ne 0 ]] && { log_err "Нужен root (sudo)"; exit 1; }

# ===== 0. проверки =====
log_info "Проверки..."
[[ -d "$SRC_ORIG" ]] || { log_err "Оригиналы не найдены: $SRC_ORIG. Передай путь первым аргументом."; exit 1; }
[[ -f "/lib/modules/$(uname -r)/build/Makefile" ]] || { log_err "Нет заголовков ядра: sudo pacman -S linux-zen-headers"; exit 1; }
command -v dkms >/dev/null || { log_err "Нет dkms: sudo pacman -S dkms"; exit 1; }
log_ok "Проверки пройдены"

# ===== 1. бэкап =====
log_info "Бэкап..."
rm -rf "$BUILD_DIR.bak" 2>/dev/null || true
[[ -d "$BUILD_DIR" ]] && cp -a "$BUILD_DIR" "$BUILD_DIR.bak"
mkdir -p "$BUILD_DIR"
log_ok "Бэкап создан"

# ===== 2. копирование оригиналов =====
log_info "Копирование оригиналов из SteamOS..."
for f in i2c-designware-common.c i2c-designware-platdrv.c i2c-designware-master.c \
         i2c-designware-baytrail.c i2c-designware-amdpsp.c i2c-designware-core.h; do
    [[ -f "$SRC_ORIG/$f" ]] && cp "$SRC_ORIG/$f" "$BUILD_DIR/"
done
log_ok "Оригиналы скопированы"

# ===== 3. эталонный amdpsp.c (с учётом BIOS-карты) =====
log_info "Запись эталонного amdpsp.c..."
cat > "$BUILD_DIR/i2c-designware-amdpsp.c" <<'AMDPSP_EOF'
// SPDX-License-Identifier: GPL-2.0
#include <asm/msr.h>
#include <linux/psp-platform-access.h>
#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/i2c.h>
#include <linux/io-64-nonatomic-lo-hi.h>
#include <linux/psp-sev.h>
#include <linux/types.h>
#include <linux/workqueue.h>
#include <linux/delay.h>
#include "i2c-designware-core.h"

#define MSR_AMD_PSP_ADDR		0xc00110a2
#define PSP_MBOX_OFFSET			0x10570
#define PSP_CMD_TIMEOUT_US		(3000 * USEC_PER_MSEC)
#define PSP_I2C_RESERVATION_TIME_MS	2500
#define PSP_I2C_REQ_BUS_CMD		0x64
#define PSP_I2C_REQ_RETRY_CNT		6000
#define PSP_I2C_REQ_RETRY_DELAY_US	(15 * USEC_PER_MSEC)
#define PSP_I2C_REQ_STS_OK		0x0
#define PSP_I2C_REQ_STS_BUS_BUSY	0x1
#define PSP_I2C_REQ_STS_INV_PARAM	0x3
#define PSP_MBOX_FIELDS_STS		GENMASK(15, 0)
#define PSP_MBOX_FIELDS_CMD		GENMASK(23, 16)
#define PSP_MBOX_FIELDS_RECOVERY	BIT(30)
#define PSP_MBOX_FIELDS_READY		BIT(31)

#ifndef __psp_pa
#define __psp_pa(x)			__pa(x)
#endif

struct local_psp_req_buffer { u32 total_size; u32 status; };
enum psp_i2c_req_type { PSP_I2C_REQ_ACQUIRE, PSP_I2C_REQ_RELEASE };
struct psp_i2c_req { struct local_psp_req_buffer hdr; enum psp_i2c_req_type type; };
struct psp_mbox { u32 cmd_fields; u64 i2c_req_addr; } __packed;

static DEFINE_MUTEX(psp_i2c_access_mutex);
static unsigned long psp_i2c_sem_acquired;
static void __iomem *mbox_iomem;
static u32 psp_i2c_access_count;
static bool psp_i2c_mbox_fail;
static struct device *psp_i2c_dev;

static int psp_check_mbox_recovery(struct psp_mbox __iomem *mbox)
{ return FIELD_GET(PSP_MBOX_FIELDS_RECOVERY, readl(&mbox->cmd_fields)); }

static int psp_mbox_probe(void)
{
	unsigned long long psp_mmio = 0;
	unsigned long mbox_addr;
	int retries, msr_try;
	msleep(3000);
	for (msr_try = 0; msr_try < 5; msr_try++) {
		if (!rdmsrq_safe(MSR_AMD_PSP_ADDR, &psp_mmio)) break;
		msleep(200);
	}
	if (msr_try >= 5) {
		dev_warn(psp_i2c_dev, "PSP MSR unavailable, degrade to exclusive-host\n");
		return -ENODEV;
	}
	mbox_addr = (unsigned long)(psp_mmio + PSP_MBOX_OFFSET);
	mbox_iomem = ioremap(mbox_addr, sizeof(struct psp_mbox));
	if (!mbox_iomem) return -ENOMEM;
	for (retries = 0; retries < 300; retries++) {
		if (!psp_check_mbox_recovery(mbox_iomem)) {
			dev_info(psp_i2c_dev, "PSP mailbox ready after %d retries\n", retries);
			return 0;
		}
		msleep(20);
	}
	dev_err(psp_i2c_dev, "PSP mailbox failed to become ready\n");
	return -ENODEV;
}

static int psp_wait_cmd(struct psp_mbox __iomem *mbox)
{ u32 tmp, e = FIELD_PREP(PSP_MBOX_FIELDS_READY, 1);
  return readl_poll_timeout(&mbox->cmd_fields, tmp, tmp == e, 0, PSP_CMD_TIMEOUT_US); }
static u32 psp_check_mbox_sts(struct psp_mbox __iomem *mbox)
{ return FIELD_GET(PSP_MBOX_FIELDS_STS, readl(&mbox->cmd_fields)); }

static int psp_send_cmd(struct psp_i2c_req *req)
{
	struct psp_mbox __iomem *mbox = mbox_iomem; phys_addr_t ra; u32 c;
	if (psp_check_mbox_recovery(mbox)) return -EIO;
	if (psp_wait_cmd(mbox)) return -EBUSY;
	ra = __psp_pa((void *)req); writeq(ra, &mbox->i2c_req_addr);
	c = FIELD_PREP(PSP_MBOX_FIELDS_CMD, PSP_I2C_REQ_BUS_CMD); writel(c, &mbox->cmd_fields);
	if (psp_wait_cmd(mbox)) return -ETIMEDOUT;
	if (psp_check_mbox_sts(mbox)) return -EIO;
	return 0;
}
static int check_i2c_req_sts(struct psp_i2c_req *req)
{ u32 s = READ_ONCE(req->hdr.status);
  if (s == PSP_I2C_REQ_STS_OK) return 0;
  if (s == PSP_I2C_REQ_STS_BUS_BUSY) return -EBUSY;
  return -EIO; }
static int psp_send_i2c_req(enum psp_i2c_req_type type)
{
	struct psp_i2c_req *req = kzalloc(sizeof(*req), GFP_KERNEL); int ret;
	if (!req) return -ENOMEM;
	req->hdr.total_size = sizeof(*req); req->type = type;
	ret = read_poll_timeout(psp_send_cmd, ret, ret != -EBUSY,
		PSP_I2C_REQ_RETRY_DELAY_US, PSP_I2C_REQ_RETRY_CNT * PSP_I2C_REQ_RETRY_DELAY_US, 0, req);
	if (!ret) ret = check_i2c_req_sts(req);
	if (ret == -EIO) psp_i2c_mbox_fail = true;
	kfree(req); return ret;
}
static void release_bus(void)
{ if (psp_i2c_sem_acquired) psp_send_i2c_req(PSP_I2C_REQ_RELEASE); psp_i2c_sem_acquired = 0; }
static void psp_release_i2c_bus_deferred(struct work_struct *w)
{ mutex_lock(&psp_i2c_access_mutex); if (psp_i2c_access_count == 0) release_bus(); mutex_unlock(&psp_i2c_access_mutex); }
static DECLARE_DELAYED_WORK(release_queue, psp_release_i2c_bus_deferred);

static int psp_acquire_i2c_bus(void)
{
	int ret;
	mutex_lock(&psp_i2c_access_mutex);
	if (psp_i2c_mbox_fail) { mutex_unlock(&psp_i2c_access_mutex); return 0; }
	psp_i2c_access_count++;
	if (!psp_i2c_sem_acquired) {
		ret = psp_send_i2c_req(PSP_I2C_REQ_ACQUIRE);
		if (ret) { psp_i2c_access_count--; mutex_unlock(&psp_i2c_access_mutex); return ret; }
		psp_i2c_sem_acquired = jiffies;
	}
	mutex_unlock(&psp_i2c_access_mutex);
	return 0;
}
static void psp_release_i2c_bus(void)
{
	mutex_lock(&psp_i2c_access_mutex);
	if (psp_i2c_access_count) psp_i2c_access_count--;
	if (!psp_i2c_mbox_fail && psp_i2c_access_count == 0 && psp_i2c_sem_acquired)
		release_bus();
	mutex_unlock(&psp_i2c_access_mutex);
}

static void i2c_adapter_dw_psp_lock_bus(struct i2c_adapter *a, unsigned int f)
{ psp_acquire_i2c_bus(); rt_mutex_lock_nested(&a->bus_lock, i2c_adapter_depth(a)); }
static int i2c_adapter_dw_psp_trylock_bus(struct i2c_adapter *a, unsigned int f)
{ int r = rt_mutex_trylock(&a->bus_lock); if (r) psp_acquire_i2c_bus(); return r; }
static void i2c_adapter_dw_psp_unlock_bus(struct i2c_adapter *a, unsigned int f)
{ psp_release_i2c_bus(); rt_mutex_unlock(&a->bus_lock); }
static const struct i2c_lock_operations i2c_dw_psp_lock_ops = {
	.lock_bus = i2c_adapter_dw_psp_lock_bus,
	.trylock_bus = i2c_adapter_dw_psp_trylock_bus,
	.unlock_bus = i2c_adapter_dw_psp_unlock_bus,
};

int i2c_dw_amdpsp_probe_lock_support(struct dw_i2c_dev *dev)
{
	int ret;
	if (!dev || !(dev->flags & ARBITRATION_SEMAPHORE)) return -ENODEV;
	if (psp_i2c_dev) return -EEXIST;
	psp_i2c_dev = dev->dev;
	ret = psp_mbox_probe(); if (ret) return ret;
	dev_info(dev->dev, "AMD PSP I2C semaphore enabled (BIOS-aligned)\n");
	dev->adapter.lock_ops = &i2c_dw_psp_lock_ops;
	dev->acquire_lock = psp_acquire_i2c_bus;
	dev->release_lock = psp_release_i2c_bus;
	return 0;
}
void i2c_dw_amdpsp_remove_lock_support(struct dw_i2c_dev *dev)
{ if (mbox_iomem) iounmap(mbox_iomem); }
AMDPSP_EOF
log_ok "amdpsp.c записан"

# ===== 4. точечные правки platdrv / common / core =====
log_info "Точечные правки platdrv / common / core..."
python3 - <<'PYEOF'
import re, os
B='/usr/src/steamdeck-i2c-fix-1.0/'
def rd(p): return open(B+p).read()
def wr(p,s): open(B+p,'w').write(s)

# ---- platdrv.c ----
p='i2c-designware-platdrv.c'; t=rd(p); log=[]
# имя драйвера
if '"dw_i2c"' in t:
    t=t.replace('.name = "dw_i2c"','.name = "i2c_designware_pspfix"'); log.append('имя->pspfix')
elif '"i2c_designware"' in t and 'pspfix' not in t:
    t=t.replace('.name = "i2c_designware"','.name = "i2c_designware_pspfix"'); log.append('имя->pspfix(alt)')
# флаг AMDI0010
lines=t.split('\n')
for i,l in enumerate(lines):
    if 'AMDI0010' in l and 'ARBITRATION_SEMAPHORE' not in l and 'ACCESS_INTR_MASK' in l:
        lines[i]=l.replace('ACCESS_INTR_MASK','ACCESS_INTR_MASK | ARBITRATION_SEMAPHORE',1)
        log.append('флаг AMDI0010'); break
t='\n'.join(lines)
# снять ifdef AMDPSP
if '#ifdef CONFIG_I2C_DESIGNWARE_AMDPSP' in t:
    lines=t.split('\n'); out=[]; i=0; cut=0
    while i<len(lines):
        s=lines[i].strip()
        if s.startswith('#ifdef CONFIG_I2C_DESIGNWARE_AMDPSP') or s.startswith('#if defined(CONFIG_I2C_DESIGNWARE_AMDPSP)'):
            k=i+1; nest=0; end=None
            while k<len(lines):
                tk=lines[k].strip()
                if tk.startswith('#if'): nest+=1
                elif tk.startswith('#endif'):
                    if nest==0: end=k; break
                    nest-=1
                k+=1
            if end is not None:
                out.extend(lines[i+1:end]); cut+=1; i=end+1; continue
        out.append(lines[i]); i+=1
    t='\n'.join(out); log.append(f'ifdef AMDPSP снят ({cut})')
# вычистить спам msleep в probe
lines=[l for l in t.split('\n') if not re.search(r'^\s*msleep\((200|800|1200|1500)\)\s*;',l)
       and not re.match(r'\s*/?\*.*(PSP|delay|stabil|init).*\*/\s*$',l,re.I)]
t='\n'.join(lines); log.append('msleep-спам вычищен')
# ABI-баги
t=t.replace('static int dw_i2c_plat_prepare(struct device dev)','static int dw_i2c_plat_prepare(struct device *dev)')
t=re.sub(r'\.remove\s*=\s*\(void \(\*\)\(struct platform_device \*\)\)\s*dw_i2c_plat_remove\s*,','.remove = dw_i2c_plat_remove,',t)
# int -> void для remove
t=re.sub(r'^static int dw_i2c_plat_remove\(struct platform_device \*pdev\)','static void dw_i2c_plat_remove(struct platform_device *pdev)',t,flags=re.M)
t=re.sub(r'(static void dw_i2c_plat_remove\([^}]*?)\s*return 0;\s*(\})',r'\1\2',t,flags=re.S)
wr(p,t); print('[platdrv]', ', '.join(log) or 'уже ок')

# ---- common.c ----
p='i2c-designware-common.c'; t=rd(p); log=[]
if 'i2c_dw_clk_rate(struct dw_i2c_dev dev)' in t:
    t=t.replace('i2c_dw_clk_rate(struct dw_i2c_dev dev)','i2c_dw_clk_rate(struct dw_i2c_dev *dev)'); log.append('clk_rate *dev')
n=len([l for l in t.splitlines() if 'EXPORT_SYMBOL' in l])
if n:
    t='\n'.join(l for l in t.splitlines() if 'EXPORT_SYMBOL' not in l); log.append(f'exports вырезаны ({n})')
wr(p,t); print('[common]', ', '.join(log) or 'уже ок')

# ---- core.h ----
p='i2c-designware-core.h'; t=rd(p)
if '#if IS_ENABLED(CONFIG_I2C_DESIGNWARE_AMDPSP)' in t:
    t=t.replace('#if IS_ENABLED(CONFIG_I2C_DESIGNWARE_AMDPSP)','#if 1'); wr(p,t); print('[core.h] прототипы AMDPSP включены')
else: print('[core.h] уже ок')
PYEOF

# ===== 5. Kbuild / Makefile =====
log_info "Kbuild / Makefile..."
cat > "$BUILD_DIR/Kbuild" <<EOF
obj-m += ${MOD}.o
${MOD}-y := i2c-designware-common.o \\
           i2c-designware-platdrv.o \\
           i2c-designware-master.o \\
           i2c-designware-baytrail.o \\
           i2c-designware-amdpsp.o
EOF
cat > "$BUILD_DIR/Makefile" <<'EOF'
KDIR := /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF
cat > "$BUILD_DIR/dkms.conf" <<EOF
PACKAGE_NAME="steamdeck-i2c-fix"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="${MOD}"
DEST_MODULE_LOCATION[0]="/kernel/drivers/i2c/busses/"
AUTOINSTALL="yes"
OVERRIDE="yes"
MAKE[0]="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN[0]="make -C /lib/modules/\${kernelver}/build M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
EOF
log_ok "Kbuild / Makefile / dkms.conf созданы"

# ===== 6. сборка =====
log_info "Сборка модуля..."
cd "$BUILD_DIR"
rm -f *.o *.ko *.mod *.mod.c Module.symvers modules.order .*.cmd 2>/dev/null || true
make -C "/lib/modules/$(uname -r)/build" M="$PWD" modules
[[ -f "${MOD}.ko" ]] || { log_err "Сборка не удалась"; exit 1; }
log_ok "Модуль собран: ${MOD}.ko"

# ===== 7. DKMS установка =====
log_info "Установка через DKMS..."
# убрать ручной экземпляр если есть
rm -f "/usr/lib/modules/$(uname -r)/extra/${MOD}.ko"
dkms remove steamdeck-i2c-fix/1.0 --all 2>/dev/null || true
dkms add "$BUILD_DIR"
dkms build steamdeck-i2c-fix/1.0
dkms install steamdeck-i2c-fix/1.0 --force
log_ok "DKMS установлен"

# ===== 8. systemd-юнит I2C =====
log_info "Создание systemd-юнита I2C..."
cat > /etc/systemd/system/steamdeck-i2c-pspfix.service <<EOF
[Unit]
Description=Steam Deck I2C PSP semaphore shadow driver (BIOS-timed warm-up)
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo $DEV > /sys/bus/platform/drivers/$DRV_BUILTIN/unbind 2>/dev/null || true'
ExecStart=/sbin/modprobe $MOD
ExecStart=/bin/sh -c '[ "${REBIND:-yes}" = yes ] && sleep $WARMUP_SEC || true'
ExecStart=/bin/sh -c '[ "${REBIND:-yes}" = yes ] && echo $DEV > /sys/bus/platform/drivers/$DRV_OURS/unbind 2>/dev/null || true'
ExecStart=/bin/sh -c '[ "${REBIND:-yes}" = yes ] && echo $DEV > /sys/bus/platform/drivers/$DRV_OURS/bind 2>/dev/null || true'
ExecStop=/bin/sh -c 'echo $DEV > /sys/bus/platform/drivers/$DRV_OURS/unbind 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now steamdeck-i2c-pspfix.service
log_ok "Юнит I2C создан и включён"

# ===== 9. демон кулера v2 =====
log_info "Установка демона кулера v2..."
cat > /usr/local/bin/steamdeck-fan.sh <<'FANEOF'
#!/usr/bin/env bash
# steamdeck-fan.sh v2 — агрессивный, но подшипнико-щадящий контроллер кулера SoC.
# Режимы: rpm (fan1_target) | pwm (pwm1) | state (cooling_device cur_state).
# Путь и пороги переопределяются через /etc/default/steamdeck-fan.
set -uo pipefail

FAN_SYSFS="${FAN_SYSFS:-}"
TEMP_SYSFS="${TEMP_SYSFS:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
T_LOW="${T_LOW:-55}"; T_HIGH="${T_HIGH:-79}"; HYST="${HYST:-3}"
RPM_LO="${RPM_LO:-5000}"; RPM_MID="${RPM_MID:-6500}"; RPM_HI="${RPM_HI:-7300}"
PWM_LO="${PWM_LO:-80}";  PWM_MID="${PWM_MID:-150}";  PWM_HI="${PWM_HI:-255}"
RAMP_STEP="${RAMP_STEP:-400}"
INTERVAL="${INTERVAL:-3}"
CPU_TYPES="${CPU_TYPES:-k10temp zenpower cpu-thermal acpitz soc_thermal amd_energy}"

log(){ echo "fanctl: $*" >&2; }

pick_temp(){
    if [ -n "$TEMP_SYSFS" ]; then [ -r "$TEMP_SYSFS" ] && { echo "$TEMP_SYSFS"; return 0; }; return 1; fi
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] || continue
        t="$(cat "$z/type" 2>/dev/null)"
        for w in $CPU_TYPES; do [ "$t" = "$w" ] && { echo "$z/temp"; return 0; }; done
    done
    [ -r /sys/class/thermal/thermal_zone0/temp ] && { echo /sys/class/thermal/thermal_zone0/temp; return 0; }
    return 1
}

pick_fan(){
    if [ -n "$FAN_SYSFS" ]; then
        case "$FAN_SYSFS" in
            */cur_state) [ -w "$FAN_SYSFS" ] && { printf 'state\t%s\n' "$FAN_SYSFS"; return 0; };;
            *pwm*)       [ -w "$FAN_SYSFS" ] && { printf 'pwm\t%s\n'   "$FAN_SYSFS"; return 0; };;
            *fan*target) [ -w "$FAN_SYSFS" ] && { printf 'rpm\t%s\n'   "$FAN_SYSFS"; return 0; };;
            *)           [ -w "$FAN_SYSFS" ] && { printf 'rpm\t%s\n'   "$FAN_SYSFS"; return 0; };;
        esac
        return 1
    fi
    for h in /sys/class/hwmon/hwmon*; do [ -w "$h/fan1_target" ] && { printf 'rpm\t%s\n' "$h/fan1_target"; return 0; }; done
    for h in /sys/class/hwmon/hwmon*; do [ -w "$h/pwm1" ] && { printf 'pwm\t%s\n' "$h/pwm1"; return 0; }; done
    for c in /sys/class/thermal/cooling_device*; do
        [ -w "$c/cur_state" ] || continue
        ct="$(cat "$c/type" 2>/dev/null)"
        case "$ct" in *[Ff]an*) printf 'state\t%s\n' "$c/cur_state"; return 0;; esac
    done
    for c in /sys/class/thermal/cooling_device*; do [ -w "$c/cur_state" ] && { printf 'state\t%s\n' "$c/cur_state"; return 0; }; done
    return 1
}

TEMP_FILE=""; FAN_FILE=""; MODE=""
i=0
while :; do
    [ -z "$TEMP_FILE" ] && TEMP_FILE="$(pick_temp || true)"
    if [ -z "$FAN_FILE" ]; then
        sel="$(pick_fan || true)"
        [ -n "$sel" ] && { MODE="${sel%%$'\t'*}"; FAN_FILE="${sel#*$'\t'}"; }
    fi
    [ -n "$TEMP_FILE" ] && [ -n "$FAN_FILE" ] && break
    i=$((i+1))
    [ "$i" -ge "$WAIT_TIMEOUT" ] && { log "err: узел не появился за ${WAIT_TIMEOUT}s"; exit 1; }
    sleep 1
done

STATE_MAX=0
if [ "$MODE" = state ]; then
    cd_dir="$(dirname "$FAN_FILE")"
    STATE_MAX="$(cat "$cd_dir/max_state" 2>/dev/null || echo 0)"
    [ "$STATE_MAX" -lt 1 ] && { log "err: max_state<1"; exit 1; }
    RAMP_STEP=1
fi
[ "$MODE" = pwm ] && RAMP_STEP=20

log "temp=$TEMP_FILE fan=$FAN_FILE mode=$MODE state_max=$STATE_MAX"

write_fan(){ printf '%s' "$1" > "$FAN_FILE" 2>/dev/null; }

case "$MODE" in
    rpm)   LVL_LO=$RPM_LO;  LVL_MID=$RPM_MID;  LVL_HI=$RPM_HI;;
    pwm)   LVL_LO=$PWM_LO;  LVL_MID=$PWM_MID;  LVL_HI=$PWM_HI;;
    state) LVL_LO=0;        LVL_MID=$((STATE_MAX/2)); LVL_HI=$STATE_MAX;;
esac

CUR=$LVL_LO
if [ "$MODE" = rpm ]; then
    inp="${FAN_FILE%_target}_input"
    [ -r "$inp" ] && { v="$(cat "$inp" 2>/dev/null||echo 0)"; case "$v" in *[!0-9]*|'') v=0;; esac; [ "$v" -ge 1000 ] && CUR=$v; }
fi
write_fan "$CUR" || log "warn: первая запись не удалась"

while :; do
    raw="$(cat "$TEMP_FILE" 2>/dev/null || echo '')"
    case "$raw" in ''|*[!0-9]*) sleep "$INTERVAL"; continue;; esac
    T=$(( raw / 1000 ))
    if   [ "$T" -le "$T_LOW"  ]; then DES=$LVL_LO
    elif [ "$T" -le "$T_HIGH" ]; then DES=$LVL_MID
    else DES=$LVL_HI; fi
    if [ "$DES" -lt "$CUR" ]; then
        case "$DES" in
            "$LVL_LO")  [ "$T" -gt $((T_LOW  - HYST)) ] && DES=$CUR;;
            "$LVL_MID") [ "$T" -gt $((T_HIGH - HYST)) ] && DES=$CUR;;
        esac
    fi
    if [ "$RAMP_STEP" -gt 0 ] && [ "$DES" -ne "$LVL_HI" ]; then
        diff=$(( DES - CUR )); adiff=${diff#-}
        if [ "$adiff" -gt "$RAMP_STEP" ]; then
            if [ "$diff" -gt 0 ]; then DES=$(( CUR + RAMP_STEP )); else DES=$(( CUR - RAMP_STEP )); fi
        fi
    fi
    [ "$DES" != "$CUR" ] && { write_fan "$DES" && CUR=$DES || log "warn: запись $DES не удалась"; }
    sleep "$INTERVAL"
done
FANEOF
chmod +x /usr/local/bin/steamdeck-fan.sh
log_ok "Демон кулера установлен"

# ===== 10. override + юнит кулера =====
log_info "Override + юнит кулера..."
cat > /etc/default/steamdeck-fan <<EOF
# Точный путь к вентилятору (steamdeck_hwmon)
FAN_SYSFS=/sys/class/hwmon/${FAN_HW}/fan1_target
# Температура CPU Zen (точнее, чем acpitz)
TEMP_SYSFS=/sys/class/hwmon/${TEMP_HW}/temp1_input
# Пороги и уровни
T_LOW=55
T_HIGH=79
HYST=3
RPM_LO=5000
RPM_MID=6500
RPM_HI=7300
RAMP_STEP=400
INTERVAL=3
EOF

cat > /etc/systemd/system/steamdeck-fan.service <<'EOF'
[Unit]
Description=Steam Deck aggressive-but-bearing-friendly SoC fan controller (v2)
After=systemd-modules-load.service systemd-udev-settle.service
Wants=systemd-modules-load.service
ConditionPathExists=/sys/class/hwmon/hwmon6/fan1_target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-/etc/default/steamdeck-fan
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/steamdeck-fan.sh
Restart=on-failure
RestartSec=10
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now steamdeck-fan.service
log_ok "Юнит кулера создан и включён"

# ===== 11. итог =====
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  ВСЁ УСТАНОВЛЕНО!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Проверка I2C:"
echo "  sudo dmesg | grep -E 'PSP|opt3001|lost arbitration|i2c_designware_pspfix' | tail -20"
echo "  systemctl status steamdeck-i2c-pspfix.service --no-pager"
echo ""
echo "Проверка кулера:"
echo "  sudo journalctl -u steamdeck-fan.service -n 10 --no-pager"
echo "  watch -n 1 'echo \"CPU: \$(( \$(cat /sys/class/hwmon/${TEMP_HW}/temp1_input) / 1000 ))°C  Fan: \$(cat /sys/class/hwmon/${FAN_HW}/fan1_input) RPM  Target: \$(cat /sys/class/hwmon/${FAN_HW}/fan1_target) RPM\"'"
echo ""
echo "Откат I2C:  sudo systemctl disable --now steamdeck-i2c-pspfix.service && sudo dkms remove steamdeck-i2c-fix/1.0 --all"
echo "Откат кулера: sudo systemctl disable --now steamdeck-fan.service"