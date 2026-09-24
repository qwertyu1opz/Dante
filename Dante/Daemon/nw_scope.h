#ifndef NW_SCOPE_H
#define NW_SCOPE_H

int nw_scope_probe(void);

int nw_scope_set_primary(const char *ifname, const char *addr, const char *router);

int nw_scope_restore(void);

int nw_scope_set_dns(const char *dns_servers_csv);

int nw_scope_restore_dns(void);

#endif 
