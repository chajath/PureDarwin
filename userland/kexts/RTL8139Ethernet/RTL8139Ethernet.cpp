/*
 * RTL8139Ethernet.cpp — Minimal RTL8139 IOKit Ethernet Driver for PureDarwin
 *
 * Implements basic Tx/Rx for QEMU's RTL8139 emulation.
 * No advanced features (VLAN, WoL, jumbo frames, etc.)
 */

#include "RTL8139Ethernet.h"
#include <IOKit/IOMemoryDescriptor.h>
#include <mach/kmod.h>

// Declare kmod_info — required for the kernel to load the kext
extern "C" {
    extern kern_return_t _start(kmod_info_t *ki, void *data);
    extern kern_return_t _stop(kmod_info_t *ki, void *data);
}
KMOD_EXPLICIT_DECL(org.puredarwin.driver.RTL8139Ethernet, "1.0.0", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t  *_antimain = 0;

#define super IOEthernetController
OSDefineMetaClassAndStructors(RTL8139Ethernet, IOEthernetController)

#define DLOG(fmt, ...) IOLog("RTL8139: " fmt "\n", ##__VA_ARGS__)

/* 32-bit physical address mask for RTL8139 DMA */
#define DMA_MASK_32BIT  0x00000000FFFFFFFFULL

// ---------------------------------------------------------------------------
// IOService overrides
// ---------------------------------------------------------------------------

bool RTL8139Ethernet::init(OSDictionary *properties)
{
    if (!super::init(properties))
        return false;

    fPCIDevice = NULL;
    fRegMap = NULL;
    fRegBase = NULL;
    fIOBar = 0;
    fUseIO = false;
    fInterruptSrc = NULL;
    fNetIf = NULL;
    fTxQueue = NULL;
    fRxBufDesc = NULL;
    fRxBuf = NULL;
    fCurTx = 0;
    fDirtyTx = 0;
    fEnabled = false;
    fNetStats = NULL;
    fEthStats = NULL;
    fRxBufPhys = 0;
    fRxOffset = 0;
    fWorkLoop = NULL;

    for (int i = 0; i < NUM_TX_DESC; i++) {
        fTxBufDesc[i] = NULL;
        fTxBuf[i] = NULL;
        fTxBufPhys[i] = 0;
    }

    return true;
}

bool RTL8139Ethernet::start(IOService *provider)
{
    DLOG("start() entry");

    if (!super::start(provider)) {
        DLOG("super::start failed");
        return false;
    }

    fPCIDevice = OSDynamicCast(IOPCIDevice, provider);
    if (!fPCIDevice) {
        DLOG("Provider is not an IOPCIDevice");
        goto fail;
    }

    fPCIDevice->retain();
    fPCIDevice->open(this);

    /* Enable PCI bus mastering and memory space */
    fPCIDevice->setBusMasterEnable(true);
    fPCIDevice->setMemoryEnable(true);
    fPCIDevice->setIOEnable(true);

    /*
     * RTL8139 register space lives in one of two BARs:
     *   BAR1 = memory MMIO   (present on -C variants, what QEMU's
     *                         -device rtl8139 may or may not expose)
     *   BAR0 = PCI I/O ports (always present)
     *
     * mapDeviceMemoryWithRegister on an I/O-space BAR returns a map
     * with length 0 that page-faults on first access, so for BAR0 we
     * must use the IOPCIDevice ioRead*/ /*ioWrite* helpers directly.
     */
    fRegMap = fPCIDevice->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
    if (fRegMap && fRegMap->getLength() > 0) {
        fRegBase = (volatile UInt8 *)fRegMap->getVirtualAddress();
        fUseIO = false;
        fIOBar = kIOPCIConfigBaseAddress1;
        DLOG("Using MMIO via BAR1: virt=%p len=%llu",
             fRegBase, (unsigned long long)fRegMap->getLength());
    } else {
        if (fRegMap) { fRegMap->release(); fRegMap = NULL; }
        /*
         * Fall back to PCI I/O ports on BAR0. We still need the
         * IOMemoryMap so ioRead*/ /*ioWrite* know which port range to
         * target; on an I/O-space BAR the map has length 0 but it
         * carries the BAR's port base.
         */
        fRegMap = fPCIDevice->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
        if (!fRegMap) {
            DLOG("BAR0 map failed; no register access path available");
            goto fail;
        }
        fUseIO = true;
        fIOBar = kIOPCIConfigBaseAddress0;
        UInt8 probe = fPCIDevice->ioRead8(0x43, fRegMap);
        if (probe == 0xFF) {
            DLOG("PCI I/O port probe at BAR0+0x43 returned 0xFF; abort");
            goto fail;
        }
        DLOG("Using PCI I/O ports via BAR0 (probe=0x%02x, map base=0x%llx len=%llu)",
             probe,
             (unsigned long long)fRegMap->getPhysicalAddress(),
             (unsigned long long)fRegMap->getLength());
    }

    /* Reset the chip */
    resetAdapter();

    /* Read MAC address */
    for (int i = 0; i < 6; i++)
        fMacAddr.bytes[i] = readReg8(RTL_IDR0 + i);

    DLOG("MAC: %02x:%02x:%02x:%02x:%02x:%02x",
         fMacAddr.bytes[0], fMacAddr.bytes[1], fMacAddr.bytes[2],
         fMacAddr.bytes[3], fMacAddr.bytes[4], fMacAddr.bytes[5]);

    /* Allocate Rx buffer with 32-bit physical address constraint */
    fRxBufDesc = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous,
        RX_BUF_TOTAL, DMA_MASK_32BIT);
    if (!fRxBufDesc) {
        DLOG("Failed to allocate Rx buffer");
        goto fail;
    }
    fRxBufDesc->prepare();
    fRxBuf = (UInt8 *)fRxBufDesc->getBytesNoCopy();
    fRxBufPhys = fRxBufDesc->getPhysicalAddress();
    memset(fRxBuf, 0, RX_BUF_TOTAL);
    DLOG("Rx buf: virt=%p phys=0x%llx", fRxBuf, (unsigned long long)fRxBufPhys);

    if (fRxBufPhys > DMA_MASK_32BIT) {
        DLOG("FATAL: Rx buffer above 4GB");
        goto fail;
    }

    /* Allocate Tx buffers with 32-bit physical address constraint */
    for (int i = 0; i < NUM_TX_DESC; i++) {
        fTxBufDesc[i] = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionOut | kIOMemoryPhysicallyContiguous,
            TX_BUF_SIZE, DMA_MASK_32BIT);
        if (!fTxBufDesc[i]) {
            DLOG("Failed to allocate Tx buffer %d", i);
            goto fail;
        }
        fTxBufDesc[i]->prepare();
        fTxBuf[i] = (UInt8 *)fTxBufDesc[i]->getBytesNoCopy();
        fTxBufPhys[i] = fTxBufDesc[i]->getPhysicalAddress();

        if (fTxBufPhys[i] > DMA_MASK_32BIT) {
            DLOG("FATAL: Tx buffer %d above 4GB", i);
            goto fail;
        }
    }

    /* Make sure interrupts are masked before enabling interrupt source */
    writeReg16(RTL_IMR, 0);
    /* Clear any pending interrupts */
    writeReg16(RTL_ISR, 0xFFFF);

    /* Set up interrupt source */
    fWorkLoop = getWorkLoop();
    if (!fWorkLoop) {
        DLOG("No workloop");
        goto fail;
    }

    fInterruptSrc = IOFilterInterruptEventSource::filterInterruptEventSource(
        this,
        OSMemberFunctionCast(IOInterruptEventAction, this,
                             &RTL8139Ethernet::interruptOccurred),
        &RTL8139Ethernet::interruptFilter,
        fPCIDevice);
    if (!fInterruptSrc) {
        DLOG("Failed to create interrupt source");
        goto fail;
    }
    if (fWorkLoop->addEventSource(fInterruptSrc) != kIOReturnSuccess) {
        DLOG("Failed to add interrupt source to workloop");
        goto fail;
    }
    fInterruptSrc->enable();

    /* Attach and register interface — do NOT enable hardware yet */
    if (!attachInterface((IONetworkInterface **)&fNetIf)) {
        DLOG("Failed to attach network interface");
        goto fail;
    }

    DLOG("RTL8139 driver started successfully");
    return true;

fail:
    /*
     * Clean up locally; do NOT call stop() — that's IOKit's job once
     * start() returns false. Calling our own stop() here followed by
     * IOKit calling it again leads to double-teardown crashes (and any
     * super::stop() call when we never finished super::start() is
     * undefined behaviour).
     */
    DLOG("start() failed, cleaning up");
    if (fInterruptSrc) {
        fInterruptSrc->disable();
        if (fWorkLoop) fWorkLoop->removeEventSource(fInterruptSrc);
        fInterruptSrc->release();
        fInterruptSrc = NULL;
    }
    if (fRegMap)    { fRegMap->release();    fRegMap = NULL;    fRegBase = NULL; }
    if (fPCIDevice) { fPCIDevice->close(this); /* released in free() */ }
    return false;
}

void RTL8139Ethernet::stop(IOService *provider)
{
    DLOG("Stopping");

    if (fEnabled)
        disableAdapter();

    if (fInterruptSrc) {
        fInterruptSrc->disable();
        if (fWorkLoop)
            fWorkLoop->removeEventSource(fInterruptSrc);
    }

    if (fNetIf) {
        detachInterface(fNetIf);
        fNetIf = NULL;
    }

    if (fPCIDevice) {
        fPCIDevice->close(this);
    }

    super::stop(provider);
}

void RTL8139Ethernet::free()
{
    if (fInterruptSrc) { fInterruptSrc->release(); fInterruptSrc = NULL; }
    if (fRxBufDesc) { fRxBufDesc->complete(); fRxBufDesc->release(); fRxBufDesc = NULL; }
    for (int i = 0; i < NUM_TX_DESC; i++) {
        if (fTxBufDesc[i]) { fTxBufDesc[i]->complete(); fTxBufDesc[i]->release(); fTxBufDesc[i] = NULL; }
    }
    if (fRegMap) { fRegMap->release(); fRegMap = NULL; }
    if (fPCIDevice) { fPCIDevice->release(); fPCIDevice = NULL; }
    if (fTxQueue) { fTxQueue->release(); fTxQueue = NULL; }

    super::free();
}

// ---------------------------------------------------------------------------
// IONetworkController overrides
// ---------------------------------------------------------------------------

IOReturn RTL8139Ethernet::enable(IONetworkInterface *interface)
{
    DLOG("Enable");
    enableAdapter();
    fEnabled = true;
    if (fTxQueue)
        fTxQueue->start();
    return kIOReturnSuccess;
}

IOReturn RTL8139Ethernet::disable(IONetworkInterface *interface)
{
    DLOG("Disable");
    fEnabled = false;
    if (fTxQueue)
        fTxQueue->stop();
    disableAdapter();
    return kIOReturnSuccess;
}

IOReturn RTL8139Ethernet::getHardwareAddress(IOEthernetAddress *addr)
{
    memcpy(addr, &fMacAddr, sizeof(IOEthernetAddress));
    return kIOReturnSuccess;
}

IOReturn RTL8139Ethernet::getMaxPacketSize(UInt32 *maxSize) const
{
    *maxSize = 1500;
    return kIOReturnSuccess;
}

IOReturn RTL8139Ethernet::getMinPacketSize(UInt32 *minSize) const
{
    *minSize = 64;
    return kIOReturnSuccess;
}

IOReturn RTL8139Ethernet::setMulticastMode(bool active)
{
    if (!fPCIDevice) return kIOReturnNotReady;
    writeReg32(RTL_MAR0, 0xFFFFFFFF);
    writeReg32(RTL_MAR4, 0xFFFFFFFF);
    return kIOReturnSuccess;
}

IOReturn RTL8139Ethernet::setPromiscuousMode(bool active)
{
    if (!fPCIDevice) return kIOReturnNotReady;
    UInt32 rcr = readReg32(RTL_RCR);
    if (active)
        rcr |= RCR_AAP;
    else
        rcr &= ~RCR_AAP;
    writeReg32(RTL_RCR, rcr);
    return kIOReturnSuccess;
}

IOOutputQueue *RTL8139Ethernet::createOutputQueue()
{
    fTxQueue = IOBasicOutputQueue::withTarget(this, 256);
    return fTxQueue;
}

bool RTL8139Ethernet::configureInterface(IONetworkInterface *interface)
{
    if (!super::configureInterface(interface))
        return false;

    IONetworkData *data = interface->getNetworkData(kIONetworkStatsKey);
    if (data)
        fNetStats = (IONetworkStats *)data->getBuffer();

    data = interface->getNetworkData(kIOEthernetStatsKey);
    if (data)
        fEthStats = (IOEthernetStats *)data->getBuffer();

    return true;
}

const OSString *RTL8139Ethernet::newVendorString() const
{
    return OSString::withCString("Realtek");
}

const OSString *RTL8139Ethernet::newModelString() const
{
    return OSString::withCString("RTL8139 (QEMU)");
}

// ---------------------------------------------------------------------------
// Hardware operations
// ---------------------------------------------------------------------------

void RTL8139Ethernet::resetAdapter()
{
    DLOG("Resetting adapter");
    writeReg8(RTL_CR, CR_RST);

    for (int i = 0; i < 1000; i++) {
        if (!(readReg8(RTL_CR) & CR_RST))
            break;
        IODelay(10);
    }

    if (readReg8(RTL_CR) & CR_RST)
        DLOG("WARNING: Reset did not complete");
}

void RTL8139Ethernet::enableAdapter()
{
    DLOG("Enabling adapter");

    writeReg8(RTL_9346CR, 0xC0);

    writeReg32(RTL_RBSTART, (UInt32)(fRxBufPhys & 0xFFFFFFFF));
    fRxOffset = 0;

    for (int i = 0; i < NUM_TX_DESC; i++)
        writeReg32(RTL_TSAD0 + i * 4, (UInt32)(fTxBufPhys[i] & 0xFFFFFFFF));
    fCurTx = 0;
    fDirtyTx = 0;

    writeReg32(RTL_RCR,
        RCR_AB | RCR_AM | RCR_APM |
        (RX_BUF_LEN_IDX << 11) |
        (7 << 13) |
        (6 << 8) |
        RCR_WRAP);

    writeReg32(RTL_TCR, (6 << 8) | (3 << 24));

    writeReg32(RTL_MAR0, 0xFFFFFFFF);
    writeReg32(RTL_MAR4, 0xFFFFFFFF);

    writeReg16(RTL_ISR, 0xFFFF);

    writeReg8(RTL_CR, CR_RE | CR_TE);

    writeReg16(RTL_IMR, INT_ROK | INT_RER | INT_TOK | INT_TER |
                        INT_RXOVW | INT_FOVW | INT_PUN);

    writeReg8(RTL_9346CR, 0x00);

    DLOG("Adapter enabled, Rx phys=0x%x", (unsigned int)(fRxBufPhys & 0xFFFFFFFF));
}

void RTL8139Ethernet::disableAdapter()
{
    if (!fPCIDevice) return;
    writeReg16(RTL_IMR, 0);
    writeReg16(RTL_ISR, 0xFFFF);
    writeReg8(RTL_CR, 0);
}

// ---------------------------------------------------------------------------
// Transmit
// ---------------------------------------------------------------------------

UInt32 RTL8139Ethernet::outputPacket(mbuf_t m, void *param)
{
    if (!fEnabled || !m) {
        if (m) freePacket(m);
        return kIOReturnOutputDropped;
    }

    UInt32 txIdx = fCurTx % NUM_TX_DESC;

    UInt32 status = readReg32(RTL_TSD0 + txIdx * 4);
    if (!(status & (TSD_TOK | TSD_TUN | TSD_OWN))) {
        freePacket(m);
        if (fNetStats) fNetStats->outputErrors++;
        return kIOReturnOutputStall;
    }

    UInt32 pktLen = mbuf_pkthdr_len(m);
    if (pktLen > TX_BUF_SIZE) {
        freePacket(m);
        if (fNetStats) fNetStats->outputErrors++;
        return kIOReturnOutputDropped;
    }

    mbuf_t cur = m;
    UInt32 offset = 0;
    while (cur && offset < TX_BUF_SIZE) {
        UInt32 len = mbuf_len(cur);
        if (offset + len > TX_BUF_SIZE) len = TX_BUF_SIZE - offset;
        memcpy(fTxBuf[txIdx] + offset, mbuf_data(cur), len);
        offset += len;
        cur = mbuf_next(cur);
    }

    if (pktLen < 60) {
        memset(fTxBuf[txIdx] + pktLen, 0, 60 - pktLen);
        pktLen = 60;
    }

    freePacket(m);

    writeReg32(RTL_TSD0 + txIdx * 4, pktLen & 0x1FFF);
    fCurTx++;
    if (fNetStats) fNetStats->outputPackets++;

    return kIOReturnOutputSuccess;
}

// ---------------------------------------------------------------------------
// Receive
// ---------------------------------------------------------------------------

void RTL8139Ethernet::handleRxInterrupt()
{
    if (!fRxBuf || !fNetIf) return;

    while (!(readReg8(RTL_CR) & CR_BUFE)) {
        UInt32 offset = fRxOffset % RX_BUF_LEN;
        UInt8 *rxPtr = fRxBuf + offset;

        UInt16 rxStatus = *(volatile UInt16 *)(rxPtr);
        UInt16 rxLen    = *(volatile UInt16 *)(rxPtr + 2);

        if (rxLen == 0 || rxLen > MAX_ETH_FRAME_SIZE + 4 || !(rxStatus & RX_ROK)) {
            DLOG("Rx error: status=0x%04x len=%u", rxStatus, rxLen);
            if (fNetStats) fNetStats->inputErrors++;
            resetAdapter();
            enableAdapter();
            return;
        }

        UInt32 pktLen = rxLen - 4;

        mbuf_t pkt = allocatePacket(pktLen);
        if (pkt) {
            UInt8 *src = rxPtr + 4;

            if (offset + 4 + rxLen > RX_BUF_LEN) {
                UInt32 firstPart = RX_BUF_LEN - offset - 4;
                if (firstPart > pktLen) firstPart = pktLen;
                memcpy(mbuf_data(pkt), src, firstPart);
                if (pktLen > firstPart)
                    memcpy((UInt8 *)mbuf_data(pkt) + firstPart, fRxBuf, pktLen - firstPart);
            } else {
                memcpy(mbuf_data(pkt), src, pktLen);
            }

            fNetIf->inputPacket(pkt, pktLen,
                IONetworkInterface::kInputOptionQueuePacket);
            if (fNetStats) fNetStats->inputPackets++;
        } else {
            if (fNetStats) fNetStats->inputErrors++;
        }

        fRxOffset = (offset + rxLen + 4 + 3) & ~3;
        writeReg16(RTL_CAPR, (UInt16)(fRxOffset - 16));
    }

    fNetIf->flushInputQueue();
}

// ---------------------------------------------------------------------------
// Tx completion
// ---------------------------------------------------------------------------

void RTL8139Ethernet::handleTxInterrupt()
{
    while (fDirtyTx != fCurTx) {
        UInt32 txIdx = fDirtyTx % NUM_TX_DESC;
        UInt32 status = readReg32(RTL_TSD0 + txIdx * 4);

        if (!(status & (TSD_TOK | TSD_TABT | TSD_TUN)))
            break;

        if (status & TSD_TABT) {
            DLOG("Tx abort on descriptor %u", txIdx);
            if (fNetStats) fNetStats->outputErrors++;
        }

        fDirtyTx++;
    }

    if (fTxQueue)
        fTxQueue->service();
}

// ---------------------------------------------------------------------------
// Interrupt handling
// ---------------------------------------------------------------------------

bool RTL8139Ethernet::interruptFilter(OSObject *owner,
    IOFilterInterruptEventSource *src)
{
    RTL8139Ethernet *me = OSDynamicCast(RTL8139Ethernet, owner);
    /*
     * Do NOT gate on fRegBase here: in PCI-I/O-port (fUseIO) mode
     * fRegBase is intentionally NULL and register access goes through
     * fPCIDevice->ioRead*().  Gating on fRegBase would make the filter
     * always return false, the ISR would never be cleared, the IRQ
     * line would stay asserted, and the CPU would livelock.
     */
    if (!me || !me->fPCIDevice || !me->fEnabled) return false;

    UInt16 isr = me->readReg16(RTL_ISR);
    if (isr == 0 || isr == 0xFFFF)
        return false;

    return true;
}

void RTL8139Ethernet::interruptOccurred(IOInterruptEventSource *src, int count)
{
    if (!fPCIDevice || !fEnabled) return;

    UInt16 isr;

    while ((isr = readReg16(RTL_ISR)) != 0) {
        writeReg16(RTL_ISR, isr);

        if (isr & (INT_ROK | INT_RER | INT_RXOVW | INT_FOVW))
            handleRxInterrupt();

        if (isr & (INT_TOK | INT_TER))
            handleTxInterrupt();

        if (isr & INT_PUN)
            DLOG("Link change detected");
    }
}
