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

/* ядро 7.x мог вынести __psp_pa из заголовков - локальный guard */
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
{
	return FIELD_GET(PSP_MBOX_FIELDS_RECOVERY, readl(&mbox->cmd_fields));
}

static int psp_mbox_probe(void)
{
	unsigned long long psp_mmio = 0;
	unsigned long mbox_addr;
	int retries, msr_try;

	msleep(3000);	/* страховка для раннего старта; при systemd-позднем почти не работает */

	/* FUN_00b138dc: MSR-блокировка ВРЕМЕННАЯ -> ретраим, не убиваем probe */
	for (msr_try = 0; msr_try < 5; msr_try++) {
		if (!rdmsrq_safe(MSR_AMD_PSP_ADDR, &psp_mmio))
			break;
		msleep(200);
	}
	if (msr_try >= 5) {
		dev_warn(psp_i2c_dev, "PSP MSR unavailable, degrade to exclusive-host\n");
		return -ENODEV;	/* graceful, НЕ -EIO */
	}

	mbox_addr = (unsigned long)(psp_mmio + PSP_MBOX_OFFSET);
	mbox_iomem = ioremap(mbox_addr, sizeof(struct psp_mbox));
	if (!mbox_iomem)
		return -ENOMEM;

	for (retries = 0; retries < 300; retries++) {
		if (!psp_check_mbox_recovery(mbox_iomem)) {
			dev_info(psp_i2c_dev, "PSP mailbox ready after %d retries\n", retries);
			return 0;
		}
		msleep(20);
	}
	dev_err(psp_i2c_dev, "PSP mailbox failed to become ready\n");
	return -ENODEV;		/* тоже деградация, не смерть адаптера */
}

static int psp_wait_cmd(struct psp_mbox __iomem *mbox)
{
	u32 tmp, e = FIELD_PREP(PSP_MBOX_FIELDS_READY, 1);
	return readl_poll_timeout(&mbox->cmd_fields, tmp, tmp == e, 0, PSP_CMD_TIMEOUT_US);
}
static u32 psp_check_mbox_sts(struct psp_mbox __iomem *mbox)
{
	return FIELD_GET(PSP_MBOX_FIELDS_STS, readl(&mbox->cmd_fields));
}

static int psp_send_cmd(struct psp_i2c_req *req)
{
	struct psp_mbox __iomem *mbox = mbox_iomem;
	phys_addr_t ra; u32 c;

	if (psp_check_mbox_recovery(mbox)) return -EIO;
	if (psp_wait_cmd(mbox)) return -EBUSY;
	ra = __psp_pa((void *)req); writeq(ra, &mbox->i2c_req_addr);
	c = FIELD_PREP(PSP_MBOX_FIELDS_CMD, PSP_I2C_REQ_BUS_CMD); writel(c, &mbox->cmd_fields);
	if (psp_wait_cmd(mbox)) return -ETIMEDOUT;
	if (psp_check_mbox_sts(mbox)) return -EIO;
	return 0;
}
static int check_i2c_req_sts(struct psp_i2c_req *req)
{
	u32 s = READ_ONCE(req->hdr.status);
	if (s == PSP_I2C_REQ_STS_OK) return 0;
	if (s == PSP_I2C_REQ_STS_BUS_BUSY) return -EBUSY;
	return -EIO;
}
static int psp_send_i2c_req(enum psp_i2c_req_type type)
{
	struct psp_i2c_req *req = kzalloc(sizeof(*req), GFP_KERNEL);
	int ret;
	if (!req) return -ENOMEM;
	req->hdr.total_size = sizeof(*req); req->type = type;
	ret = read_poll_timeout(psp_send_cmd, ret, ret != -EBUSY,
		PSP_I2C_REQ_RETRY_DELAY_US,
		PSP_I2C_REQ_RETRY_CNT * PSP_I2C_REQ_RETRY_DELAY_US, 0, req);
	if (!ret) ret = check_i2c_req_sts(req);
	if (ret == -EIO) psp_i2c_mbox_fail = true;   /* ТОЛЬКО реальный сбой протокола */
	kfree(req);
	return ret;
}
static void release_bus(void)
{
	if (psp_i2c_sem_acquired) psp_send_i2c_req(PSP_I2C_REQ_RELEASE);
	psp_i2c_sem_acquired = 0;
}
static void psp_release_i2c_bus_deferred(struct work_struct *w)
{
	mutex_lock(&psp_i2c_access_mutex);
	if (psp_i2c_access_count == 0) release_bus();
	mutex_unlock(&psp_i2c_access_mutex);
}
static DECLARE_DELAYED_WORK(release_queue, psp_release_i2c_bus_deferred);

static int psp_acquire_i2c_bus(void)
{
	int ret;
	mutex_lock(&psp_i2c_access_mutex);
	if (psp_i2c_mbox_fail) { mutex_unlock(&psp_i2c_access_mutex); return 0; }
	psp_i2c_access_count++;
	if (!psp_i2c_sem_acquired) {
		ret = psp_send_i2c_req(PSP_I2C_REQ_ACQUIRE);
		if (ret) {				/* FUN_012af078: сосед занят -> НЕ верим на слово */
			psp_i2c_access_count--;
			mutex_unlock(&psp_i2c_access_mutex);
			return ret;			/* прервём транзакцию ДО физ. выхода на шину */
		}
		psp_i2c_sem_acquired = jiffies;
	}
	mutex_unlock(&psp_i2c_access_mutex);
	return 0;
}
static void psp_release_i2c_bus(void)
{
	mutex_lock(&psp_i2c_access_mutex);
	if (psp_i2c_access_count) psp_i2c_access_count--;   /* защита от ухода в минус */
	if (!psp_i2c_mbox_fail && psp_i2c_access_count == 0 && psp_i2c_sem_acquired)
		release_bus();
	mutex_unlock(&psp_i2c_access_mutex);
}

/* честные обёртки под i2c_lock_operations - никаких UB-кастов */
static void i2c_adapter_dw_psp_lock_bus(struct i2c_adapter *a, unsigned int f)
{
	psp_acquire_i2c_bus();
	rt_mutex_lock_nested(&a->bus_lock, i2c_adapter_depth(a));
}
static int i2c_adapter_dw_psp_trylock_bus(struct i2c_adapter *a, unsigned int f)
{
	int r = rt_mutex_trylock(&a->bus_lock);
	if (r) psp_acquire_i2c_bus();
	return r;
}
static void i2c_adapter_dw_psp_unlock_bus(struct i2c_adapter *a, unsigned int f)
{
	psp_release_i2c_bus();
	rt_mutex_unlock(&a->bus_lock);
}
static const struct i2c_lock_operations i2c_dw_psp_lock_ops = {
	.lock_bus    = i2c_adapter_dw_psp_lock_bus,
	.trylock_bus = i2c_adapter_dw_psp_trylock_bus,
	.unlock_bus  = i2c_adapter_dw_psp_unlock_bus,
};

int i2c_dw_amdpsp_probe_lock_support(struct dw_i2c_dev *dev)
{
	int ret;
	if (!dev || !(dev->flags & ARBITRATION_SEMAPHORE)) return -ENODEV;
	if (psp_i2c_dev) return -EEXIST;
	psp_i2c_dev = dev->dev;
	ret = psp_mbox_probe();
	if (ret) return ret;
	dev_info(dev->dev, "AMD PSP I2C semaphore enabled (BIOS-aligned)\n");
	dev->adapter.lock_ops = &i2c_dw_psp_lock_ops;
	dev->acquire_lock = psp_acquire_i2c_bus;
	dev->release_lock = psp_release_i2c_bus;
	return 0;
}
void i2c_dw_amdpsp_remove_lock_support(struct dw_i2c_dev *dev)
{
	if (mbox_iomem) iounmap(mbox_iomem);
}
