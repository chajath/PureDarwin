/*
 * RTL8139Ethernet.h — Minimal RTL8139 IOKit Ethernet Driver for PureDarwin
 *
 * Drives the Realtek RTL8139C/8139CP as emulated by QEMU.
 * Based on the public RTL8139 programming guide and Linux rtl8139cp driver.
 *
 * PCI Vendor:Device = 10EC:8139
 */

#ifndef _RTL8139ETHERNET_H_
#define _RTL8139ETHERNET_H_

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOFilterInterruptEventSource.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/network/IOEthernetController.h>
#include <IOKit/network/IOEthernetInterface.h>
#include <IOKit/network/IOOutputQueue.h>
#include <IOKit/network/IOBasicOutputQueue.h>
#include <IOKit/network/IOMbufMemoryCursor.h>

/* RTL8139 Register offsets */
enum {
    RTL_IDR0        = 0x00,   /* MAC address bytes 0-3 */
    RTL_IDR4        = 0x04,   /* MAC address bytes 4-5 */
    RTL_MAR0        = 0x08,   /* Multicast filter 0-3 */
    RTL_MAR4        = 0x0C,   /* Multicast filter 4-7 */
    RTL_TSD0        = 0x10,   /* Tx status descriptor 0 (4 x 4 bytes) */
    RTL_TSAD0       = 0x20,   /* Tx start address descriptor 0 (4 x 4 bytes) */
    RTL_RBSTART     = 0x30,   /* Rx buffer start address */
    RTL_ERBCR       = 0x34,   /* Early Rx byte count */
    RTL_ERSR        = 0x36,   /* Early Rx status */
    RTL_CR          = 0x37,   /* Command register */
    RTL_CAPR        = 0x38,   /* Current address of packet read */
    RTL_CBR         = 0x3A,   /* Current buffer address */
    RTL_IMR         = 0x3C,   /* Interrupt mask */
    RTL_ISR         = 0x3E,   /* Interrupt status */
    RTL_TCR         = 0x40,   /* Tx configuration */
    RTL_RCR         = 0x44,   /* Rx configuration */
    RTL_TCTR        = 0x48,   /* Timer count */
    RTL_MPC         = 0x4C,   /* Missed packet counter */
    RTL_9346CR      = 0x50,   /* 93C46 command register */
    RTL_CONFIG0     = 0x51,   /* Configuration register 0 */
    RTL_CONFIG1     = 0x52,   /* Configuration register 1 */
    RTL_MULINT      = 0x5C,   /* Multiple interrupt select */
    RTL_RERID       = 0x5E,   /* PCI revision ID */
    RTL_TSAD        = 0x60,   /* Tx status of all descriptors */
    RTL_BMCR        = 0x62,   /* Basic mode control */
    RTL_BMSR        = 0x64,   /* Basic mode status */
    RTL_ANAR        = 0x66,   /* Auto-negotiation advertisement */
    RTL_ANLPAR      = 0x68,   /* Auto-negotiation link partner */
    RTL_ANER        = 0x6A,   /* Auto-negotiation expansion */
    RTL_CSCR        = 0x74,   /* CS configuration */
};

/* Command register bits */
enum {
    CR_RST      = 0x10,   /* Reset */
    CR_RE       = 0x08,   /* Receiver enable */
    CR_TE       = 0x04,   /* Transmitter enable */
    CR_BUFE     = 0x01,   /* Buffer empty */
};

/* Interrupt status/mask bits */
enum {
    INT_SERR    = 0x8000,
    INT_TIMEOUT = 0x4000,
    INT_LENCHG  = 0x2000,
    INT_FOVW    = 0x0040,
    INT_PUN     = 0x0020,
    INT_RXOVW   = 0x0010,
    INT_TER     = 0x0008,
    INT_TOK     = 0x0004,
    INT_RER     = 0x0002,
    INT_ROK     = 0x0001,
};

/* Rx configuration bits */
enum {
    RCR_ERTH    = (3 << 24),  /* Early Rx threshold */
    RCR_MRINT   = (1 << 17),  /* Multiple early interrupt */
    RCR_RER8    = (1 << 16),  /* Receive error packets > 8 bytes */
    RCR_RXFTH   = (7 << 13),  /* Rx FIFO threshold */
    RCR_RBLEN   = (3 << 11),  /* Rx buffer length: 0=8K, 1=16K, 2=32K, 3=64K */
    RCR_MXDMA   = (7 << 8),   /* Max DMA burst */
    RCR_WRAP    = (1 << 7),   /* Wrap */
    RCR_AB      = (1 << 3),   /* Accept broadcast */
    RCR_AM      = (1 << 2),   /* Accept multicast */
    RCR_APM     = (1 << 1),   /* Accept physical match */
    RCR_AAP     = (1 << 0),   /* Accept all packets (promisc) */
};

/* Tx status bits */
enum {
    TSD_CRS     = (1 << 31),
    TSD_TABT    = (1 << 30),
    TSD_OWC     = (1 << 29),
    TSD_CDH     = (1 << 28),
    TSD_OWN     = (1 << 13),
    TSD_TOK     = (1 << 15),
    TSD_TUN     = (1 << 14),
};

/* Rx header status bits */
enum {
    RX_ROK      = (1 << 0),
    RX_FAE      = (1 << 1),
    RX_CRC      = (1 << 2),
    RX_LONG     = (1 << 3),
    RX_RUNT     = (1 << 4),
    RX_ISE      = (1 << 5),
    RX_BAR      = (1 << 13),
    RX_PAM      = (1 << 14),
    RX_MAR      = (1 << 15),
};

/* Buffer sizes */
#define RX_BUF_LEN_IDX     2       /* 0=8K, 1=16K, 2=32K, 3=64K */
#define RX_BUF_LEN          (8192 << RX_BUF_LEN_IDX)
#define RX_BUF_PAD          16
#define RX_BUF_WRAP_PAD     2048
#define RX_BUF_TOTAL        (RX_BUF_LEN + RX_BUF_PAD + RX_BUF_WRAP_PAD)

#define TX_BUF_SIZE         1536
#define NUM_TX_DESC         4

#define MAX_ETH_FRAME_SIZE  1536

class RTL8139Ethernet : public IOEthernetController {
    OSDeclareDefaultStructors(RTL8139Ethernet)

public:
    /* IOService */
    virtual bool        init(OSDictionary *properties) APPLE_KEXT_OVERRIDE;
    virtual bool        start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void        stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void        free() APPLE_KEXT_OVERRIDE;

    /* IONetworkController */
    virtual IOReturn    enable(IONetworkInterface *interface) APPLE_KEXT_OVERRIDE;
    virtual IOReturn    disable(IONetworkInterface *interface) APPLE_KEXT_OVERRIDE;
    virtual IOReturn    getHardwareAddress(IOEthernetAddress *addr) APPLE_KEXT_OVERRIDE;
    virtual IOReturn    setMulticastMode(bool active) APPLE_KEXT_OVERRIDE;
    virtual IOReturn    setPromiscuousMode(bool active) APPLE_KEXT_OVERRIDE;
    virtual IOOutputQueue *createOutputQueue() APPLE_KEXT_OVERRIDE;
    virtual UInt32      outputPacket(mbuf_t m, void *param) APPLE_KEXT_OVERRIDE;
    virtual const OSString *newVendorString() const APPLE_KEXT_OVERRIDE;
    virtual const OSString *newModelString() const APPLE_KEXT_OVERRIDE;
    virtual bool        configureInterface(IONetworkInterface *interface) APPLE_KEXT_OVERRIDE;
    virtual IOReturn    getMaxPacketSize(UInt32 *maxSize) const APPLE_KEXT_OVERRIDE;
    virtual IOReturn    getMinPacketSize(UInt32 *minSize) const APPLE_KEXT_OVERRIDE;

private:
    /* Hardware operations */
    bool                initAdapter();
    void                resetAdapter();
    void                enableAdapter();
    void                disableAdapter();

    /* Interrupt handling */
    void                interruptOccurred(IOInterruptEventSource *src, int count);
    static bool         interruptFilter(OSObject *owner, IOFilterInterruptEventSource *src);
    void                handleRxInterrupt();
    void                handleTxInterrupt();

    /* Members */
    IOPCIDevice                     *fPCIDevice;
    IOMemoryMap                     *fRegMap;     /* may be NULL when using I/O ports */
    volatile UInt8                  *fRegBase;    /* may be NULL when using I/O ports */
    UInt8                            fIOBar;       /* PCI config offset of selected BAR */
    bool                             fUseIO;       /* true = PCI I/O ports, false = MMIO */
    IOWorkLoop                      *fWorkLoop;
    IOFilterInterruptEventSource    *fInterruptSrc;
    IOEthernetInterface             *fNetIf;
    IOBasicOutputQueue              *fTxQueue;
    IONetworkStats                  *fNetStats;
    IOEthernetStats                 *fEthStats;

    /* Rx buffer */
    IOBufferMemoryDescriptor        *fRxBufDesc;
    UInt8                           *fRxBuf;
    IOPhysicalAddress               fRxBufPhys;
    UInt32                          fRxOffset;

    /* Tx buffers */
    IOBufferMemoryDescriptor        *fTxBufDesc[NUM_TX_DESC];
    UInt8                           *fTxBuf[NUM_TX_DESC];
    IOPhysicalAddress               fTxBufPhys[NUM_TX_DESC];
    UInt32                          fCurTx;
    UInt32                          fDirtyTx;

    IOEthernetAddress               fMacAddr;
    bool                            fEnabled;

    /*
     * Register access — chooses between MMIO and PCI I/O ports based on
     * what we successfully opened in start(). On QEMU's basic -device
     * rtl8139 BAR0 is I/O space and BAR1 (MMIO) is sometimes absent.
     */
    UInt8  readReg8(UInt16 offset) {
        return fUseIO ? fPCIDevice->ioRead8(offset, fRegMap)
                      : fRegBase[offset];
    }
    UInt16 readReg16(UInt16 offset) {
        return fUseIO ? fPCIDevice->ioRead16(offset, fRegMap)
                      : *(volatile UInt16 *)(fRegBase + offset);
    }
    UInt32 readReg32(UInt16 offset) {
        return fUseIO ? fPCIDevice->ioRead32(offset, fRegMap)
                      : *(volatile UInt32 *)(fRegBase + offset);
    }
    void writeReg8(UInt16 offset, UInt8 val) {
        if (fUseIO) fPCIDevice->ioWrite8(offset, val, fRegMap);
        else        fRegBase[offset] = val;
    }
    void writeReg16(UInt16 offset, UInt16 val) {
        if (fUseIO) fPCIDevice->ioWrite16(offset, val, fRegMap);
        else        *(volatile UInt16 *)(fRegBase + offset) = val;
    }
    void writeReg32(UInt16 offset, UInt32 val) {
        if (fUseIO) fPCIDevice->ioWrite32(offset, val, fRegMap);
        else        *(volatile UInt32 *)(fRegBase + offset) = val;
    }
};

#endif /* _RTL8139ETHERNET_H_ */
