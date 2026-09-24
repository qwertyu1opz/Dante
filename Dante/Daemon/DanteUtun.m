

#import "DanteUtun.h"
#import "AWGConfig.h"
#import "AmneziaWGManager.h"
#import "DebugLog.h"
#import "DanteRedirector.h"
#import "DanteTunNAT.h"
#import "PowerSession.h"

#include <dlfcn.h>

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/sysctl.h>
#include <sys/uio.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <mach/mach.h>
#include "nw_scope.h"

#pragma mark - utun (kernel control)

#define DN_PF_SYSTEM         32
#define DN_AF_SYSTEM         32
#define DN_SYSPROTO_CONTROL  2
#define DN_AF_SYS_CONTROL    2
#define DN_UTUN_CONTROL_NAME "com.apple.net.utun_control"
#define DN_UTUN_OPT_IFNAME   2

struct dn_ctl_info {
    u_int32_t ctl_id;
    char      ctl_name[96];
};

struct dn_sockaddr_ctl {
    u_char    sc_len;
    u_char    sc_family;
    u_int16_t ss_sysaddr;
    u_int32_t sc_id;
    u_int32_t sc_unit;
    u_int32_t sc_reserved[5];
};

#define DN_CTLIOCGINFO _IOWR('N', 3, struct dn_ctl_info)

static int dn_utun_open(char *ifname, size_t cap) {
    int fd = socket(DN_PF_SYSTEM, SOCK_DGRAM, DN_SYSPROTO_CONTROL);
    if (fd < 0) return -1;
    struct dn_ctl_info ci;
    memset(&ci, 0, sizeof(ci));
    strlcpy(ci.ctl_name, DN_UTUN_CONTROL_NAME, sizeof(ci.ctl_name));
    if (ioctl(fd, DN_CTLIOCGINFO, &ci) < 0) { int e = errno; close(fd); errno = e; return -1; }

    struct dn_sockaddr_ctl sc;
    memset(&sc, 0, sizeof(sc));
    sc.sc_len = sizeof(sc);
    sc.sc_family = DN_AF_SYSTEM;
    sc.ss_sysaddr = DN_AF_SYS_CONTROL;
    sc.sc_id = ci.ctl_id;
    sc.sc_unit = 0;   
    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) { int e = errno; close(fd); errno = e; return -1; }

    socklen_t len = (socklen_t)cap;
    if (getsockopt(fd, DN_SYSPROTO_CONTROL, DN_UTUN_OPT_IFNAME, ifname, &len) < 0) {
        strlcpy(ifname, "utun?", cap);
    }
    return fd;
}

static void dn_set_sin(struct sockaddr *sa, struct in_addr a) {
    struct sockaddr_in *sin = (struct sockaddr_in *)sa;
    sin->sin_len = sizeof(*sin);
    sin->sin_family = AF_INET;
    sin->sin_addr = a;
}

static int dn_if_configure(const char *ifname, struct in_addr local, struct in_addr peer, int mtu) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifaliasreq ifra;
    memset(&ifra, 0, sizeof(ifra));
    strlcpy(ifra.ifra_name, ifname, sizeof(ifra.ifra_name));
    struct in_addr mask; mask.s_addr = 0xffffffff;
    dn_set_sin(&ifra.ifra_addr, local);
    dn_set_sin(&ifra.ifra_broadaddr, peer);   
    dn_set_sin(&ifra.ifra_mask, mask);
    if (ioctl(s, SIOCAIFADDR, &ifra) < 0) { int e = errno; close(s); errno = e; return -1; }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name));
    ifr.ifr_mtu = mtu;
    ioctl(s, SIOCSIFMTU, &ifr);

    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name));
    if (ioctl(s, SIOCGIFFLAGS, &ifr) >= 0) {
        ifr.ifr_flags |= (IFF_UP | IFF_RUNNING);
        ioctl(s, SIOCSIFFLAGS, &ifr);
    }
    close(s);
    return 0;
}

#pragma mark - Маршруты (routing socket)

#define DN_RTM_VERSION 5
#define DN_RTM_ADD     1
#define DN_RTM_DELETE  2
#define DN_RTF_UP      0x1
#define DN_RTF_GATEWAY 0x2
#define DN_RTF_HOST    0x4
#define DN_RTF_STATIC  0x800
#define DN_RTF_IFSCOPE 0x1000000
#define DN_RTA_DST     0x1
#define DN_RTA_GATEWAY 0x2
#define DN_RTA_NETMASK 0x4
#define DN_RTV_MTU     0x1
#define DN_RTAX_MAX    8
#define DN_NET_RT_FLAGS 2

struct dn_rt_metrics {
    uint32_t rmx_locks, rmx_mtu, rmx_hopcount;
    int32_t  rmx_expire;
    uint32_t rmx_recvpipe, rmx_sendpipe, rmx_ssthresh, rmx_rtt, rmx_rttvar, rmx_pksent;
    uint32_t rmx_state;
    uint32_t rmx_filler[3];
};

struct dn_rt_msghdr {
    unsigned short rtm_msglen;
    unsigned char  rtm_version;
    unsigned char  rtm_type;
    unsigned short rtm_index;
    int            rtm_flags;
    int            rtm_addrs;
    pid_t          rtm_pid;
    int            rtm_seq;
    int            rtm_errno;
    int            rtm_use;
    uint32_t       rtm_inits;
    struct dn_rt_metrics rtm_rmx;
};

#define DN_ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(long) - 1))) : sizeof(long))

static BOOL dn_if_peer_addr(const char *ifname, struct in_addr *out) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return NO;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name));
    BOOL ok = NO;
    if (ioctl(s, SIOCGIFDSTADDR, &ifr) == 0) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
        if (sin->sin_family == AF_INET && sin->sin_addr.s_addr != INADDR_ANY) {
            *out = sin->sin_addr;
            ok = YES;
        }
    }
    close(s);
    return ok;
}

static BOOL dn_default_route_flagged(struct in_addr *gw, unsigned *ifindex,
                                     int flagFilter, BOOL acceptLink) {
    int mib[] = {CTL_NET, PF_ROUTE, 0, AF_INET, DN_NET_RT_FLAGS, flagFilter};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0) return NO;
    char *buf = malloc(len);
    if (!buf) return NO;
    if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) { free(buf); return NO; }
    BOOL found = NO;
    for (char *next = buf; next < buf + len; ) {
        struct dn_rt_msghdr *rtm = (struct dn_rt_msghdr *)next;
        if (rtm->rtm_msglen == 0) break;
        next += rtm->rtm_msglen;
        if (rtm->rtm_version != DN_RTM_VERSION) continue;
        struct sockaddr *sa = (struct sockaddr *)(rtm + 1);
        struct sockaddr_in *dst = NULL;
        struct sockaddr *gateway = NULL;
        struct sockaddr *mask = NULL;
        for (int i = 0; i < DN_RTAX_MAX; i++) {
            if (!(rtm->rtm_addrs & (1 << i))) continue;
            if (i == 0) dst = (struct sockaddr_in *)sa;
            if (i == 1) gateway = sa;
            if (i == 2) mask = sa;
            sa = (struct sockaddr *)((char *)sa + DN_ROUNDUP(sa->sa_len));
        }
        if (!dst || dst->sin_addr.s_addr != INADDR_ANY) continue;
        
        
        
        
        uint32_t maskBits = 0;
        if (mask && mask->sa_len > 4) {
            const uint8_t *m = (const uint8_t *)mask + 4;   
            int have = (int)mask->sa_len - 4;
            for (int i = 0; i < have && i < 4; i++) maskBits |= (uint32_t)m[i] << (24 - 8 * i);
        }
        if (maskBits != 0) continue;   
        if (!gateway) continue;
        struct in_addr g;
        if (gateway->sa_family == AF_INET) g = ((struct sockaddr_in *)gateway)->sin_addr;
        else if (acceptLink && gateway->sa_family == AF_LINK) g.s_addr = INADDR_ANY;
        else continue;
        BOOL scoped = (rtm->rtm_flags & DN_RTF_IFSCOPE) != 0;
        if (found && scoped) continue;         
        *gw = g;
        *ifindex = rtm->rtm_index;
        found = YES;
        if (!scoped) break;
    }
    free(buf);
    return found;
}

static BOOL dn_default_route(struct in_addr *gw, unsigned *ifindex) {
    if (dn_default_route_flagged(gw, ifindex, DN_RTF_GATEWAY, NO)) return YES;
    return dn_default_route_flagged(gw, ifindex, 0, YES);
}

static BOOL dn_primary_from_system(char *nameOut, size_t cap, struct in_addr *gwOut);

BOOL DNPrimaryUplink(char *nameOut, size_t cap, unsigned *ifindexOut,
                     struct in_addr *gwOut, BOOL *isCellularOut) {
    char sysName[IFNAMSIZ] = {0};
    struct in_addr sysGw;
    if (dn_primary_from_system(sysName, sizeof(sysName), &sysGw)) {
        unsigned sysIdx = if_nametoindex(sysName);
        if (sysIdx) {
            if (nameOut) strlcpy(nameOut, sysName, cap);
            if (ifindexOut) *ifindexOut = sysIdx;
            if (gwOut) *gwOut = sysGw;
            if (isCellularOut) *isCellularOut = (strncmp(sysName, "pdp_ip", 6) == 0);
            return YES;
        }
    }

    
    struct in_addr gw; unsigned idx = 0;
    if (!dn_default_route(&gw, &idx)) return NO;
    char name[IFNAMSIZ] = {0};
    if (!if_indextoname(idx, name)) return NO;
    if (nameOut) strlcpy(nameOut, name, cap);
    if (ifindexOut) *ifindexOut = idx;
    if (gwOut) *gwOut = gw;
    
    if (isCellularOut) *isCellularOut = (strncmp(name, "pdp_ip", 6) == 0);
    return YES;
}

static int dn_route(int op, int flags, struct in_addr dst, struct in_addr mask,
                    struct in_addr gateway, int mtu) {
    int s = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    if (s < 0) return -1;
    struct {
        struct dn_rt_msghdr hdr;
        char buf[256];
    } msg;
    memset(&msg, 0, sizeof(msg));
    msg.hdr.rtm_version = DN_RTM_VERSION;
    msg.hdr.rtm_type = (unsigned char)op;
    msg.hdr.rtm_flags = flags | DN_RTF_UP | DN_RTF_STATIC;
    if (mtu > 0) {
        msg.hdr.rtm_inits |= DN_RTV_MTU;
        msg.hdr.rtm_rmx.rmx_mtu = (uint32_t)mtu;
    }
    msg.hdr.rtm_addrs = DN_RTA_DST | DN_RTA_GATEWAY | DN_RTA_NETMASK;
    msg.hdr.rtm_seq = 9095;

    char *p = msg.buf;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    dn_set_sin((struct sockaddr *)&sa, dst);
    memcpy(p, &sa, sizeof(sa)); p += DN_ROUNDUP(sizeof(sa));
    dn_set_sin((struct sockaddr *)&sa, gateway);
    memcpy(p, &sa, sizeof(sa)); p += DN_ROUNDUP(sizeof(sa));
    dn_set_sin((struct sockaddr *)&sa, mask);
    sa.sin_family = AF_UNSPEC;
    memcpy(p, &sa, sizeof(sa)); p += DN_ROUNDUP(sizeof(sa));
    msg.hdr.rtm_msglen = (unsigned short)(p - (char *)&msg);

    ssize_t n = write(s, &msg, msg.hdr.rtm_msglen);
    int err = errno;
    close(s);
    if (n < 0) { errno = err; return -1; }
    return 0;
}

static volatile uint16_t gDNClampMSS = 0;

volatile uint32_t gDNUtunWritten = 0, gDNUtunRetried = 0, gDNUtunDropped = 0;

volatile int gDNBatchSend = 0;

volatile int gDNMergeLoops = 0;
static NSString * const kDNClampKey = @"dante_mss_clamp";

static void dn_clamp_mss(uint8_t *ip, size_t len) {
    if (gDNClampMSS == 0) return;
    if (len < 40 || (ip[0] >> 4) != 4 || ip[9] != 6) return;
    size_t ihl = (size_t)(ip[0] & 0x0f) * 4;
    size_t totalLen = (size_t)((ip[2] << 8) | ip[3]);
    if (totalLen > len || totalLen < ihl + 20) return;
    uint8_t *tcp = ip + ihl;
    size_t tcpLen = totalLen - ihl;
    if (!(tcp[13] & 0x02)) return;                      
    size_t thl = (size_t)(tcp[12] >> 4) * 4;
    if (thl < 20 || thl > tcpLen) return;
    BOOL changed = NO;
    for (uint8_t *o = tcp + 20, *end = tcp + thl; o < end; ) {
        if (o[0] == 0) break;
        if (o[0] == 1) { o++; continue; }
        if (o + 1 >= end || o[1] < 2 || o + o[1] > end) break;
        if (o[0] == 2 && o[1] == 4) {
            if (((o[2] << 8) | o[3]) > gDNClampMSS) {
                o[2] = gDNClampMSS >> 8;
                o[3] = gDNClampMSS & 0xff;
                changed = YES;
            }
            break;
        }
        o += o[1];
    }
    if (!changed) return;
    uint32_t sum = 0;
    sum += (ip[12] << 8) | ip[13]; sum += (ip[14] << 8) | ip[15];   
    sum += (ip[16] << 8) | ip[17]; sum += (ip[18] << 8) | ip[19];   
    sum += 6;
    sum += (uint32_t)tcpLen;
    tcp[16] = 0; tcp[17] = 0;
    size_t i = 0;
    for (; i + 1 < tcpLen; i += 2) sum += (tcp[i] << 8) | tcp[i + 1];
    if (i < tcpLen) sum += tcp[i] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    uint16_t csum = (uint16_t)~sum;
    tcp[16] = csum >> 8;
    tcp[17] = csum & 0xff;
}

static struct in_addr dn_addr(uint32_t hostOrder) {
    struct in_addr a; a.s_addr = htonl(hostOrder); return a;
}

#pragma mark - Scoped Routing (Kernel Patch & SCDynamicStore)

typedef mach_port_t mach_vm_map_t;
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;

static mach_port_t g_kt = MACH_PORT_NULL;
static mach_vm_address_t g_scopedroute_kaddr = 0;
static uint32_t g_scopedroute_old = 1;
static BOOL g_scopedroute_changed = NO;

static BOOL is_kernel_64bit(void) {
    int val = 0;
    size_t size = sizeof(val);
    if (sysctlbyname("hw.cpu64bit_capable", &val, &size, NULL, 0) == 0) {
        return (val != 0);
    }
    return NO;
}

static kern_return_t kread_safe(mach_port_t kt, mach_vm_address_t addr, mach_vm_size_t size, vm_offset_t *data, mach_msg_type_number_t *dataCnt, BOOL is64) {
    if (is64) {
        typedef kern_return_t (*mach_vm_read_t)(vm_map_t, mach_vm_address_t, mach_vm_size_t, vm_offset_t *, mach_msg_type_number_t *);
        static mach_vm_read_t p_mach_vm_read = NULL;
        static BOOL checked = NO;
        if (!checked) {
            p_mach_vm_read = (mach_vm_read_t)dlsym(RTLD_DEFAULT, "mach_vm_read");
            checked = YES;
        }
        if (p_mach_vm_read) {
            return p_mach_vm_read(kt, addr, size, data, dataCnt);
        } else {
            return KERN_FAILURE;
        }
    } else {
        vm_address_t addr32 = (vm_address_t)addr;
        vm_size_t size32 = (vm_size_t)size;
        return vm_read(kt, addr32, size32, data, dataCnt);
    }
}

static kern_return_t kwrite_safe(mach_port_t kt, mach_vm_address_t addr, vm_offset_t data, mach_msg_type_number_t dataCnt, BOOL is64) {
    if (is64) {
        typedef kern_return_t (*mach_vm_write_t)(vm_map_t, mach_vm_address_t, vm_offset_t, mach_msg_type_number_t);
        static mach_vm_write_t p_mach_vm_write = NULL;
        static BOOL checked = NO;
        if (!checked) {
            p_mach_vm_write = (mach_vm_write_t)dlsym(RTLD_DEFAULT, "mach_vm_write");
            checked = YES;
        }
        if (p_mach_vm_write) {
            return p_mach_vm_write(kt, addr, data, dataCnt);
        } else {
            return KERN_FAILURE;
        }
    } else {
        vm_address_t addr32 = (vm_address_t)addr;
        return vm_write(kt, addr32, data, dataCnt);
    }
}

static mach_vm_address_t kfind_string_64(mach_port_t kt, mach_vm_address_t start, mach_vm_address_t end, const char *str, BOOL is64) {
    size_t len = strlen(str) + 1;
    mach_vm_size_t read_sz = 4095;
    mach_vm_size_t step = 4080;
    
    for (mach_vm_address_t addr = start; addr < end; addr += step) {
        vm_offset_t buf = 0;
        mach_msg_type_number_t cnt = 0;
        kern_return_t kr = kread_safe(kt, addr, read_sz, &buf, &cnt, is64);
        if (kr == KERN_SUCCESS) {
            unsigned char *p = (unsigned char *)buf;
            if (cnt >= len) {
                for (size_t i = 0; i <= cnt - len; i++) {
                    if (memcmp(p + i, str, len) == 0) {
                        mach_vm_address_t found = addr + i;
                        vm_deallocate(mach_task_self(), buf, cnt);
                        return found;
                    }
                }
            }
            vm_deallocate(mach_task_self(), buf, cnt);
        }
    }
    return 0;
}

static mach_vm_address_t kfind_ptr_64(mach_port_t kt, mach_vm_address_t start, mach_vm_address_t end, mach_vm_address_t val, BOOL is64) {
    mach_vm_size_t read_sz = 4095;
    mach_vm_size_t step = 4080;
    
    for (mach_vm_address_t addr = start; addr < end; addr += step) {
        vm_offset_t buf = 0;
        mach_msg_type_number_t cnt = 0;
        kern_return_t kr = kread_safe(kt, addr, read_sz, &buf, &cnt, is64);
        if (kr == KERN_SUCCESS) {
            if (is64) {
                uint64_t *p = (uint64_t *)buf;
                size_t words = cnt / 8;
                for (size_t i = 0; i < words; i++) {
                    if (p[i] == val) {
                        mach_vm_address_t found = addr + i * 8;
                        vm_deallocate(mach_task_self(), buf, cnt);
                        return found;
                    }
                }
            } else {
                uint32_t *p = (uint32_t *)buf;
                size_t words = cnt / 4;
                for (size_t i = 0; i < words; i++) {
                    if (p[i] == (uint32_t)val) {
                        mach_vm_address_t found = addr + i * 4;
                        vm_deallocate(mach_task_self(), buf, cnt);
                        return found;
                    }
                }
            }
            vm_deallocate(mach_task_self(), buf, cnt);
        }
    }
    return 0;
}

static int check_oid_64(mach_port_t kt, mach_vm_address_t p_oid_name, mach_vm_address_t expected_name_addr, BOOL is64, mach_vm_address_t *out_var_addr) {
    mach_vm_address_t oid_base = is64 ? (p_oid_name - 40) : (p_oid_name - 24);
    vm_offset_t buf = 0;
    mach_msg_type_number_t cnt = 0;
    kern_return_t kr = kread_safe(kt, oid_base, 80, &buf, &cnt, is64);
    if (kr != KERN_SUCCESS || cnt < 80) {
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), buf, cnt);
        return 0;
    }
    
    if (is64) {
        uint32_t kind = *(uint32_t *)(buf + 20);
        uint64_t arg1 = *(uint64_t *)(buf + 24);
        uint64_t name = *(uint64_t *)(buf + 40);
        uint64_t handler = *(uint64_t *)(buf + 48);
        
        vm_deallocate(mach_task_self(), buf, cnt);
        
        if (name != expected_name_addr) return 0;
        if ((kind & 0xf) != 2) return 0;
        if (arg1 < 0xffffffF000000000ULL) return 0;
        if (handler < 0xffffffF000000000ULL) return 0;
        
        *out_var_addr = arg1;
        return 1;
    } else {
        uint32_t *fields = (uint32_t *)buf;
        uint32_t kind = fields[3];
        uint32_t arg1 = fields[4];
        uint32_t name = fields[6];
        uint32_t handler = fields[7];
        
        vm_deallocate(mach_task_self(), buf, cnt);
        
        if (name != expected_name_addr) return 0;
        if ((kind & 0xf) != 2) return 0;
        if (arg1 < 0x80000000 || arg1 >= 0x8fffffff) return 0;
        if (handler < 0x80000000 || handler >= 0x8fffffff) return 0;
        
        *out_var_addr = arg1;
        return 1;
    }
}

static mach_vm_address_t find_scopedroute_var_addr(mach_port_t kt) {
    BOOL is64 = is_kernel_64bit();
    mach_vm_address_t kernel_base = is64 ? 0xffffffF007004000ULL : 0x80002000ULL;
    mach_vm_address_t start = kernel_base;
    mach_vm_address_t end = kernel_base + (is64 ? 0x02000000ULL : 0x01000000ULL);
    
    mach_vm_address_t str_addr = kfind_string_64(kt, start, end, "scopedroute", is64);
    if (!str_addr) return 0;
    
    mach_vm_address_t scan_ptr = start;
    while (scan_ptr < end) {
        mach_vm_address_t p_oid_name = kfind_ptr_64(kt, scan_ptr, end, str_addr, is64);
        if (!p_oid_name) break;
        
        mach_vm_address_t var_addr = 0;
        if (check_oid_64(kt, p_oid_name, str_addr, is64, &var_addr)) {
            return var_addr;
        }
        scan_ptr = p_oid_name + (is64 ? 8 : 4);
    }
    return 0;
}

static void dn_disable_scopedroute(void) {
    if (g_scopedroute_changed) return;
    mach_port_t kt = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), 0, &kt);
    if (kr != KERN_SUCCESS || kt == MACH_PORT_NULL) {
        DLog(@"[utun] tfp0 недоступен, scopedroute не отключен");
        return;
    }
    g_kt = kt;
    g_scopedroute_kaddr = find_scopedroute_var_addr(kt);
    if (g_scopedroute_kaddr != 0) {
        vm_offset_t val_buf = 0;
        mach_msg_type_number_t val_cnt = 0;
        BOOL is64 = is_kernel_64bit();
        if (kread_safe(kt, g_scopedroute_kaddr, 4, &val_buf, &val_cnt, is64) == KERN_SUCCESS && val_cnt >= 4) {
            g_scopedroute_old = *(uint32_t *)val_buf;
            vm_deallocate(mach_task_self(), val_buf, val_cnt);
        }
        uint32_t zero = 0;
        if (kwrite_safe(kt, g_scopedroute_kaddr, (vm_offset_t)&zero, 4, is64) == KERN_SUCCESS) {
            g_scopedroute_changed = YES;
            DLog(@"[utun] net.inet.ip.scopedroute успешно отключен (0) в памяти ядра");
        } else {
            DLog(@"[utun] ошибка записи в адрес ядра 0x%llx", (unsigned long long)g_scopedroute_kaddr);
        }
    } else {
        DLog(@"[utun] не удалось найти адрес scopedroute в ядре");
    }
}

void DNRepairScopedRouteIfNeeded(void) {
    int value = 1;
    size_t size = sizeof(value);
    if (sysctlbyname("net.inet.ip.scopedroute", &value, &size, NULL, 0) != 0) return;
    if (value != 0) return;                       

    mach_port_t kt = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), 0, &kt) != KERN_SUCCESS || kt == MACH_PORT_NULL) {
        DLog(@"[utun] scopedroute нулевой с прошлого запуска, но tfp0 недоступен — не починить");
        return;
    }
    mach_vm_address_t addr = find_scopedroute_var_addr(kt);
    if (!addr) {
        DLog(@"[utun] scopedroute нулевой, адрес в ядре не нашёлся");
        return;
    }
    uint32_t one = 1;
    if (kwrite_safe(kt, addr, (vm_offset_t)&one, 4, is_kernel_64bit()) == KERN_SUCCESS) {
        DLog(@"[utun] scopedroute оставался нулевым с прошлого запуска — вернул 1");
    } else {
        DLog(@"[utun] не удалось вернуть scopedroute в 1");
    }
}

static void dn_restore_scopedroute(void) {
    if (!g_scopedroute_changed || g_scopedroute_kaddr == 0 || g_kt == MACH_PORT_NULL) return;
    uint32_t val = g_scopedroute_old;
    BOOL is64 = is_kernel_64bit();
    kwrite_safe(g_kt, g_scopedroute_kaddr, (vm_offset_t)&val, 4, is64);
    g_scopedroute_changed = NO;
    g_scopedroute_kaddr = 0;
    g_kt = MACH_PORT_NULL;
    DLog(@"[utun] net.inet.ip.scopedroute восстановлен (%u)", val);
}

#pragma mark - DNS (SCDynamicStore)

typedef const void *SCDynamicStoreRef;

static void *DNSym(const char *name) { return dlsym(RTLD_DEFAULT, name); }

static SCDynamicStoreRef SCDynamicStoreCreate_(CFAllocatorRef a, CFStringRef name, void *cb, void *ctx) {
    SCDynamicStoreRef (*fn)(CFAllocatorRef, CFStringRef, void *, void *) = DNSym("SCDynamicStoreCreate");
    return fn ? fn(a, name, cb, ctx) : NULL;
}
static CFPropertyListRef SCDynamicStoreCopyValue_(SCDynamicStoreRef st, CFStringRef key) {
    CFPropertyListRef (*fn)(SCDynamicStoreRef, CFStringRef) = DNSym("SCDynamicStoreCopyValue");
    return fn ? fn(st, key) : NULL;
}
static Boolean SCDynamicStoreSetValue_(SCDynamicStoreRef st, CFStringRef key, CFPropertyListRef v) {
    Boolean (*fn)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef) = DNSym("SCDynamicStoreSetValue");
    return fn ? fn(st, key, v) : false;
}
static Boolean SCDynamicStoreRemoveValue_(SCDynamicStoreRef st, CFStringRef key) {
    Boolean (*fn)(SCDynamicStoreRef, CFStringRef) = DNSym("SCDynamicStoreRemoveValue");
    return fn ? fn(st, key) : false;
}

static BOOL dn_primary_from_system(char *nameOut, size_t cap, struct in_addr *gwOut) {
    SCDynamicStoreRef store = SCDynamicStoreCreate_(NULL, CFSTR("Dante"), NULL, NULL);
    if (!store) return NO;
    CFDictionaryRef info = (CFDictionaryRef)SCDynamicStoreCopyValue_(store, CFSTR("State:/Network/Global/IPv4"));
    BOOL ok = NO;
    if (info) {
        CFStringRef iface = CFDictionaryGetValue(info, CFSTR("PrimaryInterface"));
        if (iface && CFStringGetCString(iface, nameOut, (CFIndex)cap, kCFStringEncodingUTF8)) {
            ok = YES;
            if (gwOut) {
                gwOut->s_addr = INADDR_ANY;          
                CFStringRef router = CFDictionaryGetValue(info, CFSTR("Router"));
                char text[64] = {0};
                if (router && CFStringGetCString(router, text, sizeof(text), kCFStringEncodingUTF8)) {
                    inet_aton(text, gwOut);
                }
            }
        }
        CFRelease(info);
    }
    CFRelease(store);
    return ok;
}

static NSString * const kDNSBackupKey       = @"State:/Network/Service/org.dante.utun/DNS_Backup";
static NSString * const kDNSBackupGlobalKey = @"State:/Network/Service/org.dante.utun/DNS_Backup_Global";
static NSString * const kDNSBackupServiceKey = @"State:/Network/Service/org.dante.utun/DNS_Backup_Service";

enum { kDNPacketMax = 4096 };

@interface DNUtunReader : NSObject {
@public
    int fd;
    volatile BOOL running;
    BOOL ownsThread;          
    uint8_t batch[32][kDNPacketMax];   
}
@end
@implementation DNUtunReader
@end

@implementation DanteUtun {
    int _fd;
    NSString *_ifname;
    struct in_addr _local, _peer, _endpoint, _oldGateway;
    BOOL _hostRoute;
    BOOL _splitRoutes;
    BOOL _dnsSet;
    NSArray *_dnsServers;
    NSMutableArray *_dnsBypass;   
    BOOL _kernelPatch;            
    DNUtunReader *_reader;
    BOOL _natMode;                
}

+ (instancetype)sharedUtun {
    static DanteUtun *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[DanteUtun alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fd = -1;
        gDNClampMSS = (uint16_t)[[NSUserDefaults standardUserDefaults] integerForKey:kDNClampKey];
        
        
        
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        gDNMergeLoops = [ud objectForKey:@"dante_merge"] ? (int)[ud integerForKey:@"dante_merge"] : 1;
    }
    return self;
}

- (NSUInteger)clampMSS { return gDNClampMSS; }

- (void)setClampMSS:(NSUInteger)mss {
    if (mss != 0 && (mss < 536 || mss > 1460)) return;
    gDNClampMSS = (uint16_t)mss;
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)mss forKey:kDNClampKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    DLog(@"[utun] MSS: %@", mss ? [NSString stringWithFormat:@"не больше %lu", (unsigned long)mss] : @"не трогаю");
}

- (BOOL)isUp {
    @synchronized (self) { return _fd >= 0; }
}

- (NSString *)interfaceName {
    @synchronized (self) { return _ifname; }
}

static BOOL DNParseIPv4(NSString *text, struct in_addr *out) {
    NSString *bare = [[text componentsSeparatedByString:@"/"] objectAtIndex:0];
    bare = [bare stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return bare.length && inet_aton([bare UTF8String], out) != 0;
}

static BOOL DNResolveEndpoint(NSString *endpoint, struct in_addr *out) {
    if ([endpoint hasPrefix:@"["]) return NO;   
    NSRange colon = [endpoint rangeOfString:@":" options:NSBackwardsSearch];
    NSString *host = colon.location == NSNotFound ? endpoint : [endpoint substringToIndex:colon.location];
    if (inet_aton([host UTF8String], out)) return YES;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo([host UTF8String], NULL, &hints, &res) != 0 || !res) return NO;
    *out = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
    freeaddrinfo(res);
    return YES;
}

- (BOOL)enableForConfig:(AWGConfig *)config error:(NSString **)error {
    struct in_addr local, endpoint;
    if (!DNParseIPv4(config.ipv4Address, &local)) {
        if (error) *error = [NSString stringWithFormat:@"нет IPv4-адреса в конфиге (%@)", config.ipv4Address];
        return NO;
    }
    if (!DNResolveEndpoint(config.peerEndpoint, &endpoint)) {
        if (error) *error = [NSString stringWithFormat:@"эндпоинт %@ не IPv4", config.peerEndpoint];
        return NO;
    }
    @synchronized (self) {
        if (_fd >= 0 && _local.s_addr == local.s_addr && _endpoint.s_addr == endpoint.s_addr) {
            return YES;
        }
    }
    [self disable];

    struct in_addr gw; gw.s_addr = INADDR_ANY;
    unsigned ifindex = 0;
    BOOL haveRoute = dn_default_route(&gw, &ifindex);
    if (haveRoute && gw.s_addr == INADDR_ANY) {
        
        char up[IFNAMSIZ] = {0};
        if (if_indextoname(ifindex, up) && dn_if_peer_addr(up, &gw)) {
            DLog(@"[utun] шлюз взят у интерфейса %s: %s", up, inet_ntoa(gw));
        } else {
            DLog(@"[utun] шлюза нет и второй конец линии не узнать — маршруты мимо туннеля не проложить");
        }
    }
    if (!haveRoute) {
        if (error) *error = @"нет маршрута по умолчанию (нет ни Wi‑Fi, ни сотовой связи?)";
        return NO;
    }

    char ifname[32] = {0};
    int fd = dn_utun_open(ifname, sizeof(ifname));
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"utun: %s", strerror(errno)];
        return NO;
    }
    int bufSize = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    
    uint32_t lh = ntohl(local.s_addr);
    uint32_t ph = (lh & 0xffffff00) | 1;
    if (ph == lh) ph = (lh & 0xffffff00) | 2;
    struct in_addr peer = dn_addr(ph);
    
    
    
    
    
    NSInteger mtuOverride = [[NSUserDefaults standardUserDefaults] integerForKey:@"dante_mtu"];
    int mtu = (mtuOverride >= 576 && mtuOverride <= 1500) ? (int)mtuOverride : 1400;

    if (dn_if_configure(ifname, local, peer, mtu) != 0) {
        if (error) *error = [NSString stringWithFormat:@"%s: адрес не назначился: %s", ifname, strerror(errno)];
        close(fd);
        return NO;
    }

    @synchronized (self) {
        _fd = fd;
        _ifname = [NSString stringWithUTF8String:ifname];
        _local = local;
        _peer = peer;
        _endpoint = endpoint;
        _oldGateway = gw;
    }

    
    [[AmneziaWGManager sharedManager] bindTunnelToInterfaceIndex:ifindex];

    
    DNUtunReader *reader = [[DNUtunReader alloc] init];
    reader->fd = fd;
    reader->running = YES;
    @synchronized (self) { _reader = reader; }
    [AmneziaWGManager sharedManager].rawPacketHandler = ^(const uint8_t *bytes, size_t length) {
        if (!reader->running || length == 0 || (bytes[0] >> 4) != 4) return;
        dn_clamp_mss((uint8_t *)bytes, length);   
        uint32_t family = htonl(AF_INET);
        struct iovec iov[2] = {
            { &family, sizeof(family) },
            { (void *)bytes, length },
        };
        ssize_t w = writev(reader->fd, iov, 2);
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)) {
            gDNUtunRetried++;
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(reader->fd, &wfds);
            struct timeval tv = {0, 10000}; 
            if (select(reader->fd + 1, NULL, &wfds, NULL, &tv) > 0) {
                w = writev(reader->fd, iov, 2);
            }
        }
        if (w > 0) gDNUtunWritten++; else gDNUtunDropped++;
    };
    if (gDNMergeLoops) {
        
        reader->ownsThread = NO;
        [AmneziaWGManager sharedManager].utunFd = fd;
        DLog(@"[utun] режим одного потока: чтение utun ведёт цикл туннеля");
    } else {
        reader->ownsThread = YES;
        NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(readLoop:) object:reader];
        [thread setStackSize:256 * 1024];
        [thread start];
    }

    
    
    
    
    struct in_addr hostMask; hostMask.s_addr = 0xffffffff;
    if (gw.s_addr == INADDR_ANY) {
        DLog(@"[utun] шлюза нет (сотовая связь) — точка входа держится привязкой сокета");
    } else if (dn_route(DN_RTM_ADD, DN_RTF_HOST | DN_RTF_GATEWAY, endpoint, hostMask, gw, 0) == 0
               || errno == EEXIST) {
        _hostRoute = YES;
    } else {
        DLog(@"[utun] host-маршрут к %s: %s", inet_ntoa(endpoint), strerror(errno));
    }

    
    [self syncDNSBypass];

    
    
    struct in_addr halfMask = dn_addr(0x80000000);
    BOOL lowOK = dn_route(DN_RTM_ADD, DN_RTF_GATEWAY, dn_addr(0), halfMask, peer, mtu) == 0 || errno == EEXIST;
    BOOL highOK = dn_route(DN_RTM_ADD, DN_RTF_GATEWAY, dn_addr(0x80000000), halfMask, peer, mtu) == 0 || errno == EEXIST;
    _splitRoutes = lowOK || highOK;
    if (!lowOK || !highOK) {
        if (error) *error = [NSString stringWithFormat:@"маршруты в %s: %s", ifname, strerror(errno)];
        [self disable];
        return NO;
    }

    
    
    
    
    
    _kernelPatch = [[NSUserDefaults standardUserDefaults] boolForKey:@"dante_kpatch"];
    if (_kernelPatch) {
        dn_disable_scopedroute();
        if (!g_scopedroute_changed) {
            nw_scope_set_primary(ifname, inet_ntoa(local), inet_ntoa(peer));
        }
    }

    NSMutableArray *dns = [NSMutableArray array];
    for (NSString *raw in [config.dnsServers componentsSeparatedByString:@","]) {
        struct in_addr a;
        if (DNParseIPv4(raw, &a)) [dns addObject:[NSString stringWithUTF8String:inet_ntoa(a)]];
    }
    if (dns.count == 0) dns = [NSMutableArray arrayWithObjects:@"1.1.1.1", @"1.0.0.1", nil];
    _dnsServers = dns;
    
    
    
    
    

    DLog(@"[utun] %s поднят: %s -> %s, MTU %d, шлюз Wi‑Fi %s (if %u), DNS системы не трогаю (%@ — только для своего стека)",
         ifname, [[NSString stringWithUTF8String:inet_ntoa(local)] UTF8String],
         [[NSString stringWithUTF8String:inet_ntoa(peer)] UTF8String], mtu,
         [[NSString stringWithUTF8String:inet_ntoa(gw)] UTF8String], ifindex,
         [dns componentsJoinedByString:@","]);
    {
        char l[INET_ADDRSTRLEN], r[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &local, l, sizeof(l));
        inet_ntop(AF_INET, &peer, r, sizeof(r));
        DCon(@"%s: %s -> %s mtu %d, warp", ifname, l, r, mtu);
    }
    return YES;
}

#pragma mark - Power: отражение пакетов

static const uint32_t kDNPowerLocal = 0xC6120001;   
static const uint32_t kDNPowerFake  = 0xC6120002;   

- (BOOL)powerMode {
    @synchronized (self) { return _fd >= 0 && _natMode; }
}

- (BOOL)enableForPowerServer:(NSString *)host error:(NSString **)error {
    struct in_addr server;
    if (!DNResolveEndpoint(host, &server)) {
        if (error) *error = [NSString stringWithFormat:@"адрес сервера %@ не разрешился", host];
        return NO;
    }
    @synchronized (self) {
        if (_fd >= 0 && _natMode && _endpoint.s_addr == server.s_addr) return YES;
    }
    [self disable];

    struct in_addr gw; gw.s_addr = INADDR_ANY;
    unsigned ifindex = 0;
    if (!dn_default_route(&gw, &ifindex)) {
        if (error) *error = @"нет маршрута по умолчанию (нет ни Wi‑Fi, ни сотовой связи?)";
        return NO;
    }
    if (gw.s_addr == INADDR_ANY) {
        char up[IFNAMSIZ] = {0};
        if (if_indextoname(ifindex, up) && dn_if_peer_addr(up, &gw)) {
            DLog(@"[utun] шлюз взят у интерфейса %s: %s", up, inet_ntoa(gw));
        }
    }

    char ifname[32] = {0};
    int fd = dn_utun_open(ifname, sizeof(ifname));
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"utun: %s", strerror(errno)];
        return NO;
    }
    int bufSize = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

    struct in_addr local = dn_addr(kDNPowerLocal), peer = dn_addr(kDNPowerFake);
    
    
    NSInteger mtuOverride = [[NSUserDefaults standardUserDefaults] integerForKey:@"dante_tun_mtu"];
    int mtu = (mtuOverride >= 576 && mtuOverride <= kDNPacketMax - 4) ? (int)mtuOverride : 1500;
    if (dn_if_configure(ifname, local, peer, mtu) != 0) {
        if (error) *error = [NSString stringWithFormat:@"%s: адрес не назначился: %s", ifname, strerror(errno)];
        close(fd);
        return NO;
    }
    DNNatConfigure(local, peer, kDanteTunTCPPort, kDanteDNSPort);
    NSString *listenErr = nil;
    if (![[DanteRedirector sharedRedirector] startTunListenersOn:local fake:peer error:&listenErr]) {
        if (error) *error = listenErr;
        close(fd);
        return NO;
    }

    DNUtunReader *reader = [[DNUtunReader alloc] init];
    reader->fd = fd;
    reader->running = YES;
    reader->ownsThread = YES;
    @synchronized (self) {
        _fd = fd;
        _ifname = [NSString stringWithUTF8String:ifname];
        _local = local;
        _peer = peer;
        _endpoint = server;
        _oldGateway = gw;
        _natMode = YES;
        _reader = reader;
    }
    
    PWSetBoundInterface(ifindex);
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(natLoop:) object:reader];
    [thread setStackSize:256 * 1024];
    [thread start];

    struct in_addr hostMask; hostMask.s_addr = 0xffffffff;
    if (gw.s_addr == INADDR_ANY) {
        DLog(@"[utun] шлюза нет — сервер держится привязкой сокетов к интерфейсу");
    } else if (dn_route(DN_RTM_ADD, DN_RTF_HOST | DN_RTF_GATEWAY, server, hostMask, gw, 0) == 0
               || errno == EEXIST) {
        _hostRoute = YES;
    } else {
        DLog(@"[utun] host-маршрут к серверу %s: %s", inet_ntoa(server), strerror(errno));
    }
    [self syncDNSBypass];

    struct in_addr halfMask = dn_addr(0x80000000);
    BOOL lowOK = dn_route(DN_RTM_ADD, DN_RTF_GATEWAY, dn_addr(0), halfMask, peer, mtu) == 0 || errno == EEXIST;
    BOOL highOK = dn_route(DN_RTM_ADD, DN_RTF_GATEWAY, dn_addr(0x80000000), halfMask, peer, mtu) == 0 || errno == EEXIST;
    _splitRoutes = lowOK || highOK;
    if (!lowOK || !highOK) {
        if (error) *error = [NSString stringWithFormat:@"маршруты в %s: %s", ifname, strerror(errno)];
        [self disable];
        return NO;
    }
    char serverText[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &server, serverText, sizeof(serverText));
    DLog(@"[utun] %s поднят под Power: весь TCP и DNS устройства — через сервер %s, MTU %d, канал if %u",
         ifname, serverText, mtu, ifindex);
    DCon(@"%s: 198.18.0.1 -> 198.18.0.2 mtu %d, nat on", ifname, mtu);
    return YES;
}

- (void)natLoop:(DNUtunReader *)reader {
    int fd = reader->fd;
    uint8_t *buf = reader->batch[0];
    while (reader->running) {
        @autoreleasepool {
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(fd, &fds);
            struct timeval tv = {0, 200000};
            int rc = select(fd + 1, &fds, NULL, NULL, &tv);
            if (rc < 0 && errno != EINTR) break;
            if (rc <= 0) continue;
            for (int p = 0; p < 64 && reader->running; p++) {
                ssize_t n = read(fd, buf, kDNPacketMax);
                if (n <= 0) {
                    if (n < 0 && errno == EINTR) continue;
                    break;
                }
                if (n <= 4 || !DNNatTranslate(buf + 4, (size_t)n - 4)) continue;
                ssize_t w = write(fd, buf, (size_t)n);
                if (w < 0 && (errno == EAGAIN || errno == ENOBUFS)) {
                    fd_set wfds;
                    FD_ZERO(&wfds);
                    FD_SET(fd, &wfds);
                    struct timeval wt = {0, 10000};
                    if (select(fd + 1, NULL, &wfds, NULL, &wt) > 0) write(fd, buf, (size_t)n);
                }
            }
        }
    }
    close(fd);
}

- (void)readLoop:(DNUtunReader *)reader {
    int fd = reader->fd;
    uint8_t buf[4096];
    while (reader->running) {
        @autoreleasepool {
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(fd, &fds);
            struct timeval tv = {0, 100000};
            int rc = select(fd + 1, &fds, NULL, NULL, &tv);
            if (rc < 0 && errno != EINTR) break;
            if (rc <= 0) continue;

            
            
            
            
            
            
            AWGRawPacket out[32];
            size_t nout = 0;
            int batchSize = gDNBatchSend;
            if (batchSize > 32) batchSize = 32;
            for (int p = 0; p < 32 && reader->running; p++) {
                
                
                uint8_t *buf = reader->batch[batchSize > 0 ? p : 0];
                ssize_t n = read(fd, buf, kDNPacketMax);
                if (n <= 0) {
                    if (n < 0 && errno == EINTR) continue;
                    break;
                }
                
                if (n <= 4 || (buf[4] >> 4) != 4) continue;
                dn_clamp_mss(buf + 4, (size_t)n - 4);   
                if (batchSize <= 0) {
                    [[AmneziaWGManager sharedManager] sendRawIPPacket:buf + 4 length:(size_t)n - 4];
                    continue;
                }
                out[nout].bytes = buf + 4;
                out[nout].length = (size_t)n - 4;
                if ((int)++nout >= batchSize) {
                    [[AmneziaWGManager sharedManager] sendRawIPPackets:out count:nout];
                    nout = 0;
                }
            }
            if (nout > 0) {
                [[AmneziaWGManager sharedManager] sendRawIPPackets:out count:nout];
            }
        }
    }
    
    close(fd);
}

- (void)disable {
    int fd;
    struct in_addr peer, endpoint, gw;
    BOOL hostRoute, split, dnsSet;
    NSString *ifname;
    DNUtunReader *reader;
    
    [AmneziaWGManager sharedManager].utunFd = -1;
    @synchronized (self) {
        fd = _fd;
        reader = _reader;
        _reader = nil;
        _fd = -1;
        peer = _peer; endpoint = _endpoint; gw = _oldGateway;
        hostRoute = _hostRoute; split = _splitRoutes; dnsSet = _dnsSet;
        _hostRoute = _splitRoutes = NO;
        ifname = _ifname;
        _ifname = nil;
        if (_natMode) PWSetBoundInterface(0);
        _natMode = NO;
    }
    if (dnsSet) [self restoreDNS];
    if (fd < 0 && !hostRoute && !split) return;

    [AmneziaWGManager sharedManager].rawPacketHandler = nil;
    struct in_addr halfMask = dn_addr(0x80000000);
    if (split) {
        dn_route(DN_RTM_DELETE, DN_RTF_GATEWAY, dn_addr(0), halfMask, peer, 0);
        dn_route(DN_RTM_DELETE, DN_RTF_GATEWAY, dn_addr(0x80000000), halfMask, peer, 0);
    }
    if (hostRoute) {
        struct in_addr hostMask; hostMask.s_addr = 0xffffffff;
        dn_route(DN_RTM_DELETE, DN_RTF_HOST | DN_RTF_GATEWAY, endpoint, hostMask, gw, 0);
    }
    if (_kernelPatch) {
        if (!g_scopedroute_changed) nw_scope_restore();
        dn_restore_scopedroute();
        _kernelPatch = NO;
    }
    [self removeDNSBypassVia:gw];
    
    if (reader) reader->running = NO;
    if ((!reader || !reader->ownsThread) && fd >= 0) close(fd);
    if (fd >= 0) {
        DLog(@"[utun] %@ снят", ifname);
        DCon(@"%@: detached", ifname);
    }
}

#pragma mark - DNS

static NSArray *DNSystemDNSServers(void) {
    SCDynamicStoreRef store = SCDynamicStoreCreate_(NULL, CFSTR("Dante"), NULL, NULL);
    if (!store) return @[];
    NSDictionary *g = CFBridgingRelease(SCDynamicStoreCopyValue_(store, CFSTR("State:/Network/Global/DNS")));
    CFRelease(store);
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *a in [g objectForKey:@"ServerAddresses"]) {
        struct in_addr ia;
        if ([a isKindOfClass:[NSString class]] && inet_aton([a UTF8String], &ia)) [out addObject:a];
    }
    return out;
}

- (void)syncDNSBypass {
    struct in_addr gw;
    @synchronized (self) {
        if (_fd < 0) return;
        gw = _oldGateway;
        if (!_dnsBypass) _dnsBypass = [NSMutableArray array];
    }
    NSArray *want = DNSystemDNSServers();
    struct in_addr hostMask; hostMask.s_addr = 0xffffffff;
    for (NSString *a in want) {
        if ([_dnsBypass containsObject:a]) continue;
        struct in_addr ia; inet_aton([a UTF8String], &ia);
        uint32_t h = ntohl(ia.s_addr);
        BOOL local = (h >> 24) == 10 || (h >> 20) == (172 << 4 | 1) || (h >> 16) == (192 << 8 | 168) ||
                     (h >> 24) == 127;
        if (local) continue;
        if (dn_route(DN_RTM_ADD, DN_RTF_HOST | DN_RTF_GATEWAY, ia, hostMask, gw, 0) == 0 || errno == EEXIST) {
            [_dnsBypass addObject:a];
            DLog(@"[utun] DNS %@ — мимо туннеля", a);
        } else {
            DLog(@"[utun] маршрут к DNS %@: %s", a, strerror(errno));
        }
    }
    for (NSString *a in [_dnsBypass copy]) {
        if ([want containsObject:a]) continue;
        struct in_addr ia; inet_aton([a UTF8String], &ia);
        dn_route(DN_RTM_DELETE, DN_RTF_HOST | DN_RTF_GATEWAY, ia, hostMask, gw, 0);
        [_dnsBypass removeObject:a];
    }
}

- (void)removeDNSBypassVia:(struct in_addr)gw {
    struct in_addr hostMask; hostMask.s_addr = 0xffffffff;
    for (NSString *a in _dnsBypass) {
        struct in_addr ia; inet_aton([a UTF8String], &ia);
        dn_route(DN_RTM_DELETE, DN_RTF_HOST | DN_RTF_GATEWAY, ia, hostMask, gw, 0);
    }
    [_dnsBypass removeAllObjects];
}

- (void)restoreDNS {
    SCDynamicStoreRef store = SCDynamicStoreCreate_(NULL, CFSTR("Dante"), NULL, NULL);
    if (!store) return;
    NSDictionary *meta = CFBridgingRelease(SCDynamicStoreCopyValue_(store, (__bridge CFStringRef)kDNSBackupServiceKey));
    if (meta) {
        NSString *svc = [meta objectForKey:@"Service"];
        NSDictionary *orig = CFBridgingRelease(SCDynamicStoreCopyValue_(store, (__bridge CFStringRef)kDNSBackupKey));
        if (svc.length && orig) {
            NSString *key = [NSString stringWithFormat:@"State:/Network/Service/%@/DNS", svc];
            if (orig.count) {
                SCDynamicStoreSetValue_(store, (__bridge CFStringRef)key, (__bridge CFDictionaryRef)orig);
            } else {
                SCDynamicStoreRemoveValue_(store, (__bridge CFStringRef)key);
            }
        }
        NSDictionary *origGlobal = CFBridgingRelease(SCDynamicStoreCopyValue_(store, (__bridge CFStringRef)kDNSBackupGlobalKey));
        if (origGlobal) {
            SCDynamicStoreSetValue_(store, CFSTR("State:/Network/Global/DNS"), (__bridge CFDictionaryRef)origGlobal);
        } else {
            SCDynamicStoreRemoveValue_(store, CFSTR("State:/Network/Global/DNS"));
        }
        SCDynamicStoreRemoveValue_(store, (__bridge CFStringRef)kDNSBackupKey);
        SCDynamicStoreRemoveValue_(store, (__bridge CFStringRef)kDNSBackupGlobalKey);
        SCDynamicStoreRemoveValue_(store, (__bridge CFStringRef)kDNSBackupServiceKey);
        DLog(@"[utun] DNS системы возвращён");
    }
    CFRelease(store);
    @synchronized (self) { _dnsSet = NO; }
}

- (void)restoreLeftovers {
    if (self.isUp) return;
    [self restoreDNS];
    DNRepairScopedRouteIfNeeded();
}

- (void)reassertDNS {
    
    [self syncDNSBypass];
}

@end
