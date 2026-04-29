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
    fInterruptSrc = NULL;
    fNetIf = NULL;
    fTxQueue = NULL;
    fRxBufDesc = NULL;
    fRxBuf = NULL;
    fCurTx = 0;
    fDirtyTx = 0;
    fEnabled = false;

    for (int i = 0; i < NUM_TX_DESC; i++) {
        fTxBufDesc[i] = NULL;
        fTxBuf[i] = NULL;
    }

    return true;
}

bool RTL8139Ethernet::start(IOService *provider)
{
    if (!super::start(provider))
        return false;

    fPCIDevice = OSDynamicCast(IOPCIDevice, provider);
    if (!fPCIDevice) {
        DLOG("Provider is not an IOPCIDevice");
        return false;
    }

    fPCIDevice->retain();
    fPCIDevice->open(this);

    /* Enable PCI bus mastering and memory space */
    fPCIDevice->setBusMasterEnable(true);
    fPCIDevice->setMemoryEnable(true);

    /* Map BAR1 (MMIO) — RTL8139 uses BAR0 for I/O and BAR1 for MMIO */
    fRegMap = fPCIDevice->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress1);
    if (!fRegMap) {
        /* Fall back to BAR0 (I/O ports) mapped as memory */
        fRegMap = fPCIDevice->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
    }
    if (!fRegMap) {
        DLOG("Failed to map device registers");
        goto fail;
    }
    fRegBase = (volatile UInt8 *)fRegMap->getVirtualAddress();
    DLOG("Registers mapped at %p, length %llu", fRegBase, fRegMap->getLength());

    /* Reset the chip */
    resetAdapter();

    /* Read MAC address */
    for (int i = 0; i < 6; i++)
        fMacAddr.bytes[i] = readReg8(RTL_IDR0 + i);

    DLOG("MAC address: %02x:%02x:%02x:%02x:%02x:%02x",
         fMacAddr.bytes[0], fMacAddr.bytes[1], fMacAddr.bytes[2],
         fMacAddr.bytes[3], fMacAddr.bytes[4], fMacAddr.bytes[5]);

    /* Allocate Rx buffer (32K + 16 + 2K wrap padding) */
    fRxBufDesc = IOBufferMemoryDescriptor::withCapacity(
        RX_BUF_TOTAL, kIODirectionInOut, true);
    if (!fRxBufDesc) {
        DLOG("Failed to allocate Rx buffer");
        goto fail;
    }
    fRxBufDesc->prepare();
    fRxBuf = (UInt8 *)fRxBufDesc->getBytesNoCopy();
    fRxBufPhys = fRxBufDesc->getPhysicalAddress();
    memset(fRxBuf, 0, RX_BUF_TOTAL);

    /* Allocate Tx buffers (4 x 1536 bytes) */
    for (int i = 0; i < NUM_TX_DESC; i++) {
        fTxBufDesc[i] = IOBufferMemoryDescriptor::withCapacity(
            TX_BUF_SIZE, kIODirectionOut, true);
        if (!fTxBufDesc[i]) {
            DLOG("Failed to allocate Tx buffer %d", i);
            goto fail;
        }
        fTxBufDesc[i]->prepare();
        fTxBuf[i] = (UInt8 *)fTxBufDesc[i]->getBytesNoCopy();
        fTxBufPhys[i] = fTxBufDesc[i]->getPhysicalAddress();
    }

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

    /* Attach and register interface */
    if (!attachInterface((IONetworkInterface **)&fNetIf)) {
        DLOG("Failed to attach network interface");
        goto fail;
    }

    DLOG("RTL8139 driver started successfully");
    return true;

fail:
    stop(provider);
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

IOReturn RTL8139Ethernet::setMulticastMode(bool active)
{
    /* Accept all multicast for simplicity */
    writeReg32(RTL_MAR0, 0xFFFFFFFF);
    writeReg32(RTL_MAR4, 0xFFFFFFFF);
    return kIOReturnSuccess;
}

IOReturn RTL8139Ethernet::setPromiscuousMode(bool active)
{
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

    /* Wait for reset to complete (bit clears) */
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

    /* Unlock config registers */
    writeReg8(RTL_9346CR, 0xC0);

    /* Set Rx buffer address */
    writeReg32(RTL_RBSTART, (UInt32)fRxBufPhys);
    fRxOffset = 0;

    /* Set Tx buffer addresses */
    for (int i = 0; i < NUM_TX_DESC; i++)
        writeReg32(RTL_TSAD0 + i * 4, (UInt32)fTxBufPhys[i]);
    fCurTx = 0;
    fDirtyTx = 0;

    /* Enable Rx: accept broadcast + unicast + multicast, 32K buffer, no wrap, max DMA */
    writeReg32(RTL_RCR,
        RCR_AB | RCR_AM | RCR_APM |
        (RX_BUF_LEN_IDX << 11) |   /* Buffer length */
        (7 << 13) |                  /* Rx FIFO threshold: no threshold */
        (6 << 8) |                   /* Max DMA burst: unlimited */
        RCR_WRAP);                   /* Wrap around */

    /* Tx configuration: max DMA burst, interframe gap */
    writeReg32(RTL_TCR, (6 << 8) | (3 << 24));

    /* Accept all multicast */
    writeReg32(RTL_MAR0, 0xFFFFFFFF);
    writeReg32(RTL_MAR4, 0xFFFFFFFF);

    /* Enable interrupts */
    writeReg16(RTL_IMR, INT_ROK | INT_RER | INT_TOK | INT_TER |
                        INT_RXOVW | INT_FOVW | INT_PUN);

    /* Enable Rx and Tx */
    writeReg8(RTL_CR, CR_RE | CR_TE);

    /* Lock config registers */
    writeReg8(RTL_9346CR, 0x00);

    DLOG("Adapter enabled, Rx buf at phys 0x%x", (UInt32)fRxBufPhys);
}

void RTL8139Ethernet::disableAdapter()
{
    /* Disable interrupts */
    writeReg16(RTL_IMR, 0);

    /* Disable Rx and Tx */
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

    /* Check if descriptor is available */
    UInt32 status = readReg32(RTL_TSD0 + txIdx * 4);
    if (!(status & (TSD_TOK | TSD_TUN | TSD_OWN))) {
        /* Descriptor busy — should not happen with queue but be safe */
        freePacket(m);
        if (fNetStats) fNetStats->outputErrors++;
        return kIOReturnOutputStall;
    }

    /* Copy packet data to Tx buffer */
    UInt32 pktLen = mbuf_pkthdr_len(m);
    if (pktLen > TX_BUF_SIZE) {
        freePacket(m);
        if (fNetStats) fNetStats->outputErrors++;
        return kIOReturnOutputDropped;
    }

    /* Linearize mbuf chain into Tx buffer */
    mbuf_t cur = m;
    UInt32 offset = 0;
    while (cur && offset < TX_BUF_SIZE) {
        UInt32 len = mbuf_len(cur);
        if (offset + len > TX_BUF_SIZE) len = TX_BUF_SIZE - offset;
        memcpy(fTxBuf[txIdx] + offset, mbuf_data(cur), len);
        offset += len;
        cur = mbuf_next(cur);
    }

    /* Pad short frames */
    if (pktLen < 60) {
        memset(fTxBuf[txIdx] + pktLen, 0, 60 - pktLen);
        pktLen = 60;
    }

    freePacket(m);

    /* Tell hardware to transmit: write length to TSD, clears OWN bit */
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
    while (!(readReg8(RTL_CR) & CR_BUFE)) {
        UInt32 offset = fRxOffset % RX_BUF_LEN;
        UInt8 *rxPtr = fRxBuf + offset;

        /* RTL8139 Rx header: 4 bytes (status:16, length:16) */
        UInt16 rxStatus = *(UInt16 *)(rxPtr);
        UInt16 rxLen    = *(UInt16 *)(rxPtr + 2);

        /* Sanity check */
        if (rxLen == 0 || rxLen > MAX_ETH_FRAME_SIZE + 4 || !(rxStatus & RX_ROK)) {
            DLOG("Rx error: status=0x%04x len=%u", rxStatus, rxLen);
            if (fNetStats) fNetStats->inputErrors++;
            /* Reset receiver on error */
            resetAdapter();
            enableAdapter();
            return;
        }

        /* Packet data starts at offset+4, length includes 4-byte CRC */
        UInt32 pktLen = rxLen - 4;  /* Strip CRC */

        /* Allocate mbuf and copy data */
        mbuf_t pkt = allocatePacket(pktLen);
        if (pkt) {
            UInt8 *src = rxPtr + 4;  /* Skip Rx header */

            /* Handle wrap-around: data might span end of buffer */
            if (offset + 4 + rxLen > RX_BUF_LEN) {
                /* Wrapped — copy in two parts */
                UInt32 firstPart = RX_BUF_LEN - offset - 4;
                if (firstPart > pktLen) firstPart = pktLen;
                memcpy(mbuf_data(pkt), src, firstPart);
                if (pktLen > firstPart)
                    memcpy((UInt8 *)mbuf_data(pkt) + firstPart, fRxBuf, pktLen - firstPart);
            } else {
                memcpy(mbuf_data(pkt), src, pktLen);
            }

            /* Submit to network stack */
            fNetIf->inputPacket(pkt, pktLen, IONetworkInterface::kInputOptionQueuePacket);
            if (fNetStats) fNetStats->inputPackets++;
        } else {
            if (fNetStats) fNetStats->inputErrors++;
        }

        /* Advance Rx offset: header(4) + length, aligned to 4 bytes + 4 */
        fRxOffset = (offset + rxLen + 4 + 3) & ~3;

        /* Update CAPR (read pointer) */
        writeReg16(RTL_CAPR, fRxOffset - 16);
    }

    /* Flush queued packets */
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
            break;  /* Not yet complete */

        if (status & TSD_TABT) {
            DLOG("Tx abort on descriptor %u", txIdx);
            if (fNetStats) fNetStats->outputErrors++;
        }

        fDirtyTx++;
    }

    /* Wake queue if space available */
    if (fTxQueue)
        fTxQueue->service();
}

// ---------------------------------------------------------------------------
// Interrupt handling
// ---------------------------------------------------------------------------

bool RTL8139Ethernet::interruptFilter(OSObject *owner, IOFilterInterruptEventSource *src)
{
    RTL8139Ethernet *me = OSDynamicCast(RTL8139Ethernet, owner);
    if (!me || !me->fRegBase) return false;

    UInt16 isr = me->readReg16(RTL_ISR);
    if (isr == 0 || isr == 0xFFFF)
        return false;  /* Not our interrupt */

    return true;
}

void RTL8139Ethernet::interruptOccurred(IOInterruptEventSource *src, int count)
{
    UInt16 isr;

    while ((isr = readReg16(RTL_ISR)) != 0) {
        /* Acknowledge all interrupts */
        writeReg16(RTL_ISR, isr);

        if (isr & (INT_ROK | INT_RER | INT_RXOVW | INT_FOVW))
            handleRxInterrupt();

        if (isr & (INT_TOK | INT_TER))
            handleTxInterrupt();

        if (isr & INT_PUN)
            DLOG("Link change detected");
    }
}
