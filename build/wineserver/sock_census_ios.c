/*
 * [sock-census] (Madeira, LOG ONLY, Battle.net launcher freeze)
 *
 * This file IS server/sock.c: it includes the submodule's sock.c unchanged
 * and appends one read-only helper that needs struct sock, which is private
 * to sock.c. build.sh compiles this file in place of sock.c (same sock.o,
 * same REPLACEMENTS entry), so sock.c itself carries no new edit and the
 * patch cannot conflict with the fork's own sock.c probes.
 *
 * The quoted includes inside sock.c ("file.h", "request.h", ...) resolve
 * against sock.c's own directory first, exactly as a direct compile.
 */
#include "../../wine/server/sock.c"

/* Fills out[IOS_SC_N] and a short text for one fd user, if it is a socket.
 * Returns 0 (and touches nothing) for any other object. Changes no state:
 * sock_get_poll_events only computes, and no queue or list is modified.
 *
 * out[] layout (keep in step with fd_ios.c ios_sock_census):
 *  0 want     events sock_get_poll_events() asks for right now (-1 = none)
 *  1 rwait    a read async is really waiting (async_waiting(read_q))
 *  2 rqueued  read_q is not empty (waiting or terminated-not-yet-reaped)
 *  3 wwait    a write async is really waiting
 *  4 preqs    pending AFD poll requests that name this socket
 *  5 pread    one of those asks for AFD_POLL_READ (or HUP/RESET/CLOSE)
 *  6 await    accept_q waiting, 7 cwait connect_q waiting
 *  8 mask, 9 pending_events, 10 reported_events
 *  11 state (enum connection_state), 12 is-stream-inet, 13 peer port
 */
#define IOS_SC_N 16
int ios_sock_census_info( void *user, int *out, char *desc, size_t len );
int ios_sock_census_info( void *user, int *out, char *desc, size_t len )
{
    struct object *obj = user;
    struct sock *sock;
    struct poll_req *req;
    static const char * const state_name[] =
        { "listening", "unconnected", "connecting", "connected", "connectionless" };
    const char *st, *fam, *type;
    int i, port = 0;

    if (!obj || obj->ops != &sock_ops) return 0;
    sock = (struct sock *)obj;
    for (i = 0; i < IOS_SC_N; i++) out[i] = 0;

    out[0] = (sock->fd && sock->type) ? sock_get_poll_events( sock->fd ) : -1;
    out[1] = async_waiting( &sock->read_q );
    out[2] = !list_empty( &sock->read_q.queue );
    out[3] = async_waiting( &sock->write_q );
    LIST_FOR_EACH_ENTRY( req, &poll_list, struct poll_req, entry )
    {
        unsigned int j;
        if (req->iosb->status != STATUS_PENDING) continue;
        for (j = 0; j < req->count; ++j)
        {
            if (req->sockets[j].sock != sock) continue;
            out[4]++;
            if (req->sockets[j].mask & (AFD_POLL_READ | AFD_POLL_HUP | AFD_POLL_RESET | AFD_POLL_CLOSE))
                out[5] = 1;
        }
    }
    out[6] = async_waiting( &sock->accept_q );
    out[7] = async_waiting( &sock->connect_q );
    out[8] = (int)sock->mask;
    out[9] = (int)sock->pending_events;
    out[10] = (int)sock->reported_events;
    out[11] = (int)sock->state;
    out[12] = sock->type == WS_SOCK_STREAM && (sock->family == WS_AF_INET || sock->family == WS_AF_INET6);
    /* remote PORT only: no address goes into a log that players share */
    if (sock->peer_addr.addr.sa_family == WS_AF_INET) port = ntohs( sock->peer_addr.in.sin_port );
    else if (sock->peer_addr.addr.sa_family == WS_AF_INET6) port = ntohs( sock->peer_addr.in6.sin6_port );
    out[13] = port;

    st = (unsigned int)sock->state < sizeof(state_name) / sizeof(state_name[0])
         ? state_name[sock->state] : "?";
    fam = sock->family == WS_AF_INET ? "inet" : sock->family == WS_AF_INET6 ? "inet6"
        : sock->family == 1 /* AF_UNIX on Windows too */ ? "unix" : "other";
    type = sock->type == WS_SOCK_STREAM ? "tcp" : sock->type == WS_SOCK_DGRAM ? "udp" : "other";
    snprintf( desc, len, "%s-%s %s peer-port=%d mask=%x pend=%x rep=%x%s%s%s%s%s%s",
              fam, type, st, port, sock->mask, sock->pending_events, sock->reported_events,
              sock->rd_shutdown ? " rd-shut" : "", sock->wr_shutdown ? " wr-shut" : "",
              sock->hangup ? " hangup" : "", sock->aborted ? " aborted" : "",
              sock->reset ? " reset" : "", sock->nonblocking ? " nonblock" : "" );
    return 1;
}
