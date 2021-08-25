### QUIC (Quick UDP Internet Connections)
This document contains notes about Node.js's QUIC implementation, ngtcp2, and
nghttp3.

#### Background
HTTP/2 addressed a number of short comings in HTTP/1 and one of the primary
features of HTTP/2 is its use of multiplexing. This is allowing multiple logical
streams of data being sent over the same physical connection.
Browsers now typically use one TCP connection to each host instead of previously
using six.

HTTP/2 fixed the HEAD on line blocking problem in HTTP/1 where clients had to
wait for the first response from the first request before sending another. HTTP/1
browsers would typically use more connections to get around this (like 6 of them).

HTTP/2 over TCP multiplexes and pipelines request over one connection but if a
single packet is dropped or lost somewhere on the way to between two endpoints
that use HTTP/2, the entire TCP connection is halted while the lost packet is
retransmitted.  This is called TCP head of line blocking.

With QUIC streams are treated independently and they don't affect each other.

The original QUIC protocol developed by Google transported HTTP/2 frames. For
the standardization in IETF it was required that it not be bound to HTTP/2 only,
so there are two layers, "The QUIC transport" and "HTTP over QUIC" (sometimes
referred to as "hq"). HTTP-over-QUIC was renamed to HTTP/3 in November 2018.

While UDP is not a reliable transport, QUIC adds a layer on top of UDP that
introduces reliability. It offers re-transmissions of packets,
congestion control, pacing and the other features otherwise present in TCP.

A connection is a negotiated setup between two end-points similar to how a TCP
connection works. A QUIC connection is made to a UDP port and IP address, but
once established the connection is associated by its "connection ID".
Over an established connection, either side can create streams and send data
to the other end. Streams are delivered in-order and they are reliable, but
different streams may be delivered out-of-order. So one stream does not affect
the other.

Early data allows a QUIC client to send data in the 0-RTT handshake.

### Specifications
* [Version-Independent Properties of QUIC](https://tools.ietf.org/html/draft-ietf-quic-invariants-07)
* [QUIC: A UDP-Based Multiplexed and Secure Transport](https://tools.ietf.org/html/draft-ietf-quic-transport-23)
* [QUIC Loss Detection and Congestion Control](https://tools.ietf.org/html/draft-ietf-quic-recovery-23)
* [Using TLS to Secure QUIC](https://tools.ietf.org/html/draft-ietf-quic-tls-23)
* [Hypertext Transfer Protocol Version 3 (HTTP/3)](https://tools.ietf.org/html/draft-ietf-quic-http-23)
* [QPACK: Header Compression for HTTP/3](https://tools.ietf.org/html/draft-ietf-quic-qpack-10)

### ngtcp3 example walkthrough
This section will attempt to walk through the ngtcp2 client/server example and
explain what is going on (roughly). This will be done by first stepping through
the server until the point where it is listening for connections. At this point
we will turn our attention to the client side as it is one that initiates
the connection to the server.

First, we need to create a private key and a cerificate for the server:
```console
$ cd examples
$ openssl req -nodes -new -x509 -keyout server.key -out server.cert
```

#### server example startup
Lets start with the server:
```console
$ lldb -- ./examples/server --show-secret localhost 7777 examples/server.key examples/server.cert
(lldb) br s -n main
```

After the arguments have been parsed the ssl context will be initialized passing
in the private key and the certificate.
```c
TLSServerContext tls_ctx;

if (tls_ctx.init(private_key_file, cert_file, AppProtocol::H3) != 0) {
  exit(EXIT_FAILURE);
}
```
server.cc includes `tls_server_context.h` which conditionally includes one of
the tls_context implementations:
```c
#if defined(ENABLE_EXAMPLE_OPENSSL) && defined(WITH_EXAMPLE_OPENSSL)
#  include "tls_server_context_openssl.h"
#endif // ENABLE_EXAMPLE_OPENSSL && WITH_EXAMPLE_OPENSSL

#if defined(ENABLE_EXAMPLE_GNUTLS) && defined(WITH_EXAMPLE_GNUTLS)
#  include "tls_server_context_gnutls.h"
#endif // ENABLE_EXAMPLE_GNUTLS && WITH_EXAMPLE_GNUTLS

#if defined(ENABLE_EXAMPLE_BORINGSSL) && defined(WITH_EXAMPLE_BORINGSSL)
#  include "tls_server_context_boringssl.h"
#endif // ENABLE_EXAMPLE_BORINGSSL && WITH_EXAMPLE_BORINGSSL
```
In this case I'm using OpenSSL so lets take a closer look at it's init method.

The TLSServerContext for OpenSSL is defined as follows:
```
class TLSServerContext {
public:
  TLSServerContext();
  ~TLSServerContext();

  int init(const char *private_key_file, const char *cert_file,
           AppProtocol app_proto);

  SSL_CTX *get_native_handle() const;

  void enable_keylog();

private:
  SSL_CTX *ssl_ctx_;
};
```
Notice that there is an `SSL_CTX` which is what the get_native_handle function
returns. The BoringSSL implementation also uses SSL_CTX but the gnutls does not
which makes sense. 

`examples/tls_server_context_openssl.cc`

The first things that happens in `TLSServerContext::init` is that a new
SSL_CTX object is created. SSL_CTX is used to establish TLS connections. The
TLS_method() passed is the connection method. OpenSSL has a generic TLS_METHOD()
but also client and server specific methods named TLS_client_method() and
TLS_server_method.

If we take a look in `openssl/include/openssl/ssl.h` we find:
```c
__owur const SSL_METHOD *TLS_method(void);
__owur const SSL_METHOD *TLS_server_method(void);
__owur const SSL_METHOD *TLS_client_method(void);
```
`__owur` is a macro that is only used when the flag `DEBUG_UNUSED` is set at 
compile time (`-D"DEBUG_UNUSED=true"`) for OpenSSL. If enabled it will report
a compiler warning if a call to these functions do not use the returned value.

If you go looking for TLS_method() you will not find it in the source code as it
is generated by a macro (so it will be generated by the preprocessor). This
macro can be found in `ssl/ssl_locl.h`.
In `ssl/methods.c` we have:
```c
IMPLEMENT_tls_meth_func(TLS_ANY_VERSION, 0, 0,
                        TLS_method,
                        ossl_statem_accept,
                        ossl_statem_connect, TLSv1_2_enc_data)
```
Notice that this is where `TLS_method` is generated by using the
`IMPLEMENT_tls_meth_func` macro.
The arguments are `version`, `flags`, `mask`, `function name`, `s_accept`,
`s_connect`, `enc_data`.

```c
const SSL_METHOD *TLS_method(void) {
  static const SSL_METHOD TLS_method_data= {
    ...
  };

  return &TLS_method_data;
}
```

We can verify this using:
```console
(lldb) expr *TLS_method()
(SSL_METHOD) $7 = {
  version = 65536
  flags = 0
  mask = 0
  ssl_new = 0x00000001002b4e70 (libssl.3.dylib`tls1_new at t1_lib.c:105)
  ssl_clear = 0x00000001002b4f20 (libssl.3.dylib`tls1_clear at t1_lib.c:121)
  ssl_free = 0x00000001002b4ee0 (libssl.3.dylib`tls1_free at t1_lib.c:115)
  ssl_accept = 0x00000001002e0250 (libssl.3.dylib`ossl_statem_accept at statem.c:255)
  ssl_connect = 0x00000001002dfbd0 (libssl.3.dylib`ossl_statem_connect at statem.c:250)
  ssl_read = 0x000000010028eb20 (libssl.3.dylib`ssl3_read at s3_lib.c:4482)
  ssl_peek = 0x000000010028ec90 (libssl.3.dylib`ssl3_peek at s3_lib.c:4487)
  ssl_write = 0x000000010028e9e0 (libssl.3.dylib`ssl3_write at s3_lib.c:4441)
  ssl_shutdown = 0x000000010028e840 (libssl.3.dylib`ssl3_shutdown at s3_lib.c:4390)
  ssl_renegotiate = 0x000000010028ecd0 (libssl.3.dylib`ssl3_renegotiate at s3_lib.c:4492)
  ssl_renegotiate_check = 0x000000010028ea50 (libssl.3.dylib`ssl3_renegotiate_check at s3_lib.c:4509)
  ssl_read_bytes = 0x00000001002c6950 (libssl.3.dylib`ssl3_read_bytes at rec_layer_s3.c:1271)
  ssl_write_bytes = 0x00000001002c3dd0 (libssl.3.dylib`ssl3_write_bytes at rec_layer_s3.c:343)
  ssl_dispatch_alert = 0x000000010028ffc0 (libssl.3.dylib`ssl3_dispatch_alert at s3_msg.c:74)
  ssl_ctrl = 0x000000010028b650 (libssl.3.dylib`ssl3_ctrl at s3_lib.c:3383)
  ssl_ctx_ctrl = 0x000000010028c810 (libssl.3.dylib`ssl3_ctx_ctrl at s3_lib.c:3750)
  get_cipher_by_char = 0x000000010028db70 (libssl.3.dylib`ssl3_get_cipher_by_char at s3_lib.c:4094)
  put_cipher_by_char = 0x000000010028dbb0 (libssl.3.dylib`ssl3_put_cipher_by_char at s3_lib.c:4101)
  ssl_pending = 0x00000001002c3600 (libssl.3.dylib`ssl3_pending at rec_layer_s3.c:112)
  num_ciphers = 0x000000010028b200 (libssl.3.dylib`ssl3_num_ciphers at s3_lib.c:3262)
  get_cipher = 0x000000010028b210 (libssl.3.dylib`ssl3_get_cipher at s3_lib.c:3267)
  get_timeout = 0x00000001002b4e60 (libssl.3.dylib`tls1_default_timeout at t1_lib.c:96)
  ssl3_enc = 0x000000010030f070
  ssl_version = 0x00000001002a4d60 (libssl.3.dylib`ssl_undefined_void_function at ssl_lib.c:3824)
  ssl_callback_ctrl = 0x000000010028c760 (libssl.3.dylib`ssl3_callback_ctrl at s3_lib.c:3722)
  ssl_ctx_callback_ctrl = 0x000000010028d6b0 (libssl.3.dylib`ssl3_ctx_callback_ctrl at s3_lib.c:3994)
}
```
I was wondering about the difference between TLS_method and TLS_server_method,
and the TLS_client_method.
```c
IMPLEMENT_tls_meth_func(TLS_ANY_VERSION, 0, 0,
                        TLS_server_method,
                        ossl_statem_accept,
                        ssl_undefined_function, TLSv1_2_enc_data)
```
Notice that this has `ssl_undefined_function` instead of `ossl_statem_connect`.
And `TLS_client_method` looks like this:
```c
IMPLEMENT_tls_meth_func(TLS_ANY_VERSION, 0, 0,
                        TLS_client_method,
                        ssl_undefined_function,
                        ossl_statem_connect, TLSv1_2_enc_data)
```
And here we can see that it does not have a accept function.
So what are these `ossl_statem_accept` and `ossl_statem_connect`?  
We'll the names imply some kind of state machines and their implementation look
like this:

```c
int ossl_statem_accept(SSL *s) {
    return state_machine(s, 1);
}
int ossl_statem_connect(SSL *s) {
    return state_machine(s, 0);
}
```
So they are both calling state_machine but with setting the `server` parameter
to 1 and 0 (for the client).
The functions `ossl_statem_accept` and `ossl_statem_connect` are only used in
`ssl/statem/statem_lib.c` as far as I can tell. The `tls_finish_handshake`
function has the following if statement:
```c
if (s->server) {
  ...
  s->handshake_func = ossl_statem_accept;
} else {
  ...
  s->handshake_func = ossl_statem_connect;
}
```
So for a server `s->handshake_func` would be `ossl_statem_accept` which just
calls `state_machine(s, 1)` and for a client it would be `ossl_statem_connect`
which calls `state_machine(s, 0)`.

So it looks like setting both, as in using TLS_method(), is not neccessary and
it should be safe to use TLS_client_method(), TLS_server_method() instead.

So this `SSL_METHOD` will be passed to `SSL_CTX_new`.
```c
  SSL_CTX *ret = NULL;
  ...
  ret = OPENSSL_zalloc(sizeof(*ret));
```
Note `zalloc` will call memset to zero out the memory before returning.
Next, the SSL_CTX object will be populated.

The following SSL options are used:
```
  constexpr auto ssl_opts = (SSL_OP_ALL & ~SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS) |
                            SSL_OP_SINGLE_ECDH_USE |
                            SSL_OP_CIPHER_SERVER_PREFERENCE |
                            SSL_OP_NO_ANTI_REPLAY;
  SSL_CTX_set_options(ssl_ctx, ssl_opts);
```
SSL_OP_ALL include bug workarounds:
```c
# define SSL_OP_ALL (SSL_OP_CRYPTOPRO_TLSEXT_BUG|\
                     SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS|\
                     SSL_OP_LEGACY_SERVER_CONNECT|\
                     SSL_OP_TLSEXT_PADDING|\
                     SSL_OP_SAFARI_ECDHE_ECDSA_BUG)
```
```
if (SSL_CTX_set1_groups_list(ssl_ctx, config.groups) != 1) {
```
In versions of TLS prior to 1.3 this extention was named `elliptic_curves`.
```console
(lldb) expr config.groups
(const char *) $8 = 0x0000000100080500 "P-256:X25519:P-384:P-521"
```
```c
SSL_CTX_set_mode(ssl_ctx, SSL_MODE_RELEASE_BUFFERS);
SSL_CTX_set_min_proto_version(ssl_ctx, TLS1_3_VERSION);
SSL_CTX_set_max_proto_version(ssl_ctx, TLS1_3_VERSION);

  switch (app_proto) {
  case AppProtocol::H3:
    SSL_CTX_set_alpn_select_cb(ssl_ctx_, alpn_select_proto_h3_cb, nullptr);
    break;
  case AppProtocol::HQ:
    SSL_CTX_set_alpn_select_cb(ssl_ctx_, alpn_select_proto_hq_cb, nullptr);
    break;
  case AppProtocol::Perf:
    SSL_CTX_set_alpn_select_cb(ssl_ctx_, alpn_select_proto_perf_cb, nullptr);
    break;
  }
```
`SSL_CTX_set_alpn_select_cb` sets a callback on the ssl context that will
be called during the ClientHello processing to select the ALPN protocol from
the client's list of offered protocols. The nullptr is the argument to the
callback which we don't have any of these callbacks. 
The different application protocols are 'h3' which is QUIC over HTTP/3, 'hq'
which is QUIC over HTTP/2 (I think). 

Next, we have:
```c
  SSL_CTX_set_default_verify_paths(ssl_ctx);
```
This sets the default location from where CA certs are loaded.

```c

  SSL_CTX_set_session_id_context(ssl_ctx, sid_ctx, sizeof(sid_ctx) - 1);
```
The above sets the SSL session id.

```console
(lldb) expr sid_ctx
(const unsigned char [14]) $11 = "ngtcp2 server"
```
This bacially does the following:
```c
  memcpy(ctx->sid_ctx, sid_ctx, sid_ctx_len);
```
Next, we have:
```c
  SSL_CTX_set_max_early_data(ssl_ctx, std::numeric_limits<uint32_t>::max());
  SSL_CTX_set_quic_method(ssl_ctx, &quic_method);
```
Lets take a cloer look at `SSL_CTX_set_quic_method` which is a function that
exists in the fork of OpenSSL (also in quictls/openssl).
Looking at `openssl/include/openssl/ssl.h` we have the following functions and
structs:
```c
typedef enum ssl_encryption_level_t {
  ssl_encryption_initial = 0,
  ssl_encryption_early_data,
  ssl_encryption_handshake,
  ssl_encryption_application
} OSSL_ENCRYPTION_LEVEL;

struct ssl_quic_method_st {
  int (*set_encryption_secrets)(SSL *ssl, OSSL_ENCRYPTION_LEVEL level,
                                const uint8_t *read_secret,
                                const uint8_t *write_secret, size_t secret_len);
  int (*add_handshake_data)(SSL *ssl, OSSL_ENCRYPTION_LEVEL level,
                            const uint8_t *data, size_t len);
  int (*flush_flight)(SSL *ssl);
  int (*send_alert)(SSL *ssl, enum ssl_encryption_level_t level, uint8_t alert);
};

int SSL_CTX_set_quic_method(SSL_CTX *ctx, const SSL_QUIC_METHOD *quic_method);
int SSL_set_quic_method(SSL *ssl, const SSL_QUIC_METHOD *quic_method);
int SSL_set_quic_transport_params(SSL *ssl,
                                  const uint8_t *params,
                                  size_t params_len);
```
a SSL_CTX is used as a framework for establishing TLS connections. An SSL object
is a network connection assigned. So it looks like we can have SSL_QUIC_METHODS
for the context, as well as for each individual TLS connection.

```c
void SSL_get_peer_quic_transport_params(const SSL *ssl,
                                        const uint8_t **out_params,
                                        size_t *out_params_len);
size_t SSL_quic_max_handshake_flight_len(const SSL *ssl, OSSL_ENCRYPTION_LEVEL level);
OSSL_ENCRYPTION_LEVEL SSL_quic_read_level(const SSL *ssl);
OSSL_ENCRYPTION_LEVEL SSL_quic_write_level(const SSL *ssl);
int SSL_provide_quic_data(SSL *ssl, OSSL_ENCRYPTION_LEVEL level,
                                 const uint8_t *data, size_t len);
int SSL_process_quic_post_handshake(SSL *ssl);
int SSL_is_quic(SSL *ssl);

void SSL_set_quic_early_data_enabled(SSL *ssl, int enabled);
```

So we were looking at:
```c
SSL_CTX_set_quic_method(ssl_ctx, &quic_method);
```
This is bacially just setting ctx->quic_method.
So with the ssl context created we will use that to create an instance of the
Server:
```c
Server s(EV_DEFAULT, ssl_ctx);
```
```c
  token_aead_.native_handle = const_cast<EVP_CIPHER *>(EVP_aes_128_gcm());
  token_md_.native_handle = const_cast<EVP_MD *>(EVP_sha256());

  auto dis = std::uniform_int_distribution<uint8_t>(0, 255);
  std::generate(std::begin(token_secret_), std::end(token_secret_),
                [&dis]() { return dis(randgen); });
```
Notice that we generate a token_secret_ for the server.
TODO: how is this used?  

Next, we will call `server::init` passing in the address and port to be used.
and call `init`, followed by `ev_run`.
```c++
Server s(EV_DEFAULT, ssl_ctx);
  if (s.init(addr, port) != 0) {
    exit(EXIT_FAILURE);
  }

  ev_run(EV_DEFAULT, 0);
```
Each server instance has an endpoints_ member which is declared in `server.h`:
```c++
std::vector<Endpoint> endpoints_;

// Endpoint is a local endpoint.
struct Endpoint {
  Address addr;
  ev_io rev;
  Server *server;
  int fd;
};
```
`Server::init` will allocated space for 4 endpoints, but only two are added in 
our case, one for ipv4 and one for ipv6.

```c++
endpoints_.reserve(4);
```
After this, endpoints will be added by:
```c++
add_endpoint(endpoints_, addr, port, AF_INET) == 0)
```
First, `add_endpoint` will create a socket:
```c++
auto fd = socket(addr.su.sa.sa_family, SOCK_DGRAM, 0);
```
This file descriptor will then be bound and a new Endpoint will be created
and populated:
```c++
  endpoints.emplace_back(Endpoint{});
  auto &ep = endpoints.back();
  ep.addr = addr;
  ep.fd = fd;
  ev_io_init(&ep.rev, sreadcb, 0, EV_READ);
```
Notice that is is here that the Endpoint's get there `sreadcb` which is the
servers read callback. So when there is something to be read libev will
call `sreadcb`. `ep.rev` is of type `ev_io` which is a io watcher.

Next, these two endpoints are set up to be used by libev:
```c++
 for (auto &ep : endpoints_) {
    ep.server = this;
    ep.rev.data = &ep;
    ev_io_set(&ep.rev, ep.fd, EV_READ);
    ev_io_start(loop_, &ep.rev);
  }
```
Just showing `sreadcb` here and we will return to it when the client connects.
```c
void sreadcb(struct ev_loop *loop, ev_io *w, int revents) {
  auto ep = static_cast<Endpoint *>(w->data);
  ep->server->on_read(*ep);
}
```

So, the server is now listening for incoming connections. Let turn our attention
to the client:
```console
$ lldb -- ./examples/client localhost 7777
(lldb) br s -n main
(lldb) r
```
Ignoring the parsing of options and configuration we are going to take a look
at the `create_ssl_ctx`:
```c
auto ssl_ctx = create_ssl_ctx(private_key_file, cert_file);
```
In our case `private_key_file` and `cert_file` will both be null. There are a
couple of function calls that are common to both the client and the server
but also some differences. But the context is created and returned. 
This is then passed into the Client constructor:
```c
  Client c(EV_DEFAULT, ssl_ctx);
```
Notice that a client has an `ssl_` instance in addition to a context. It used
the ssl context to create a connection and the `ssl_` instance is set when
there is a connection (verify this as I'm just guessing at the moment).
Each client has a `sendbuf_`.
The constructor's body will then do the following:
```c
  ev_io_init(&wev_, writecb, 0, EV_WRITE);
  ev_io_init(&rev_, readcb, 0, EV_READ);
```
So we are initializing libev io watchers for READ and WRITE events, and associating
the callbacks `readcb` and `writecb` with these events.
```c
  ev_io wev_;
  ev_io rev_;
  wev_.data = this;
  rev_.data = this;
```
The data will be the Client instance that being created. So this will be available
to the watcher/callback functions. 

Next, we have a few timers that are initilized:
```c
  ev_timer_init(&timer_, timeoutcb, 0., config.timeout / 1000.);
  timer_.data = this;

  ev_timer_init(&rttimer_, retransmitcb, 0., 0.);
  rttimer_.data = this;

  ev_timer_init(&change_local_addr_timer_, change_local_addrcb,
                config.change_local_addr, 0.);
  change_local_addr_timer_.data = this;

  ev_timer_init(&key_update_timer_, key_updatecb, config.key_update, 0.);
  key_update_timer_.data = this;

  ev_timer_init(&delay_stream_timer_, delay_streamcb, config.delay_stream, 0.);
  delay_stream_timer_.data = this;
```
After the client object has been created `run` is called with it:
```c
  if (run(c, addr, port) != 0) {
    exit(EXIT_FAILURE);
  }
```

```c
  auto fd = create_sock(remote_addr, addr, port);
  bind_addr(local_addr, fd, remote_addr.su.sa.sa_family);
  c.init(fd, local_addr, remote_addr, addr, port, config.version);
```
In Client::init the callback for ngtcp2 will be specified:
```c
  auto callbacks = ngtcp2_conn_callbacks{
  ...
  };
```
```c
  auto dis = std::uniform_int_distribution<uint8_t>(
      0, std::numeric_limits<uint8_t>::max());

  auto generate_cid = [&dis](ngtcp2_cid &cid, size_t len) {
    cid.datalen = len;
    std::generate(std::begin(cid.data), std::begin(cid.data) + cid.datalen,
                  [&dis]() { return dis(randgen); });
  };

  ngtcp2_cid scid, dcid;
  generate_cid(scid, 17);
  if (config.dcid.datalen == 0) {
    generate_cid(dcid, 18);
  } else {
    dcid = config.dcid;
  }
```
Above we are generating the source connection id and the destination connection
id. Not that we only generate the destination connection id if it was not
configure which would be the case if we are trying to use a previous session
token. TODO: take a closer look at how that works. 

Next we have the ngtcp2 settings and transport params:
```c
  ngtcp2_settings settings;
  ngtcp2_settings_default(&settings);
  ...
```
After that we create a new ngtcp2 client connection:
```c
  rv = ngtcp2_conn_client_new(&conn_, &dcid, &scid, &path, version, &callbacks,
                              &settings, nullptr, this);
```
`nullptr` is ngtcp2_mem which will just use the default implementation
(ngtcp2_mem_default()). And notice that `user_data` is set to `this`.

After we call `conn_new` (TODO: add details from other notes) we set the following
members on the connection: 
```c
  (*pconn)->rcid = *dcid;
  (*pconn)->state = NGTCP2_CS_CLIENT_INITIAL;
  (*pconn)->local.bidi.next_stream_id = 0;
  (*pconn)->local.uni.next_stream_id = 2;
```

After this we are back in Client::init and have the following call:
```c
  if (init_ssl() != 0) {
```
And in `init_ssl()`:
```c
  ssl_ = SSL_new(ssl_ctx_);
```
This will create a new SSL instance using information from the passed in context.
For example:
```c
  s->options = ctx->options;
  s->dane.flags = ctx->dane.flags;
  s->min_proto_version = ctx->min_proto_version;
  s->max_proto_version = ctx->max_proto_version;
```
A SSL instance has a proint to the context:
```c
s->ctx = ctx;
```
The SSL instance will get the method from the context:
```c
s->method = ctx->method;
```
```c
s->method->ssl_new(s)
```
```c
ossl_statem_clear(s);
```
This clears/initializes the OpenSSL state machine:
```c
void ossl_statem_clear(SSL *s) {
  s->statem.state = MSG_FLOW_UNINITED;
  s->statem.hand_state = TLS_ST_BEFORE;
  s->statem.in_init = 1;
  s->statem.no_cert_verify = 0;
}
```
Just notice what the initial state is.

For quic the `quic_method` is set:
```c
s->quic_method = ctx->quic_method;
```

After the SSL instance has been created we set the app data:
```c
SSL_set_app_data(ssl_, this);
```
Note that this i macro:
```c
# define SSL_set_app_data(s,arg)  (SSL_set_ex_data(s,0,(char *)(arg)))
```

Next, we set the connect state:
```c
SSL_set_connect_state(ssl_);
```

```c
  s->server = 0;
  s->shutdown = 0;
  ossl_statem_clear(s);
  s->handshake_func = s->method->ssl_connect;
  clear_ciphers(s);
```
```console
(lldb) expr s->method->ssl_connect
(int (*const)(SSL *)) $4 = 0x0000000100275bd0 (libssl.3.dylib`ossl_statem_connect at statem.c:250)
```
Back in Client::init we have:
```c
rv = setup_initial_crypto_context();
```

After Client::init we are back in the `run` function:
```c
  auto rv = c.on_write();
```

In `Client::on_write` we have the following call:
```
auto rv = write_streams();
```
`Client::write_streams` 

```c
auto nwrite = ngtcp2_conn_writev_stream(
    conn_, &path.path, sendbuf_.wpos(), max_pktlen_, &ndatalen,
    NGTCP2_WRITE_STREAM_FLAG_MORE, stream_id, fin,
    reinterpret_cast<const ngtcp2_vec *>(v), vcnt, util::timestamp(loop_));
```
This will take us into `ngtcp2_conn.c` which has a switch statement using the
`conn->state` (which is currently initial)

```c
nwrite = ngtcp2_conn_client_write_handshake(conn, dest, destlen, pdatalen, flags,
    stream_id, fin, datav, datavcnt, ts);
```
```c
  if (!ppe_pending) {
    was_client_initial = conn->state == NGTCP2_CS_CLIENT_INITIAL;
    spktlen = conn_write_handshake(conn, dest, destlen, early_datalen, ts);
```
`ppe` is the Protected Packet Encoder. So we set the state to client initiail
and the call conn_write_handshake. So we the `dest`buffer to be populated with
handshake data after this call.

```c
nwrite = conn_write_client_initial(conn, dest, destlen, early_datalen, ts);
```
In this function we have the following call:
```c
rv = conn->callbacks.client_initial(conn, conn->user_data);
```
This call will take us back to Client::client_initial. 
```c
int client_initial(ngtcp2_conn *conn, void *user_data) {
  auto c = static_cast<Client *>(user_data);

if (c->recv_crypto_data(NGTCP2_CRYPTO_LEVEL_INITIAL, nullptr, 0)
```
`Client::recv_crypto_data` will call ngtcp2_crypto_read_write_crypto_data:
```c
return ngtcp2_crypto_read_write_crypto_data(conn_, ssl_, crypto_level, data, datalen);
```
This call will land in `openssl.c` which will call:
```c
  if (SSL_provide_quic_data(ssl, from_ngtcp2_level(crypto_level), data, datalen) != 1) {
```
`SSL_provide_quic_data` can be found in `ssl_quic.c` which is in the OpenSSL
project while `openssl.c` is in `ngtcp2/crypto/openssl`.
```
    /* Split the QUIC messages up, if necessary */
    while (len > 0) {
        QUIC_DATA *qd;
```
`QUIC_DATA` is a struct that look like this:
```c
struct quic_data_st {
    struct quic_data_st *next;
    OSSL_ENCRYPTION_LEVEL level;
    size_t offset;
    size_t length;
};
typedef struct quic_data_st QUIC_DATA;
```
But in our case len is 0 and we will return from this function, and be back
in ngtcp2_crypto_read_write_crypto_data:
```
  if (!ngtcp2_conn_get_handshake_completed(conn)) {
    rv = SSL_do_handshake(ssl);
```
SSL_do_handshake is in ssl_lib.c. There are some checks and then the path we
take will be to call `s->handshake_func`:
```c
    ret = s->handshake_func(s);
```
Recall that this is a client and so the function will be `ossl_statem_connect`.
So, this will land us in statem.c and the state_machine function:
```c
OSSL_STATEM *st = &s->statem;
```

```console
(lldb) expr *st
(OSSL_STATEM) $10 = {
  state = MSG_FLOW_UNINITED
  write_state = WRITE_STATE_TRANSITION
  write_state_work = WORK_ERROR
  read_state = READ_STATE_HEADER
  read_state_work = WORK_ERROR
  hand_state = TLS_ST_BEFORE
  request_state = TLS_ST_BEFORE
  in_init = 1
  read_state_first_init = 0
  in_handshake = 0
  cleanuphand = 0
  no_cert_verify = 0
  use_timer = 0
  enc_write_state = ENC_WRITE_STATE_VALID
  enc_read_state = ENC_READ_STATE_VALID
}
```
We can see that st->state is `MSG_FLOW_UNINITED` so the following if clause
will be entered:
```c
    if (st->state == MSG_FLOW_UNINITED
            || st->state == MSG_FLOW_FINISHED) {
        if (st->state == MSG_FLOW_UNINITED) {
            st->hand_state = TLS_ST_BEFORE;
            st->request_state = TLS_ST_BEFORE;
```
```c
  s->server = server;
```
We are on the client so server will be 0.
```c
        if (s->init_buf == NULL) {
            if ((buf = BUF_MEM_new()) == NULL) {
                SSLfatal(s, SSL_AD_NO_ALERT, SSL_F_STATE_MACHINE,
                         ERR_R_INTERNAL_ERROR);
                goto end;
            }
            if (!BUF_MEM_grow(buf, SSL3_RT_MAX_PLAIN_LENGTH)) {
                SSLfatal(s, SSL_AD_NO_ALERT, SSL_F_STATE_MACHINE,
                         ERR_R_INTERNAL_ERROR);
                goto end;
            }
            s->init_buf = buf;
            buf = NULL;
        }

        if (!ssl3_setup_buffers(s)) {
            SSLfatal(s, SSL_AD_NO_ALERT, SSL_F_STATE_MACHINE,
                     ERR_R_INTERNAL_ERROR);
            goto end;
        }
        s->init_num = 0;

        s->s3.change_cipher_spec = 0;
```
We are inte SSL_in_before "state" so the following section will be entered:
```c
        if ((SSL_in_before(s)) || s->renegotiate) {
            if (!tls_setup_handshake(s)) {
                /* SSLfatal() already called */
                goto end;
            }

            if (SSL_IS_FIRST_HANDSHAKE(s))
                st->read_state_first_init = 1;
        }
```
`tls_setup_handshake` can be found in `../openssl/ssl/statem/statem_lib.c`
```c
     st->state = MSG_FLOW_WRITING;
     init_write_state_machine(s);
```
```console
* thread #1, queue = 'com.apple.main-thread', stop reason = step in
  * frame #0: 0x00000001002843e8 libssl.3.dylib`ssl3_do_write(s=0x0000000102070e00, type=22) at statem_lib.c:47:9
    frame #1: 0x00000001002211ea libssl.3.dylib`ssl3_handshake_write(s=0x0000000102070e00) at s3_lib.c:3290:12
    frame #2: 0x0000000100277577 libssl.3.dylib`statem_do_write(s=0x0000000102070e00) at statem.c:714:16
    frame #3: 0x00000001002771aa libssl.3.dylib`write_state_machine(s=0x0000000102070e00) at statem.c:867:19
    frame #4: 0x00000001002760ca libssl.3.dylib`state_machine(s=0x0000000102070e00, server=0) at statem.c:444:21
```
ssl3_do_write in statem_lib.c will call
```c
  ret = s->quic_method->add_handshake_data(s, 
     s->quic_write_level,
     (const uint8_t*)&s->init_buf->data[s->init_off],
     s->init_num);
```
Notice how this is a callback that was set on the `quic_method`. So this is a
callback from OpenSSL and it is passing handshake data that has been created.
`add_handshake_data` will in turn call Client::write_client_handshake:
```c
int add_handshake_data(SSL *ssl, OSSL_ENCRYPTION_LEVEL ossl_level,
                       const uint8_t *data, size_t len) {
  auto c = static_cast<Client *>(SSL_get_app_data(ssl))
  c->write_client_handshake(util::from_ossl_level(ossl_level), data, len);
```
So we are going to call write_client_handshake with the following data and
the level will be `NGTCP2_CRYPTO_LEVEL_INITIAL`:
```console
(lldb) expr len
(lldb) memory read --force -s 1 -c 303 data
0x102803000: 01 00 01 2b 03 03 cb 9d 11 2e e6 07 d4 7c 3e 28  ...+..�...�.�|>(
0x102803010: 9f 36 fc 75 e9 91 b7 b9 7a db 6c eb a6 ff 1d f8  .6�u�.��z�l��.�
0x102803020: df a2 6f c1 f8 ef 00 00 0a 13 01 13 02 13 03 13  ߢo���..........
0x102803030: 04 00 ff 01 00 00 f8 00 00 00 0e 00 0c 00 00 09  ..�...�.........
0x102803040: 6c 6f 63 61 6c 68 6f 73 74 00 0b 00 04 03 00 01  localhost.......
0x102803050: 02 00 0a 00 0a 00 08 00 17 00 1d 00 18 00 19 00  ................
0x102803060: 23 00 00 00 10 00 08 00 06 05 68 33 2d 32 33 00  #.........h3-23.
0x102803070: 16 00 00 00 17 00 00 00 0d 00 1e 00 1c 04 03 05  ................
0x102803080: 03 06 03 08 07 08 08 08 09 08 0a 08 0b 08 04 08  ................
0x102803090: 05 08 06 04 01 05 01 06 01 00 2b 00 03 02 03 04  ..........+.....
0x1028030a0: 00 2d 00 02 01 01 00 33 00 47 00 45 00 17 00 41  .-.....3.G.E...A
0x1028030b0: 04 c8 07 e8 cb 0d 65 96 9c c1 7c a6 21 14 de a9  .�.��.e..�|�!.ީ
0x1028030c0: 66 54 8f 97 a4 83 07 99 6b 2f c4 11 d8 79 72 62  fT..�...k/�.�yrb
0x1028030d0: 21 b4 92 3c 95 a3 e3 05 d1 2a 47 d1 95 80 8b 8f  !�.<.��.�*G�....
0x1028030e0: 59 72 e3 06 e4 ab 29 e8 08 e2 5b 11 d4 aa 8d cd  Yr�.�)�.�[.Ԫ.�
0x1028030f0: 2a ff a5 00 3a 00 38 00 05 00 04 80 04 00 00 00  *��.:.8.........
0x102803100: 06 00 04 80 04 00 00 00 07 00 04 80 04 00 00 00  ................
0x102803110: 04 00 04 80 10 00 00 00 08 00 01 01 00 09 00 02  ................
0x102803120: 40 64 00 01 00 04 80 00 75 30 00 0e 00 01 07     @d......u0.....
```
```c
  auto &crypto = crypto_[level];
  crypto.data.emplace_back(data, datalen);
```
The client has a field named `crypto_` which which is an array of Crypto object
initially of size 3:
```c
struct Crypto {
  /* data is unacknowledged data. */
  std::deque<Buffer> data;
  /* acked_offset is the size of acknowledged crypto data removed from
     |data| so far */
  uint64_t acked_offset;
};
```
```c
  ngtcp2_conn_submit_crypto_data(conn_, level, buf.rpos(), buf.size());
```
So we have saved the crypto data and are now going to call ngtcp2 to submit
the crypto data.

```c
  rv = ngtcp2_frame_chain_new(&frc, conn->mem);
  if (rv != 0) {
    return rv;
  }

  fr = &frc->fr.crypto;

  fr->type = NGTCP2_FRAME_CRYPTO;
  fr->offset = pktns->crypto.tx.offset;
  fr->datacnt = 1;
  fr->data[0].len = datalen;
  fr->data[0].base = (uint8_t *)data;
```
TODO: take a closer look at ngtcp2_frame_chain.
Notice that the frame type is set to NGTCP2_FRAME_CRYPTO, and we are setting
the datalen and data itself on this structure/instance.


```c
  rv = ngtcp2_ksl_insert(&pktns->crypto.tx.frq, NULL,
                         ngtcp2_ksl_key_ptr(&key, &fr->offset), frc);
  pktns->crypto.strm.tx.offset += datalen;
  pktns->crypto.tx.offset += datalen;
```
At this stage we are done and will return. So we have added the handshake data
to the connections queue but nothing more right?
This will then return control back into statem_lib.c, recall that the where in:
```c
  ret = s->quic_method->add_handshake_data(s, s->quic_write_level,
                                           (const uint8_t*)&s->init_buf->data[s->init_off],
                                    s->init_num);
  ...
  written = s->init_num;
  ...
            if (!ssl3_finish_mac(s,
                                 (unsigned char *)&s->init_buf->data[s->init_off],
                                 written))
```
And we will return to statem.c 867:
```c
  ret = statem_do_write(s);
```
```console
* thread #1, queue = 'com.apple.main-thread', stop reason = step in
  * frame #0: 0x0000000100276287 libssl.3.dylib`statem_flush(s=0x0000000102070e00) at statem.c:909:9
    frame #1: 0x0000000100278ba0 libssl.3.dylib`ossl_statem_client_post_work(s=0x0000000102070e00, wst=WORK_MORE_A) at statem_clnt.c:759:21
    frame #2: 0x00000001002771ea libssl.3.dylib`write_state_machine(s=0x0000000102070e00) at statem.c:876:44
    frame #3: 0x00000001002760ca libssl.3.dylib`state_machine(s=0x0000000102070e00, server=0) at statem.c:444:21
```
```c
 if (SSL_IS_QUIC(s)) {
-> 910 	        if (!s->quic_method->flush_flight(s)) {

```
In our case flush_flight is defined as:
```c
int flush_flight(SSL *ssl) { return 1; }
```
```console
* thread #1, queue = 'com.apple.main-thread', stop reason = step in
  * frame #0: 0x00000001002766b5 libssl.3.dylib`read_state_machine(s=0x0000000102070e00) at statem.c:580:24
    frame #1: 0x0000000100276085 libssl.3.dylib`state_machine(s=0x0000000102070e00, server=0) at statem.c:435:21
    frame #2: 0x0000000100275be7 libssl.3.dylib`ossl_statem_connect(s=0x0000000102070e00) at statem.c:251:12
    frame #3: 0x000000010023629e libssl.3.dylib`SSL_do_handshake(s=0x0000000102070e00) at ssl_lib.c:3776:19
```
```c
  ret = quic_get_message(s, &mt, &len);
```

Back in conn_write_client_initial:
```c
  return conn_write_handshake_pkt(conn, dest, destlen, NGTCP2_PKT_INITIAL,
                                  early_datalen, ts);
```
Back in `write_streams` we have:
```c
    rv = send_packet();
```
This is where we are actually going to send the packet:
```c
  do {
    nwrite = sendto(fd_, sendbuf_.rpos(), sendbuf_.size(), MSG_DONTWAIT,
                    &remote_addr_.su.sa, remote_addr_.len);
  } while (nwrite == -1 && errno == EINTR);
```
Add the following break point to the server lldb session:
```console
(lldb) br s -n sreadcb
```
Also, if you have restarted the client lldb session for some reason set a 
break point in send_packet it will then stop after sending:
```
(lldb) br s -n send_packet
```
And also start a wireshark capture as you'll then be able to see the packet
sent to the server.

We can see that the data being sent out is encrypted.
```console
(lldb) memory read --force -s 1 -c 1232 sendbuf_.rpos()
```

So, now we should have stopped in a break point in the server lldb session.
```c
void sreadcb(struct ev_loop *loop, ev_io *w, int revents) {
  auto ep = static_cast<Endpoint *>(w->data);
  ep->server->on_read(*ep);
}
```
`on_read` will call `recvfrom` to read the data
Just note where that we used OpenSSL to encrypt, then send using UDP, and we
are now reading from the socket, nothing else is going on.
```c
  auto nread =
      recvfrom(ep.fd, buf.data(), buf.size(), MSG_DONTWAIT, &su.sa, &addrlen);
```
Notice that data will be read into buf, and nread will be used below:
```
  uint32_t version;
  const uint8_t *dcid, *scid;
  size_t dcidlen, scidlen;

  rv = ngtcp2_pkt_decode_version_cid(&version, &dcid, &dcidlen, &scid, &scidlen,
                                     buf.data(), nread, NGTCP2_SV_SCIDLEN);
```
We can inspect the data using and verify that is matches what the client sent:
```console
(lldb) memory read --force -s 1 -c 1232 buf.data()
```
This is what the QUIC paket looks like in wireshark:
```
QUIC IETF
    QUIC Connection information
        [Connection Number: 0]
    [Packet Length: 1232]
    1... .... = Header Form: Long Header (1)
    .1.. .... = Fixed Bit: True
    ..00 .... = Packet Type: Initial (0)
    .... 00.. = Reserved: 0
    .... ..00 = Packet Number Length: 1 bytes (0)
    Version: draft-23 (0xff000017)
    Destination Connection ID Length: 18
    Destination Connection ID: 3392fb765e8717676bd234516703646e3f44
    Source Connection ID Length: 17
    Source Connection ID: d6acad4c6beb0303d56e51ae55c0292679
    Token Length: 0
    Length: 1187
    Packet Number: 0
    Payload: b71e5a9bf2ff332392e2ddcf29d2145b8624c4eb6845fa43…
    TLSv1.3 Record Layer: Handshake Protocol: Client Hello
    PADDING Length: 863
```
```c
  if (data[0] & NGTCP2_HEADER_FORM_BIT) {
```
This will check the header form bit (0x80):
```console
(lldb) expr -format b -- (int) data[0]
(int) $18 = 0b00000000000000000000000011000110
(lldb) expr -format b -- 0x80
(int) $17 = 0b00000000000000000000000010000000
```
After this `len` is incremented/set:
```c
    len = 1 + 4 + 1 + 1;
```
The long header packet looks like this:
```
   0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
   +-+-+-+-+-+-+-+-+
   |1|1|T T|X X X X|
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                         Version (32)                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | DCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |               Destination Connection ID (0..160)            ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | SCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                 Source Connection ID (0..160)               ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```
What are the increments for?  
1 would seem to be the for bit header
```
(lldb) memory read -f b -s 1 -c 1 data
0x7ffeefbeea98: 0b11000110
```
 1                  1          00         0110
header form bit   fixed bit  pkg type     type specific bits 4
bit
```
So the following
```c
    len = 1 + 4 + 1 + 1;
```
We first have 1 for the header form bit, then 4 for the type specific bits, then
one for the fixed bit and only one for the package type. Is this an error or
am I missing something here?  Should this be
```c
    len = 1 + 1 + 2 + 4  
```
So we can see that we are extracting information from the header and nothing
else. We have not touched any frames yet.
After this we have `make_cid_key`:
```c
auto dcid_key = util::make_cid_key(dcid, dcidlen);
```

if no handler is found we will call:
```c
rv = ngtcp2_accept(&hd, buf.data(), nread);

...
auto h = std::make_unique<Handler>(loop_, ssl_ctx_, this, &hd.dcid);
..
```




`ngtcp2_pkt_decode_version_cid` will populate the passed in version, and also
the destination connection id, and source connection id.

```c
ngtcp2_conn_submit_crypto_data(conn_, level, buf.rpos(), buf.size());
```
So this will first create a new frame and the type will be NGTCP2_FRAME_CRYPTO.
This will the set on conn-pkns thing. Start here tomorrow!

Now, remember that TLS...




ngtcp

There are a number of things that happen in create_ssl_ctx, for example:
```c++
  SSL_CTX_set_alpn_select_cb(ssl_ctx, alpn_select_proto_cb, nullptr);
```
This is a callback for the Application Layer Protocol Negotiation. 
```c++
  SSL_CTX_set_quic_method(ssl_ctx, &quic_method);
```
`quic_method` is a struct declared earlier in server.cc:
```c++
auto quic_method = SSL_QUIC_METHOD{
    set_encryption_secrets,
    add_handshake_data,
    flush_flight,
    send_alert,
};
```
And the definition of the struct can be found in examples/server.cc
```c
struct ssl_quic_method_st {
    int (*set_encryption_secrets)(SSL *ssl, OSSL_ENCRYPTION_LEVEL level,
                                  const uint8_t *read_secret,
                                  const uint8_t *write_secret, size_t secret_len);
    int (*add_handshake_data)(SSL *ssl, OSSL_ENCRYPTION_LEVEL level,
                              const uint8_t *data, size_t len);
    int (*flush_flight)(SSL *ssl);
    int (*send_alert)(SSL *ssl, enum ssl_encryption_level_t level, uint8_t alert);
};
```
So we can see that we are adding more SSL callbacks, one for the setting of 
encryption secrets, one for adding handshake data, etc. 

So what are the callback that are called by OpenSSL? 
If we take a look at `create_ssl_ctx` we can find the following:
```c
SSL_CTX_set_alpn_select_cb(ssl_ctx, alpn_select_proto_cb, nullptr);
SSL_CTX_set_verify(ssl_ctx, SSL_VERIFY_PEER | SSL_VERIFY_CLIENT_ONCE | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
                   verify_cb);
  }
}
SSL_CTX_set_quic_method(ssl_ctx, &quic_method);  
SSL_CTX_set_client_hello_cb(ssl_ctx, client_hello_cb, nullptr);
```
Let's set break points to see where these function are called.
```console
(lldb) br s -n alpn_select_proto_cb
(lldb) br s -n verify_cb
(lldb) br s -n client_hello_cb
(lldb) br s -n set_encryption_secrets
(lldb) br s -n add_handshake_data
(lldb) br s -n flush_flight
(lldb) br s -n send_alert
```

`statem_srvr.c` will call `client_hello_cb`.
```c
int client_hello_cb(SSL *ssl, int *al, void *arg) {
```
So what is al?  
This is is a value that will be sent as an `alert` value in the case the
callback returns a failure (`0`).
The callback in ngtcp2 server example:
```c
int client_hello_cb(SSL *ssl, int *al, void *arg) {
  const uint8_t *tp;
  size_t tplen;

  if (!SSL_client_hello_get0_ext(ssl, NGTCP2_TLSEXT_QUIC_TRANSPORT_PARAMETERS,
                                 &tp, &tplen)) {
    *al = SSL_AD_INTERNAL_ERROR;
    return SSL_CLIENT_HELLO_FAILURE;
  }

  return SSL_CLIENT_HELLO_SUCCESS;
}
```
So in this case we are checking that the TLS extension for quic transport
parameters is present. If not we set al and return failure.

The second callback to be called in alpn_select_proto_cb which is used by the
server side to check the application protocols that the client passed. The 
server should select on and set the out list.

Next, we have `add_handshake_data` which is called from `statem_lib.c`.
In this callback, `Handler::write_server_handshake` will be called.
So, it looks like this is where ngtcp2 will submit the crypto data to the client.
```c
ngtcp2_conn_submit_crypto_data(conn_, level, buf.rpos(), buf.size());


// In a new console
$ lldb -- client localhost 7777
(lldb) br s -n main
```
In the client, first the programs options are parsed and configured.
Next, an SSL Context is created by the following function call
```c++
auto ssl_ctx = create_ssl_ctx();
```
This function will set the correct protocol versions to `TLS1_3_VERSION`.
```c++
// This makes OpenSSL client not send CCS (Change Cipher Spec) after an initial
ClientHello.
SSL_CTX_clear_options(ssl_ctx, SSL_OP_ENABLE_MIDDLEBOX_COMPAT);
```
`SSL_OP_ENABLE_MIDDLEBOX_COMPAT`:
```
If set, then dummy Change Cipher Spec (CCS) messages are sent in TLSv1.3. This 
has the effect of making TLSv1.3 look more like TLSv1.2 so that middleboxes 
that do not understand TLSv1.3 will not drop the connection. Regardless of 
whether this option is set or not CCS messages received from the peer will 
always be ignored in TLSv1.3. This option is set by default. To switch it off 
use SSL_clear_options(). A future version of OpenSSL may not set this by default.
```
Next the ciphersuites are set and the groups (EC groups?). Following that we
have:
```c++
SSL_CTX_set_mode(ssl_ctx, SSL_MODE_QUIC_HACK);
```
This part of the patch to support QUIC in OpenSSL.
Next, we have a custom extension
```
SSL_CTX_add_client_custom_ext() adds a custom extension for a TLS/DTLS client
with extension type ext_type and callbacks add_cb, free_cb and parse_cb. 
```
```c++
if (SSL_CTX_add_custom_ext(
          ssl_ctx, NGTCP2_TLSEXT_QUIC_TRANSPORT_PARAMETERS,
          SSL_EXT_CLIENT_HELLO | SSL_EXT_TLS1_3_ENCRYPTED_EXTENSIONS,
          transport_params_add_cb,
          transport_params_free_cb,
          nullptr, // no add/free function args
          transport_params_parse_cb,
          nullptr) // no parse args
                 != 1) {
```
`transport_params_add_cb` is used to add custom data to be included in TLS
messages.

Lets start with the client and step through until we get to `Client::init`:
```c++
  if (init_ssl() != 0) {
    return -1;
  }
```
This calls Client::init_ssl:
```c++
  ssl_ = SSL_new(ssl_ctx_);
  auto bio = BIO_new(create_bio_method());
  BIO_set_data(bio, this);
  SSL_set_bio(ssl_, bio, bio);
  SSL_set_app_data(ssl_, this);
  SSL_set_connect_state(ssl_);
  SSL_set_msg_callback(ssl_, msg_cb);
  SSL_set_msg_callback_arg(ssl_, this);
  SSL_set_key_callback(ssl_, key_cb, this);
```
Next, back in Client::init we have:
```c++
  auto callbacks = ngtcp2_conn_callbacks{
      client_initial,
      nullptr, // recv_client_initial
      recv_crypto_data,
      handshake_completed,
      nullptr, // recv_version_negotiation
      do_hs_encrypt,
      do_hs_decrypt,
      do_encrypt,
      do_decrypt,
      do_in_hp_mask,
      do_hp_mask,
      recv_stream_data,
      acked_crypto_offset,
      acked_stream_data_offset,
      nullptr, // stream_open
      stream_close,
      nullptr, // recv_stateless_reset
      recv_retry,
      extend_max_streams_bidi,
      nullptr, // extend_max_streams_uni
      nullptr, // rand
      get_new_connection_id,
      remove_connection_id,
      ::update_key,
  };
```
So these are the callback that a client would register.
Next the source connection id is generated:
```c++
  ngtcp2_cid scid, dcid;
  scid.datalen = 17;
  std::generate(std::begin(scid.data), std::begin(scid.data) + scid.datalen,
                [&dis]() { return dis(randgen); });
```
And then the destination destination connection id is generated:
```c++
  if (config.dcid.datalen == 0) {
    dcid.datalen = 18;
    std::generate(std::begin(dcid.data), std::begin(dcid.data) + dcid.datalen,
                  [&dis]() { return dis(randgen); });
  } else {
    dcid = config.dcid;
  }
```
Next various settings are set:
```c++
  settings.log_printf = config.quiet ? nullptr : debug::log_printf;
  settings.initial_ts = util::timestamp(loop_);
  settings.max_stream_data_bidi_local = 256_k;
  settings.max_stream_data_bidi_remote = 256_k;
  settings.max_stream_data_uni = 256_k;
  settings.max_data = 1_m;
  settings.max_streams_bidi = 1;
  settings.max_streams_uni = 1;
  settings.idle_timeout = config.timeout;
  settings.max_packet_size = NGTCP2_MAX_PKT_SIZE;
  settings.ack_delay_exponent = NGTCP2_DEFAULT_ACK_DELAY_EXPONENT;
  settings.max_ack_delay = NGTCP2_DEFAULT_MAX_ACK_DELAY;
```
After this a connection is created using `ngtcp2_conn_client_new`:
```c++
rv = ngtcp2_conn_client_new(&conn_, &dcid, &scid, version, &callbacks,
                              &settings, this);
```
This function can be found in `lib/ngtcp2_conn.c` and will set the connection
state to `NGTCP2_CS_CLIENT_INITIAL`.
Next, the there is a setup of the crypto context by:
```c++
rv = setup_initial_crypto_context();
```
The first thing that happens is:
```c++
auto dcid = ngtcp2_conn_get_dcid(conn_);
```
`dcid` which is the destination connection identifier. This is then used in the
following call:
```c++
rv = crypto::derive_initial_secret(
      initial_secret.data(), initial_secret.size(), dcid,
      reinterpret_cast<const uint8_t *>(NGTCP2_INITIAL_SALT),
      str_size(NGTCP2_INITIAL_SALT));
```
This function is described by [section 5.2](https://tools.ietf.org/id/draft-ietf-quic-tls-17.html#rfc.section.5.2)
of the spec which describes how initial packets are protected with a secret derived from the Destionation Conneciton ID.

The first two parameters are the destination pointer (unit8_t) and the size (size_t). 
`dcid` is a pointer to the secret, followed by the salt and the salt length.
The salt is defined in the [spec](https://tools.ietf.org/id/draft-ietf-quic-tls-17.html#rfc.section.5.2).

```
int derive_initial_secret(uint8_t *dest, size_t destlen,
                          const ngtcp2_cid *secret, const uint8_t *salt,
                          size_t saltlen) {
  Context ctx;
  prf_sha256(ctx);
  return hkdf_extract(dest, destlen, secret->data, secret->datalen, salt, saltlen, ctx);
}
```
The first call to `prf_sha256` will populate Context::prf by calling call EVP_sha256(). 
(pseudorandom function I think `prf` stands for).

Next we have:
```c++
rv = crypto::derive_client_initial_secret(secret.data(), secret.size(),
                                            initial_secret.data(),
                                            initial_secret.size());
```
We are using the secret that was derived from the destination connection id, and using the same secret but with a label:
```c++
int derive_client_initial_secret(uint8_t *dest, size_t destlen,
                                 const uint8_t *secret, size_t secretlen) {
  static constexpr uint8_t LABEL[] = "client in";
  Context ctx;
  prf_sha256(ctx);
  return crypto::hkdf_expand_label(dest, destlen, secret, secretlen, LABEL,
                                   str_size(LABEL), ctx);
}
```
Next, we have:
```c++
auto keylen = crypto::derive_packet_protection_key(
      key.data(), key.size(), secret.data(), secret.size(), hs_crypto_ctx_);
```
This will use the label "quic key":
```c++
```

If there has not been a connection previously (0-RTT not possible) then an 
initial handshake will be performed (Client::do_handshake_write_once):
```c++
nwrite = c.do_handshake_write_once();
```
This will eventually call conn_write_client_initial in conn_write_handshake:
```c++
nwrite = conn_write_client_initial(conn, dest, destlen, early_datalen, ts);
```
This will call the callback set previously named `client_initial` passing in
the connection and connectio user_data.
`client_initial will call `tls_handshake:
```c++
if (c->tls_handshake(true) != 0) {
  return NGTCP2_ERR_CALLBACK_FAILURE;
}
```
which will later call `SSL_do_handshake(ssl_)` which is a function in ssl_lib.c. 
This will call any extensions that have been registered which is the case for us as we added a custom extension.
`transport_params_add_cb`:
```c++
rv = ngtcp2_conn_get_local_transport_params(
      conn, &params, NGTCP2_TRANSPORT_PARAMS_TYPE_CLIENT_HELLO);
...
constexpr size_t bufsize = 64;
auto buf = std::make_unique<uint8_t[]>(bufsize);
auto nwrite = ngtcp2_encode_transport_params(
      buf.get(), bufsize, NGTCP2_TRANSPORT_PARAMS_TYPE_CLIENT_HELLO, &params);
```

Later `Client::send_packet` will actually send the message to the server.

This will cause the servers `sreadcb` go be called as this is registered
as a read event in Server::Server:
```c++
ev_io_init(&rev_, sreadcb, 0, EV_READ);
```
```c++
void sreadcb(struct ev_loop *loop, ev_io *w, int revents) {
  auto s = static_cast<Server *>(w->data);

  s->on_read();
}
```
This will inturn call `feed_data` which will call `do_handshake` which does:
```c++
auto rv = do_handshake_read_once(data, datalen);
```
Which calls `ngtcp2_conn_read_handshake`:
```
6385   case NGTCP2_CS_SERVER_INITIAL:
6386     rv = conn_recv_handshake_cpkt(conn, pkt, pktlen, ts);
```
This will later endup in `conn_recv_handshake_pkt`:
```c++
switch(fr->type) {
...
case NGTCP2_FRAME_CRYPTO:
      rv = conn_recv_crypto(conn, pktns->crypto_rx_offset_base,
                            max_crypto_rx_offset, &fr->crypto);

```
```c++
conn_call_recv_crypto_data
```
```c++
rv = conn->callbacks.recv_crypto_data(conn, offset, data, datalen,
                                      conn->user_data);
```
This is the callback that the server registered.
```console
(lldb) br s -n recv_crypto_data
```
From `recv_crypto_data`:
```c++
 if (!ngtcp2_conn_get_handshake_completed(h->conn())) {
    rv = h->tls_handshake();
```
```c++
rv = SSL_read_early_data(ssl_, buf.data(), buf.size(), &nread);
```
This will call into OpenSSL. 

Here is a backtrace from `msg_cb`.
```console
(lldb) bt
* thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
  * frame #0: 0x0000000100004a8c server`(anonymous namespace)::msg_cb(write_p=0, version=772, content_type=22, buf=0x0000000102807600, len=296, ssl=0x0000000102800600, arg=0x00000001013002d0) at server.cc:198 [opt]
    frame #1: 0x00000001001c396d libssl.3.dylib`tls_get_message_body(s=0x0000000102800600, len=0x00007ffeefbeca58) at statem_lib.c:1332
    frame #2: 0x00000001001b1a2f libssl.3.dylib`read_state_machine(s=0x0000000102800600) at statem.c:621
    frame #3: 0x00000001001b12c3 libssl.3.dylib`state_machine(s=0x0000000102800600, server=1) at statem.c:432
    frame #4: 0x00000001001b149a libssl.3.dylib`ossl_statem_accept(s=0x0000000102800600) at statem.c:255
    frame #5: 0x000000010017200d libssl.3.dylib`SSL_do_handshake(s=0x0000000102800600) at ssl_lib.c:3608
    frame #6: 0x0000000100171ead libssl.3.dylib`SSL_accept(s=0x0000000102800600) at ssl_lib.c:1662
    frame #7: 0x00000001001726c0 libssl.3.dylib`SSL_read_early_data(s=0x0000000102800600, buf=0x00007ffeefbecbe8, num=8, readbytes=0x00007ffeefbecbd8) at ssl_lib.c:1826
    frame #8: 0x00000001000053c4 server`Handler::tls_handshake(this=0x00000001013002d0) at server.cc:1105 [opt]
    frame #9: 0x0000000100027736 server`conn_recv_crypto [inlined] conn_call_recv_crypto_data(conn=<unavailable>, offset=<unavailable>, data="\x01", datalen=296) at ngtcp2_conn.c:106 [opt]
    frame #10: 0x000000010002771f server`conn_recv_crypto(conn=0x0000000102802600, rx_offset_base=<unavailable>, max_rx_offset=<unavailable>, fr=<unavailable>) at ngtcp2_conn.c:4639 [opt]
    frame #11: 0x000000010002880b server`conn_recv_handshake_pkt(conn=<unavailable>, pkt=<unavailable>, pktlen=<unavailable>, ts=1549283305446764032) at ngtcp2_conn.c:4378 [opt]
    frame #12: 0x000000010001eb92 server`conn_recv_handshake_cpkt(conn=0x0000000102802600, pkt="��", pktlen=1232, ts=1549283305446764032) at ngtcp2_conn.c:4449 [opt]
    frame #13: 0x000000010001e7d3 server`ngtcp2_conn_read_handshake(conn=0x0000000102802600, pkt="��", pktlen=1232, ts=1549283305446764032) at ngtcp2_conn.c:6386 [opt]
    frame #14: 0x00000001000065f7 server`Handler::do_handshake_read_once(this=<unavailable>, data=<unavailable>, datalen=<unavailable>) at server.cc:1402 [opt]
    frame #15: 0x0000000100006f31 server`Handler::feed_data(sockaddr const*, unsigned int, unsigned char*, unsigned long) [inlined] Handler::do_handshake(this=0x00000001013002d0, data="��", datalen=1232) at server.cc:1439 [opt]
    frame #16: 0x0000000100006f23 server`Handler::feed_data(this=0x00000001013002d0, sa=0x00007ffeefbfe5b0, salen=28, data="��", datalen=1232) at server.cc:1489 [opt]
    frame #17: 0x000000010000a37f server`Server::on_read() [inlined] Handler::on_read(this=0x00000001013002d0, sa=0x00000000d6fb1e1c, salen=<unavailable>, data="", datalen=<unavailable>) at server.cc:1502 [opt]
    frame #18: 0x000000010000a36a server`Server::on_read(this=0x00007ffeefbfe720) at server.cc:2164 [opt]
```



```c++
auto rv =
      ngtcp2_conn_read_handshake(conn_, data, datalen, util::timestamp(loop_));
...

```
The actual handshake is sent by calling:
```c++
rv = conn->callbacks.client_initial(conn, conn->user_data);
```

### tcpdump

```console
sudo tcpdump -X -vv -i lo0 -s0 -n port 7777

### Configuring Wireshark for QUIC protocol
1) Set SSLKEYLOGFILE environment variable:
```console
$ export SSLKEYLOGFILE="quic_keylog_file"
```
2) In wireshark choose the port that QUIC uses. 
reshark choose the port that QUIC uses. 
Go to `Preferences->Protocols->QUIC` and set the port the program listens to.
In the case or the example application this would be the port specified on the
command line.

3) We go to the TSL protcol and add the "Pre-Master-Secret log file" that you set using
SSLKEYLOGFILE.

4) Create a filter.
Make sure you choose the correct network interface for capturing. I'm using localhost
so I choose the `loopback` nic. And the port is `udp.port == 7777`

Start the server and then the client and you should be able to see the traffic.

Example session

Client Initial:
```
Frame 1: 1284 bytes on wire (10272 bits), 1284 bytes captured (10272 bits) on interface lo0, id 0
    Interface id: 0 (lo0)
        Interface name: lo0
    Encapsulation type: NULL/Loopback (15)
    Arrival Time: Oct 22, 2019 08:30:39.061073000 CEST
    [Time shift for this packet: 0.000000000 seconds]
    Epoch Time: 1571725839.061073000 seconds
    [Time delta from previous captured frame: 0.000000000 seconds]
    [Time delta from previous displayed frame: 0.000000000 seconds]
    [Time since reference or first frame: 0.000000000 seconds]
    Frame Number: 1
    Frame Length: 1284 bytes (10272 bits)
    Capture Length: 1284 bytes (10272 bits)
    [Frame is marked: False]
    [Frame is ignored: False]
    [Protocols in frame: null:ipv6:udp:quic:tls]
    [Coloring Rule Name: UDP]
    [Coloring Rule String: udp]
Null/Loopback
    Family: IPv6 (30)

Internet Protocol Version 6, Src: ::1, Dst: ::1
    0110 .... = Version: 6
    <0110 .... = Version: 6 [This field makes the filter match on "ip.version == 6" possible]>
    .... 0000 0000 .... .... .... .... .... = Traffic Class: 0x00 (DSCP: CS0, ECN: Not-ECT)
        .... 0000 00.. .... .... .... .... .... = Differentiated Services Codepoint: Default (0)
        .... .... ..00 .... .... .... .... .... = Explicit Congestion Notification: Not ECN-Capable Transport (0)
    .... .... .... 0011 0100 0000 0101 1001 = Flow Label: 0x34059
    Payload Length: 1240
    Next Header: UDP (17)
    Hop Limit: 64
    Source: ::1
    <Source or Destination Address: ::1>
    <[Source Host: ::1]>
    <[Source or Destination Host: ::1]>
    Destination: ::1
    <Source or Destination Address: ::1>
    <[Destination Host: ::1]>
    <[Source or Destination Host: ::1]>

User Datagram Protocol, Src Port: 53160, Dst Port: 7777
    Source Port: 53160
    Destination Port: 7777
    <Source or Destination Port: 53160>
    <Source or Destination Port: 7777>
    Length: 1240
    Checksum: 0x04eb [unverified]
    [Checksum Status: Unverified]
    [Stream index: 0]
    [Timestamps]
        [Time since first frame: 0.000000000 seconds]
        [Time since previous frame: 0.000000000 seconds]

QUIC IETF
    QUIC Connection information
        [Connection Number: 0]
    [Packet Length: 1232]
    1... .... = Header Form: Long Header (1)
    .1.. .... = Fixed Bit: True
    ..00 .... = Packet Type: Initial (0)
    .... 00.. = Reserved: 0
    .... ..00 = Packet Number Length: 1 bytes (0)
    Version: draft-23 (0xff000017)
    Destination Connection ID Length: 18
    Destination Connection ID: a8258a61065b6e0c72a111734d6eced24cae
    Source Connection ID Length: 17
    Source Connection ID: 61ac5a112d1731c9d35a03ea687ac82eb4
    Token Length: 0
    Length: 1187
    Packet Number: 0
    Payload: db5ce9a849705d1b826c29035bedc94d7750cfe12acfa6fb…
    TLSv1.3 Record Layer: Handshake Protocol: Client Hello
        Frame Type: CRYPTO (0x06)
        Offset: 0
        Length: 303
        Crypto Data
        Handshake Protocol: Client Hello
            Handshake Type: Client Hello (1)
            Length: 299
            Version: TLS 1.2 (0x0303)
            Random: 422fd7fddc8e10f91d9fcec6030fe4eb11a0e6ed980985cc…
            Session ID Length: 0
            Cipher Suites Length: 10
            Cipher Suites (5 suites)
                Cipher Suite: TLS_AES_128_GCM_SHA256 (0x1301)
                Cipher Suite: TLS_AES_256_GCM_SHA384 (0x1302)
                Cipher Suite: TLS_CHACHA20_POLY1305_SHA256 (0x1303)
                Cipher Suite: TLS_AES_128_CCM_SHA256 (0x1304)
                Cipher Suite: TLS_EMPTY_RENEGOTIATION_INFO_SCSV (0x00ff)
            Compression Methods Length: 1
            Compression Methods (1 method)
                Compression Method: null (0)
            Extensions Length: 248
            Extension: server_name (len=14)
                Type: server_name (0)
                Length: 14
                Server Name Indication extension
                    Server Name list length: 12
                    Server Name Type: host_name (0)
                    Server Name length: 9
                    Server Name: localhost
            Extension: ec_point_formats (len=4)
                Type: ec_point_formats (11)
                Length: 4
                EC point formats Length: 3
                Elliptic curves point formats (3)
                    EC point format: uncompressed (0)
                    EC point format: ansiX962_compressed_prime (1)
                    EC point format: ansiX962_compressed_char2 (2)
            Extension: supported_groups (len=10)
                Type: supported_groups (10)
                Length: 10
                Supported Groups List Length: 8
                Supported Groups (4 groups)
                    Supported Group: secp256r1 (0x0017)
                    Supported Group: x25519 (0x001d)
                    Supported Group: secp384r1 (0x0018)
                    Supported Group: secp521r1 (0x0019)
            Extension: session_ticket (len=0)
                Type: session_ticket (35)
                Length: 0
                Data (0 bytes)
            Extension: application_layer_protocol_negotiation (len=8)
                Type: application_layer_protocol_negotiation (16)
                Length: 8
                ALPN Extension Length: 6
                ALPN Protocol
                    ALPN string length: 5
                    ALPN Next Protocol: h3-23
            Extension: encrypt_then_mac (len=0)
                Type: encrypt_then_mac (22)
                Length: 0
            Extension: extended_master_secret (len=0)
                Type: extended_master_secret (23)
                Length: 0
            Extension: signature_algorithms (len=30)
                Type: signature_algorithms (13)
                Length: 30
                Signature Hash Algorithms Length: 28
                Signature Hash Algorithms (14 algorithms)
                    Signature Algorithm: ecdsa_secp256r1_sha256 (0x0403)
                        Signature Hash Algorithm Hash: SHA256 (4)
                        Signature Hash Algorithm Signature: ECDSA (3)
                    Signature Algorithm: ecdsa_secp384r1_sha384 (0x0503)
                        Signature Hash Algorithm Hash: SHA384 (5)
                        Signature Hash Algorithm Signature: ECDSA (3)
                    Signature Algorithm: ecdsa_secp521r1_sha512 (0x0603)
                        Signature Hash Algorithm Hash: SHA512 (6)
                        Signature Hash Algorithm Signature: ECDSA (3)
                    Signature Algorithm: ed25519 (0x0807)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (7)
                    Signature Algorithm: ed448 (0x0808)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (8)
                    Signature Algorithm: rsa_pss_pss_sha256 (0x0809)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (9)
                    Signature Algorithm: rsa_pss_pss_sha384 (0x080a)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (10)
                    Signature Algorithm: rsa_pss_pss_sha512 (0x080b)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (11)
                    Signature Algorithm: rsa_pss_rsae_sha256 (0x0804)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (4)
                    Signature Algorithm: rsa_pss_rsae_sha384 (0x0805)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (5)
                    Signature Algorithm: rsa_pss_rsae_sha512 (0x0806)
                        Signature Hash Algorithm Hash: Unknown (8)
                        Signature Hash Algorithm Signature: Unknown (6)
                    Signature Algorithm: rsa_pkcs1_sha256 (0x0401)
                        Signature Hash Algorithm Hash: SHA256 (4)
                        Signature Hash Algorithm Signature: RSA (1)
                    Signature Algorithm: rsa_pkcs1_sha384 (0x0501)
                        Signature Hash Algorithm Hash: SHA384 (5)
                        Signature Hash Algorithm Signature: RSA (1)
                    Signature Algorithm: rsa_pkcs1_sha512 (0x0601)
                        Signature Hash Algorithm Hash: SHA512 (6)
                        Signature Hash Algorithm Signature: RSA (1)
            Extension: supported_versions (len=3)
                Type: supported_versions (43)
                Length: 3
                Supported Versions length: 2
                Supported Version: TLS 1.3 (0x0304)
            Extension: psk_key_exchange_modes (len=2)
                Type: psk_key_exchange_modes (45)
                Length: 2
                PSK Key Exchange Modes Length: 1
                PSK Key Exchange Mode: PSK with (EC)DHE key establishment (psk_dhe_ke) (1)
            Extension: key_share (len=71)
                Type: key_share (51)
                Length: 71
                Key Share extension
                    Client Key Share Length: 69
                    Key Share Entry: Group: secp256r1, Key Exchange length: 65
                        Group: secp256r1 (23)
                        Key Exchange Length: 65
                        Key Exchange: 04f4d847ceec921099779d989b147af0239c7bfa2865a392…
            Extension: quic_transports_parameters (len=58)
                Type: quic_transports_parameters (65445)
                Length: 58
                Parameters Length: 56
                Parameter: initial_max_stream_data_bidi_local (len=4) 262144
                    Type: initial_max_stream_data_bidi_local (0x0005)
                    Length: 4
                    Value: 80040000
                    initial_max_stream_data_bidi_local: 262144
                Parameter: initial_max_stream_data_bidi_remote (len=4) 262144
                    Type: initial_max_stream_data_bidi_remote (0x0006)
                    Length: 4
                    Value: 80040000
                    initial_max_stream_data_bidi_remote: 262144
                Parameter: initial_max_stream_data_uni (len=4) 262144
                    Type: initial_max_stream_data_uni (0x0007)
                    Length: 4
                    Value: 80040000
                    initial_max_stream_data_uni: 262144
                Parameter: initial_max_data (len=4) 1048576
                    Type: initial_max_data (0x0004)
                    Length: 4
                    Value: 80100000
                    initial_max_data: 1048576
                Parameter: initial_max_streams_bidi (len=1) 1
                    Type: initial_max_streams_bidi (0x0008)
                    Length: 1
                    Value: 01
                    initial_max_streams_bidi: 1
                Parameter: initial_max_streams_uni (len=2) 100
                    Type: initial_max_streams_uni (0x0009)
                    Length: 2
                    Value: 4064
                    initial_max_streams_uni: 100
                Parameter: idle_timeout (len=4) 30000 ms
                    Type: idle_timeout (0x0001)
                    Length: 4
                    Value: 80007530
                    idle_timeout: 30000
                Parameter: active_connection_id_limit (len=1) 7
                    Type: active_connection_id_limit (0x000e)
                    Length: 1
                    Value: 07
                    Active Connection ID Limit: 7
    PADDING Length: 863
        Frame Type: PADDING (0x00)
        [Padding Length: 863]

```
```
Long Headers:
Long headers are used for packets that are sent prior to the completion of version 
negotiation and establishment of 1-RTT keys like `Initial', '0-RTT', 'Handshake' and
'Retry'.


### Updating ngtcp2 sources in deps
You'll need to checkout the correct version locally and the copy all the
source and header files to deps/ngtcp2 directory. 
If there are new source files these have to be updated in ngtcp2.gyp.


#### QUIC Address Validation


#### QUIC Path Validation
This is used during connection migration and is performed by the migrating endpoint
to ensure that the peer can be reached from the new local address.
So, the address would be a two-tuple of IP-address and port and this would be used
to make sure that it can communicate with the remote address (also a two-tuple of
IP-address and port). A PATH_CHALLENGE is sent and a PATH_RESPONSE should be recieved
by both.

On receiving a PATH_CHALLENGE frame, an endpoint MUST respond immediately by echoing 
the data contained in the PATH_CHALLENGE frame in a PATH_RESPONSE frame.

## ngtcp2 notes

```


### ng_frame_chaining

Lets set a breakpoint in sreadcb:
```console
(lldb) br set -n sreadcb
Breakpoint 4: where = server`(anonymous namespace)::sreadcb(ev_loop*, ev_io*, int) + 19 at server.cc:1960:37, address = 0x000000010001b083
```
The event loop is then started and will wait for incoming connections:
```c++
ev_run(EV_DEFAULT, 0);
```

So, at this point the server is listening for incoming connections. When a
connection arrives libev will call `sreadcb`. 

Let's switch to the client now as it is the client that initiates the connection
to the server.


I'm going to focus on the server for now and later walkthough the client, so
lets start the client without debugging:
```console.
$ ./examples/client localhost 7777 https://something/
```
This will break in `sreadcb`:
```c++
void sreadcb(struct ev_loop *loop, ev_io *w, int revents) {
  auto ep = static_cast<Endpoint *>(w->data);
  ep->server->on_read(*ep);
}
```
Notice that we are getting the Endpoint from the ev_io data member. This was set
previously when creating the endpoing `ep.rev.data = $ep`. And notice
that we are calling `Server::on_read`. At this point there was been no TLS
interaction at all. 

```c++
auto nread = recvfrom(ep.fd, buf.data(), buf.size(), MSG_DONTWAIT, &su.sa, &addrlen);
  ...
uint32_t version;
const uint8_t *dcid, *scid;
size_t dcidlen, scidlen;
rv = ngtcp2_pkt_decode_version_cid(&version,
                                   &dcid, &dcidlen,
                                   &scid, &scidlen,
                                   buf.data(), 
                                   nread,
                                   NGTCP2_SV_SCIDLEN);
```
Lets take a closer look at `ngtcp2_pkt_decode_version_cid`. The following
shows the format of a Long Header Packet:
```

0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
   +-+-+-+-+-+-+-+-+
   |1|1|T T|X X X X|
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                         Version (32)                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | DCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |               Destination Connection ID (0..160)            ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | SCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                 Source Connection ID (0..160)               ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

```c
if (data[0] & NGTCP2_HEADER_FORM_BIT) {
 ...
}
```
This will check the first byte of the buffer passed in, It is declared as:
```c++
std::array<uint8_t, 64_k> buf;
```
Which is a fixed size array with elements of type of uint8_t and a size of
64_k. Where is 64_k coming from?

This is from the spec:
```
Header Form:  The most significant bit (0x80) of byte 0 (the first
              byte) is set to 1 for long headers.
```

```c
dcidlen = data[5];
...
version = ngtcp2_get_uint32(&data[1]);

Version:  The QUIC Version is a 32-bit field that follows the first
      byte.  This field indicates which version of QUIC is in use and
      determines how the rest of the protocol fields are interpreted.
```

After this has been done we are back in server:cc on_read and have populated
version, dcid, scid, dcidlen, and scidlen.
```
auto dcid_key = util::make_cid_key(dcid, dcidlen);
```
This call is creating a new string from the dcid and it's length:
```c++
std::string make_cid_key(const uint8_t *cid, size_t cidlen) {
  return std::string(cid, cid + cidlen);
}
```
This is using the string constructor that takes a size_type count, and the 2gt
```console
(const uint8_t *) $16 = 0x00007ffeefbee2ae "��\bk\v\x10Q\x16\tdH\x8fQUR\x04\x8b�'�\x02�\b\f\x03G��\x98aD�t\x1b"
(lldb) expr cidlen
(size_t) $17 = 18
(lldb) expr dcid_key
(std::__1::basic_string<char, std::__1::char_traits<char>, std::__1::allocator<char> >) $18 = "��\bk\v\x10Q\x16\tdH\x8fQUR\x04\x8b��"
```

(uint8_t) $12 = '\x12'
(lldb) expr (int)$12
(int) $13 = 18


`on_read` will accept the connection and will parse the package. If all goes
well it will then create a new Handler for this connection:
```c++
auto h = std::make_unique<Handler>(loop_, ssl_ctx_, this, &hd.dcid);
h->init(ep, &su.sa, addrlen, &hd.scid, pocid, hd.version);
```

Handler::init
Each Handler has its own SSL context:
```c++
  ssl_ = SSL_new(ssl_ctx_);
  SSL_set_app_data(ssl_, this);
  SSL_set_accept_state(ssl_);
  SSL_set_quic_early_data_enabled(ssl_, 1);
```
And a Handler also has the callback server callbacks configured in init:
```c
auto callbacks = ngtcp2_conn_callbacks{
      nullptr, // client_initial
      ::recv_client_initial,
      ::recv_crypto_data,
      ::handshake_completed,
      nullptr, // recv_version_negotiation
      ngtcp2_crypto_encrypt_cb,
      ngtcp2_crypto_decrypt_cb,
      do_hp_mask,
      ::recv_stream_data,
      acked_crypto_offset,
      ::acked_stream_data_offset,
      stream_open,
      stream_close,
      nullptr, // recv_stateless_reset
      nullptr, // recv_retry
      nullptr, // extend_max_streams_bidi
      nullptr, // extend_max_streams_uni
      rand,
      get_new_connection_id,
      remove_connection_id,
      ::update_key,
      path_validation,
      nullptr, // select_preferred_addr
      ::stream_reset,
      ::extend_max_remote_streams_bidi, // extend_max_remote_streams_bidi,
      nullptr,                          // extend_max_remote_streams_uni,
      ::extend_max_stream_data,
  };
```

Then a server connection is created:
```c++
rv = ngtcp2_conn_server_new(&conn_, dcid, &scid_, &path, version, &callbacks,
                            &settings, nullptr, this);
...

```c
if (h->on_read(ep, &su.sa, addrlen, buf.data(), nread) != 0)
```

this will Handler::feed_data which in turn will call `ngtcp2_conn_read_pkt`.
```c
  switch (conn->state) {
  case NGTCP2_CS_CLIENT_INITIAL:
  case NGTCP2_CS_CLIENT_WAIT_HANDSHAKE:
  case NGTCP2_CS_CLIENT_TLS_HANDSHAKE_FAILED:
  case NGTCP2_CS_SERVER_INITIAL:
  case NGTCP2_CS_SERVER_WAIT_HANDSHAKE:
  case NGTCP2_CS_SERVER_TLS_HANDSHAKE_FAILED:
    return ngtcp2_conn_read_handshake(conn, path, pkt, pktlen, ts);
  case NGTCP2_CS_CLOSING:
    return NGTCP2_ERR_CLOSING;
  case NGTCP2_CS_DRAINING:
    return NGTCP2_ERR_DRAINING;
  case NGTCP2_CS_POST_HANDSHAKE:
    rv = conn_recv_cpkt(conn, path, pkt, pktlen, ts);
    if (rv != 0) {
      break;
    }
    if (conn->state == NGTCP2_CS_DRAINING) {
      return NGTCP2_ERR_DRAINING;
    }
    break;
  }
```
So in our case the state will be NGTCP2_CS_CLIENT_INITIAL and `ngtcp2_conn_read_handshake`
will be called.
```c
case NGTCP2_CS_SERVER_INITIAL:
  rv = conn_recv_handshake_cpkt(conn, path, pkt, pktlen, ts);
```
```c
while (pktlen) {
  nread = conn_recv_handshake_pkt(conn, path, pkt, pktlen, ts);
  ...
```
`conn_recv_handshake_pkt` (lib/ngtcp2_conn.c):
```c
static ssize_t conn_recv_handshake_pkt(ngtcp2_conn *conn,
                                       const ngtcp2_path *path,
                                       const uint8_t *pkt, size_t pktlen,
                                       ngtcp2_tstamp ts) {
...
  if (conn->server) {
    if ((conn->flags & NGTCP2_CONN_FLAG_CONN_ID_NEGOTIATED) == 0) {
      rv = conn_call_recv_client_initial(conn, &hd.dcid);
```
`conn_call_recv_client_initial`
```c
  rv = conn->callbacks.recv_client_initial(conn, dcid, conn->user_data);
```
This is where ngtcp2 calls the recv_client_initial callback. So this looks like
its is the first callback being invoked.
Notice user data is:
```console
(lldb) expr *(Handler*)conn->user_data
```


`recv_client_initial`:
auto h = static_cast<Handler *>(user_data);
if (h->recv_client_initial(dcid) != 0) {
  return NGTCP2_ERR_CALLBACK_FAILURE;
}
```
So we are now calling Hander::recv_client_initial.
```c
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_SECRETLEN> initial_secret, rx_secret, tx_secret;
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_KEYLEN> rx_key, rx_hp_key, tx_key, tx_hp_key;
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_IVLEN> rx_iv, tx_iv;

 if (ngtcp2_crypto_derive_and_install_initial_key(
          conn_, rx_secret.data(), tx_secret.data(), initial_secret.data(),
          rx_key.data(), rx_iv.data(), rx_hp_key.data(), tx_key.data(),
          tx_iv.data(), tx_hp_key.data(), dcid,
          NGTCP2_CRYPTO_SIDE_SERVER) != 0) {
    std::cerr << "ngtcp2_crypto_derive_and_install_initial_key() failed"
              << std::endl;
    return -1;
  }

```

`ngtcp2_crypto_derive_and_install_initial_key` can be found in `crypto/shared.c`.
```c
  ngtcp2_crypto_ctx ctx;

  ngtcp2_crypto_ctx_initial(&ctx);
```
`ngtcp2_crypto_ctx_initial`:
```c
ngtcp2_crypto_ctx *ngtcp2_crypto_ctx_initial(ngtcp2_crypto_ctx *ctx) {
  ctx->aead.native_handle = (void *)EVP_aes_128_gcm();
  ctx->md.native_handle = (void *)EVP_sha256();
  ctx->hp.native_handle = (void *)EVP_aes_128_ctr();
  return ctx;
}
```

ngtcp2_conn.c 4542:
```c
 case NGTCP2_FRAME_CRYPTO:
   rv = conn_recv_crypto(conn, crypto_level, crypto, &fr->crypto);
```
Then later in ngtcp2_conn.c conn_recv_crypto will call:
```c
 rv = conn_call_recv_crypto_data(conn, crypto_level, offset, data, datalen);
```c
rv = conn->callbacks.recv_crypto_data(conn, crypto_level, offset, data,
                                      datalen, conn->user_data);
```
This will call `recv_crypto_data` in server.cc.

This is where the CRYPTO data is logged:
```console
Ordered CRYPTO data in Initial crypto level
00000000  01 00 01 2b 03 03 6e 2f  89 18 0a b7 ec 58 23 6f  |...+..n/.....X#o|
00000010  12 77 b8 88 cd f4 9e 3e  17 e4 1c a1 04 86 ae 23  |.w.....>.......#|
00000020  12 01 72 cd 5a 0a 00 00  0a 13 01 13 02 13 03 13  |..r.Z...........|
00000030  04 00 ff 01 00 00 f8 00  00 00 0e 00 0c 00 00 09  |................|
00000040  6c 6f 63 61 6c 68 6f 73  74 00 0b 00 04 03 00 01  |localhost.......|
00000050  02 00 0a 00 0a 00 08 00  17 00 1d 00 18 00 19 00  |................|
00000060  23 00 00 00 10 00 08 00  06 05 68 33 2d 32 32 00  |#.........h3-22.|
00000070  16 00 00 00 17 00 00 00  0d 00 1e 00 1c 04 03 05  |................|
00000080  03 06 03 08 07 08 08 08  09 08 0a 08 0b 08 04 08  |................|
00000090  05 08 06 04 01 05 01 06  01 00 2b 00 03 02 03 04  |..........+.....|
000000a0  00 2d 00 02 01 01 00 33  00 47 00 45 00 17 00 41  |.-.....3.G.E...A|
000000b0  04 cc 01 3d 18 99 96 8d  9d d1 a5 cb 52 00 5e 46  |...=........R.^F|
000000c0  87 92 66 82 68 c3 54 26  50 85 88 79 1e 8c dd 90  |..f.h.T&P..y....|
000000d0  a4 1a 0b e8 8e 4a bd b4  96 99 7b c1 5a 2d 3a 09  |.....J....{.Z-:.|
000000e0  7c 67 58 b8 a6 85 dc 96  ab 78 1b 42 a5 e6 8b 4a  ||gX......x.B...J|
000000f0  a6 ff a5 00 3a 00 38 00  05 00 04 80 04 00 00 00  |....:.8.........|
00000100  06 00 04 80 04 00 00 00  07 00 04 80 04 00 00 00  |................|
00000110  04 00 04 80 10 00 00 00  08 00 01 01 00 09 00 02  |................|
00000120  40 64 00 01 00 04 80 00  75 30 00 0e 00 01 07     |@d......u0.....|
0000012f
```
```c
auto h = static_cast<Handler *>(user_data);
if (h->recv_crypto_data(crypto_level, data, datalen) != 0) {
```
Which will call ngtcp2_crypto_read_write_crypto_data which can be found in openssl.c.
This will in turn call SSL_provide_quic_data:
```c
if (SSL_provide_quic_data(ssl, from_ngtcp2_level(crypto_level), data, datalen)) {
```
Now, SSL_provide_quic_data is in ssl_quic.c.
Now this is where I tied into the morning session, asking about where the
data was stored. This is done using:
```c
memcpy((void*)(qd + 1), data, l);
```
After this ngtcp2_conn_get_handshake_completed
```c
 if (!ngtcp2_conn_get_handshake_completed(conn)) {
   rv = SSL_do_handshake(ssl);
```

statem.c:580
 } else if (SSL_IS_QUIC(s)) {
   581 	                ret = quic_get_message(s, &mt, &len);
1gt

 1180	    case TLS_ST_SR_CLNT_HELLO:
-> 1181	        return tls_process_client_hello(s, pkt)

tls_post_process_client_hello:
switch (s->ctx->client_hello_cb(s, &al, s->ctx->client_hello_cb_arg)) {


(lldb) bt 3
* thread #1, queue = 'com.apple.main-thread', stop reason = step in
  * frame #0: 0x000000010003ecff server`ngtcp2_crypto_read_write_crypto_data(conn=0x0000000101803600, tls=0x000000010180da00, crypto_level=NGTCP2_CRYPTO_LEVEL_INITIAL, data="\x01", datalen=303) at openssl.c:314:27
    frame #1: 0x000000010000999f server`Handler::recv_crypto_data(this=0x0000000100605bd0, crypto_level=NGTCP2_CRYPTO_LEVEL_INITIAL, data="\x01", datalen=303) at server.cc:1478:10
    frame #2: 0x0000000100008f48 server`(anonymous namespace)::recv_crypto_data(conn=0x0000000101803600, crypto_level=NGTCP2_CRYPTO_LEVEL_INITIAL, offset=0, data="\x01", datalen=303, user_data=0x0000000100605bd0) at server.cc:787:10

 314 	    rv = SSL_do_handshake(ssl);

When this happens SSL will call any SSL callbacks.
(lldb) br s -f openssl.c -l 314

`SSL_do_handshake` can be found in `ssl_lib.c`:
```c
int SSL_do_handshake(SSL *s) {

}
```
The SSL struct is large so I can't document it, just going to show some 
quic related properties:
```console
(lldb) expr *s->quic_method
(SSL_QUIC_METHOD) $2 = {
  set_encryption_secrets = 0x0000000100021240 (server`(anonymous namespace)::set_encryption_secrets(ssl_st*, ssl_encryption_level_t, unsigned char const*, unsigned char const*, unsigned long) at server.cc:2766)
  add_handshake_data = 0x00000001000212c0 (server`(anonymous namespace)::add_handshake_data(ssl_st*, ssl_encryption_level_t, unsigned char const*, unsigned long) at server.cc:2781)
  flush_flight = 0x0000000100021320 (server`(anonymous namespace)::flush_flight(ssl_st*) at server.cc:2789)
  send_alert = 0x0000000100021330 (server`(anonymous namespace)::send_alert(ssl_st*, ssl_encryption_level_t, unsigned char) at server.cc:2793)
}
(lldb) expr s->ext.quic_transport_params
(uint8_t *) $6 = 0x0000000100c03740 "
(lldb) expr s->quic_write_level
(OSSL_ENCRYPTION_LEVEL) $8 = ssl_encryption_initial
(lldb) expr s->quic_read_level
(OSSL_ENCRYPTION_LEVEL) $9 = ssl_encryption_initial
```

```console
* thread #1, queue = 'com.apple.main-thread', stop reason = step over
  * frame #0: 0x000000010029f6b5 libssl.3.dylib`read_state_machine(s=0x0000000102000600) at statem.c:580:24
    frame #1: 0x000000010029f085 libssl.3.dylib`state_machine(s=0x0000000102000600, server=1) at statem.c:435:21
    frame #2: 0x000000010029f26a libssl.3.dylib`ossl_statem_accept(s=0x0000000102000600) at statem.c:256:12
    frame #3: 0x000000010025f29e libssl.3.dylib`SSL_do_handshake(s=0x0000000102000600) at ssl_lib.c:3776:19
    frame #4: 0x000000010003ed08 server`ngtcp2_crypto_read_write_crypto_data(conn=0x0000000102002400, tls=0x0000000102000600, crypto_level=NGTCP2_CRYPTO_LEVEL_INITIAL, data="\x01", datalen=303) at openssl.c:314:10
```
In `statem.c` we have:
```
```c
} else if (SSL_IS_QUIC(s))
  ret = quic_get_message(s, &mt, &len);
```
SSL_IS_QUIC is a macro that looks like this (../openssl/ssl/ssl_locl.h):
```
#  define SSL_IS_QUIC(s)  (s->quic_method != NULL)
```
`quic_get_message` can be found in ../openssl/ssl/statem/statem_quic.c:
```c
QUIC_DATA *qd = s->quic_input_data_head;
```
`QUIC_DATA` is a struct that looks like this (../openssl/ssl/ssl_locl.h):
```c
struct quic_data_st {
    struct quic_data_st *next;
    OSSL_ENCRYPTION_LEVEL level;
    size_t offset;
    size_t length;
};
typedef struct quic_data_st QUIC_DATA;
```
`OSSL_ENCRYPTION_LEVEL` (../openssl/build/include/openssl/ssl.h):
```c
typedef enum ssl_encryption_level_t {
    ssl_encryption_initial = 0,
    ssl_encryption_early_data,
    ssl_encryption_handshake,
    ssl_encryption_application
} OSSL_ENCRYPTION_LEVEL;
```
```console
(lldb) expr *qd
(QUIC_DATA) $12 = {
  next = 0x0000000000000000
  level = ssl_encryption_initial
  offset = 303
  length = 303
}
```

```c
memcpy(s->init_buf->data, (void*)(qd + 1), qd->length);
```
Just keep in mind that destiation comes first, then the source, followed by 
the number of bytes to copy:
```c
void * memcpy(void *restrict dst, const void *restrict src, size_t n);
```
So in our case we are copying source buffer specified using:
```
(void*)(qd + 1)
``` 
Now, qd is a pointer to our quic_data_st struct. This will increment the source
pointer 32 bytes, to what every comes after the struct. How do we know what is
there?

```console
(lldb) br s -f ssl_quic.c -l 100
(lldb) br s -f statem_quic.c -l 46
```
The first break point will break in `SSL_provide_quic_data` which is called
by ngtcp2_crypto_read_write_crypto_data:
```c
if (SSL_provide_quic_data(ssl, from_ngtcp2_level(crypto_level), data, datalen)
```
(../openssl/ssl/ssl_quic.c):
```c
  memcpy((void*)(qd + 1), data, l);
```
So we can see that this is how data to to qd+1.


* frame #0: 0x00000001000210c4 server`(anonymous namespace)::client_hello_cb(ssl=0x0000000101800600, al=0x00007ffeefbebf84, arg=0x0000000000000000) at server.cc:2814:34
    frame #1: 0x00000001002b9f10 libssl.3.dylib`tls_early_post_process_client_hello(s=0x0000000101800600) at statem_srvr.c:1617:17


statem.c:580

else if (SSL_IS_QUIC(s)) {
   581 	                ret = quic_get_message(s, &mt, &len);


statem_srvr.c:1617:17
1617	        switch (s->ctx->client_hello_cb(s, &al, s->ctx->client_hello_cb_arg)) {

lldb) expr s->ctx->client_hello_cb
(SSL_client_hello_cb_fn) $58 = 0x00000001000210b0 (server`(anonymous namespace)::client_hello_cb(ssl_st*, int*, void*) at server.cc:2810)


ssl3_do_write  statem_lib.c:47
```c
ret = s->quic_method->add_handshake_data(s,
                                         s->quic_write_level,
                                         (const uint8_t*)&s->init_buf->data[s->init_off],
                                          s->init_num);
```
This calls server`(anonymous namespace)::add_handshake_data



So to recap: 
1) sreadcb is called which just does
```c++
  auto ep = static_cast<Endpoint *>(w->data);
  ep->server->on_read(*ep);
```
2) Server::on_read
Will decode/parse the read data extracting the version, dcid, scid. If there
was no handler for this dcid one will be created.gt
ngtcp2_pkt_hd hd;
...
rv = ngtcp2_accept(&hd, buf.data(), nread);
 
(lldb) memory read -c 303 -f x "qd+1)" --force

Recall that server.cc sets up a few OpenSSL releated callbacks:
but note that these are set on the context and not the SSL instance.
```c++
 SSL_CTX_set_alpn_select_cb(ssl_ctx, alpn_select_proto_cb, nullptr);
 SSL_CTX_set_client_hello_cb(ssl_ctx, client_hello_cb, nullptr);
```



------------------

```c
v = conn_call_recv_client_initial(conn, &hd.dcid);
```
This will call the registered callback for client initial:
```
rv = conn->callbacks.recv_client_initial(conn, dcid, conn->user_data);
```
Before the call to `conn_call_recv_client_initial` we were only in ngtcp2 core.
Core does not know anything about the example and classes like Handler. This is
passed as the void pointer user_data:
```c++
auto h = static_cast<Handler *>(user_data);
if (h->recv_client_initial(dcid)
```

```c
int Handler::recv_client_initial(const ngtcp2_cid *dcid) {
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_SECRETLEN> initial_secret,
                                                       rx_secret,
                                                       tx_secret;
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_KEYLEN> rx_key,
                                                    rx_hp_key,
                                                    tx_key,
                                                    tx_hp_key;
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_IVLEN> rx_iv, tx_iv;

  if (ngtcp2_crypto_derive_and_install_initial_key(conn_,
                                                   rx_secret.data(),
                                                   tx_secret.data(),
                                                   initial_secret.data(),
                                                   rx_key.data(),
                                                   rx_iv.data(),
                                                   rx_hp_key.data(),
                                                   tx_key.data(),
                                                   tx_iv.data(),
                                                   tx_hp_key.data(),
                                                   dcid,
                                                   NGTCP2_CRYPTO_SIDE_SERVER) != 0) {
    std::cerr << "ngtcp2_crypto_derive_and_install_initial_key() failed" << std::endl;
    return -1;
  }
```








```c++
  SSL_CTX_set_client_hello_cb(ssl_ctx, client_hello_cb, nullptr);
```






### ngtcp_conn_client_new
This function takes a number of parameters like connection, dcid, scid, path, version, callbacks, settings and user_data.
Lets take a look at path:
```console
(lldb) expr *path
(ngtcp2_path) $1 = {
  local = (len = 28, addr = "\x1c\x1e\xffffffec\xfffffffd")
  remote = (len = 28, addr = "\x1c\x1e\x1ea")
}
```
So this contains the local and remote addresses and is used for path validation
which endpoints test the reachability between a specific local address and a 
specific peer address.


The QUIC OpenSSL callback:
```console
(lldb) bt
* thread #1, queue = 'com.apple.main-thread', stop reason = step in
  * frame #0: 0x00000001001872fd libssl.3.dylib`ssl3_write_bytes(s=0x0000000102800000, type=22, buf_=0x0000000102002e00, len=296, written=0x00007ffeefbfdc90) at rec_layer_s3.c:353
    frame #1: 0x00000001001b2bbf libssl.3.dylib`ssl3_do_write(s=0x0000000102800000, type=22) at statem_lib.c:46
    frame #2: 0x00000001001508ba libssl.3.dylib`ssl3_handshake_write(s=0x0000000102800000) at s3_lib.c:3289
    frame #3: 0x00000001001a5727 libssl.3.dylib`statem_do_write(s=0x0000000102800000) at statem.c:707
    frame #4: 0x00000001001a5349 libssl.3.dylib`write_state_machine(s=0x0000000102800000) at statem.c:860
    frame #5: 0x00000001001a4308 libssl.3.dylib`state_machine(s=0x0000000102800000, server=0) at statem.c:441
    frame #6: 0x00000001001a3e67 libssl.3.dylib`ossl_statem_connect(s=0x0000000102800000) at statem.c:250
    frame #7: 0x000000010016500d libssl.3.dylib`SSL_do_handshake(s=0x0000000102800000) at ssl_lib.c:3608
    frame #8: 0x00000001000047be client`Client::tls_handshake(this=0x00007ffeefbfe058, initial=true) at client.cc:1096 [opt]
    frame #9: 0x0000000100003c24 client`(anonymous namespace)::client_initial(conn=<unavailable>, user_data=<unavailable>) at client.cc:511 [opt]
    frame #10: 0x000000010001b6f8 client`conn_write_handshake [inlined] conn_write_client_initial(conn=<unavailable>, dest=<unavailable>, destlen=<unavailable>, early_datalen=0, ts=<unavailable>) at ngtcp2_conn.c:1638 [opt]
    frame #11: 0x000000010001b6ea client`conn_write_handshake(conn=0x0000000100802800, dest="", destlen=1232, early_datalen=0, ts=1549444042830946816) at ngtcp2_conn.c:6508 [opt]
    frame #12: 0x00000001000053c3 client`Client::do_handshake_write_once(this=0x00007ffeefbfe058) at client.cc:1217 [opt]
    frame #13: 0x000000010000a5e0 client`main [inlined] (anonymous namespace)::run(c=0x000000000000001c, addr=<unavailable>, port=<unavailable>) at client.cc:2392 [opt]
    frame #14: 0x000000010000a38c client`main(argc=<unavailable>, argv=<unavailable>) at client.cc:2690 [opt]
    frame #15: 0x00007fff6a656085 libdyld.dylib`start + 1
    frame #16: 0x00007fff6a656085 libdyld.dylib`start + 1
```


And this is where the msg_cb (in client.cc) is called:
```console
(lldb) bt
* thread #1, queue = 'com.apple.main-thread', stop reason = step in
  * frame #0: 0x00000001000033cc client`(anonymous namespace)::msg_cb(write_p=1, version=772, content_type=22, buf=0x0000000102002e00, len=296, ssl=0x0000000102800000, arg=0x00007ffeefbfe058) at client.cc:203 [opt]
    frame #1: 0x00000001001b2d15 libssl.3.dylib`ssl3_do_write(s=0x0000000102800000, type=22) at statem_lib.c:65
    frame #2: 0x00000001001508ba libssl.3.dylib`ssl3_handshake_write(s=0x0000000102800000) at s3_lib.c:3289
    frame #3: 0x00000001001a5727 libssl.3.dylib`statem_do_write(s=0x0000000102800000) at statem.c:707
    frame #4: 0x00000001001a5349 libssl.3.dylib`write_state_machine(s=0x0000000102800000) at statem.c:860
    frame #5: 0x00000001001a4308 libssl.3.dylib`state_machine(s=0x0000000102800000, server=0) at statem.c:441
    frame #6: 0x00000001001a3e67 libssl.3.dylib`ossl_statem_connect(s=0x0000000102800000) at statem.c:250
    frame #7: 0x000000010016500d libssl.3.dylib`SSL_do_handshake(s=0x0000000102800000) at ssl_lib.c:3608
    frame #8: 0x00000001000047be client`Client::tls_handshake(this=0x00007ffeefbfe058, initial=true) at client.cc:1096 [opt]
    frame #9: 0x0000000100003c24 client`(anonymous namespace)::client_initial(conn=<unavailable>, user_data=<unavailable>) at client.cc:511 [opt]
    frame #10: 0x000000010001b6f8 client`conn_write_handshake [inlined] conn_write_client_initial(conn=<unavailable>, dest=<unavailable>, destlen=<unavailable>, early_datalen=0, ts=<unavailable>) at ngtcp2_conn.c:1638 [opt]
    frame #11: 0x000000010001b6ea client`conn_write_handshake(conn=0x0000000100802800, dest="", destlen=1232, early_datalen=0, ts=1549444042830946816) at ngtcp2_conn.c:6508 [opt]
    frame #12: 0x00000001000053c3 client`Client::do_handshake_write_once(this=0x00007ffeefbfe058) at client.cc:1217 [opt]
    frame #13: 0x000000010000a5e0 client`main [inlined] (anonymous namespace)::run(c=0x000000000000001c, addr=<unavailable>, port=<unavailable>) at client.cc:2392 [opt]
    frame #14: 0x000000010000a38c client`main(argc=<unavailable>, argv=<unavailable>) at client.cc:2690 [opt]
    frame #15: 0x00007fff6a656085 libdyld.dylib`start + 1
    frame #16: 0x00007fff6a656085 libdyld.dylib`start + 1
(lldb)
```
This callback is required as it gives us the ability to perform the actual sending
to the remote peer.

Logging:
```
I00000000 0xd2b423b792d83d40db7d54057f6315d4635e con recv packet len=1232
```
```c
ngtcp2_log_info(&conn->log, NGTCP2_LOG_EVENT_CON, "recv packet len=%zu",
6359                     pktlen);
```

```c
log->log_printf(log->user_data, (NGTCP2_LOG_HD " %s\n"),
   702 	                  timestamp_cast(log->last_ts - log->ts), log->scid,
   703 	                  strevent(ev), buf);
-> 704 	}
```

#### ngtcp2_conn
Lets get some basic understanding of what this struct contains. This is the
object that we register our callbacks on.
There are also a number of members of type `ngtcp2_cid`:
```c
typedef struct {
  size_t datalen;
  uint8_t data[NGTCP2_MAX_CIDLEN];
} ngtcp2_cid;
```
So this is a very simple structure with a length and an array with the actual
value of the connection id.
There are a number of these `rcid`, `ocid`, `oscid`, `odcid`. 
Each connection has a destination connection id member of type `ngtcp2_dcid`.

There is a `bound_dcids` of type `ngtcp2_ringbuf`
When a new connection is created using `conn_new`, for example using `ngtcp_conn_client_new`
a ringbuffer is created for `bound_dcids`.
```c
rv = ngtcp2_ringbuf_init(&(*pconn)->bound_dcids,
                           NGTCP2_MAX_BOUND_DCID_POOL_SIZE, sizeof(ngtcp2_dcid),
                           mem);
```
The ringbuffer struct looks like this:
```c
typedef struct {
  /* buf points to the underlying buffer. */
  uint8_t *buf;
  ngtcp2_mem *mem;
  /* nmemb is the number of elements that can be stored in this ring
     buffer. */
  size_t nmemb;
  /* size is the size of each element. */
  size_t size;
  /* first is the offset to the first element. */
  size_t first;
  /* len is the number of elements actually stored. */
  size_t len;
} ngtcp2_ringbuf;
```
So we are creating a new ringbuffer of size 4, and the size of the elemets in 
the underlying buffer will be sizeof(ngtcp2_dcid). So that is done
when a connection is created.

When a NEW_CONNECTION_ID frame is recieved the function `conn_recv_new_connection_id`
will be called. Now, this frame has a sequence number, a length field, a 
connection id, and a stateless reset token.
What is the stateless reset token for?  
This is a 128-bit value that can be used as an option of last resort when

```c
dcid = ngtcp2_ringbuf_push_back(&conn->dcids);
ngtcp2_dcid_init(dcid, fr->seq, &fr->cid, fr->stateless_reset_token);
```
The first time this is called an empty ngtcp2_dcid will be returned.

#### Destination connection id
This struct can be found in `lib/ngtcp2_cid.h`
```c
typedef struct {
  /* seq is the sequence number associated to the CID. */
  uint64_t seq;
  /* cid is a connection ID */
  ngtcp2_cid cid;
  /* path is a path which cid is bound to.  The addresses are zero
     length if cid has not been bound to a particular path yet. */
  ngtcp2_path path;
  /* token is a stateless reset token associated to this CID.
     Actually, the stateless reset token is tied to the connection,
     not to the particular connection ID. */
  uint8_t token[NGTCP2_STATELESS_RESET_TOKENLEN];
  uint8_t local_addrbuf[128];
  uint8_t remote_addrbuf[128];
} ngtcp2_dcid;
```

#### Path validation
https://tools.ietf.org/html/draft-ietf-quic-transport-19#section-8.2

`ngtcp2_path_validation` is a callback that can be set on the connection object. This
is called to inform the application about the outcome of path validation.
Where is this used?  
Is is used when setting the callbacks and is called from `conn_call_path_validation`:
```c
static int conn_call_path_validation(ngtcp2_conn *conn, const ngtcp2_path *path,
                                     ngtcp2_path_validation_result res) {
  int rv;
  ...

  rv = conn->callbacks.path_validation(conn, path, res, conn->user_data);
  if (rv != 0) {
    return NGTCP2_ERR_CALLBACK_FAILURE;
  }

  return 0;
}
```
This function is called from `ngtcp2_conn.c`'s conn_recv_path_response:
```
static int conn_recv_path_response(ngtcp2_conn *conn, const ngtcp2_path *path,
                                   ngtcp2_path_response *fr) {
  int rv;
  ngtcp2_pv *pv = conn->pv, *npv = NULL;
  ngtcp2_duration timeout;

  if (!pv) {
    return 0;
  }

  rv = ngtcp2_pv_validate(pv, path, fr->data);
  if (rv != 0) {
    if (rv == NGTCP2_ERR_PATH_VALIDATION_FAILED) {
      return conn_on_path_validation_failed(conn, pv);
    }
    return 0;
  }
```
`pv` is for path validation and is a struct containing the context of a path validation.
Notice how the validation is performed by `ngtcp2_pv_validate`

So in node, what action should be taken if path validation fails/succeeds?  
When an endpoint does a connection migration it need to verify that it can communicate
with the remote peer through the new local address.
So the migrating endpoint would send a PATH_CHALLENGE to the remote peer. After
a succesful validation the local address of the connection should be updated.

What should happen if path validation fails?  
We have tried to do a connection migration but failed. Should this throw and
error to indicate this. If the migration happened because a switch from wifi to
3g/4g then the old local address is probably not useable anymore.

The connection passed into this callback, it is the same as the existing connection, 
assuming that it has been stored somewhere in the class/struct?



It is also called from `conn_on_path_validation_failed`:
```c
rv = conn_call_path_validation(conn, &pv->dcid.path, NGTCP2_PATH_VALIDATION_RESULT_FAILURE);
```
And it is also called from `conn_recv_path_response`:
```c
rv = conn_call_path_validation(conn, &pv->dcid.path, NGTCP2_PATH_VALIDATION_RESULT_SUCCESS);
```

```c
struct ngtcp2_pv {
  ngtcp2_mem *mem;
  ngtcp2_log *log;
  /* dcid is DCID and path this path validation uses. */
  ngtcp2_dcid dcid;
  /* ents is the ring buffer of ngtcp2_pv_entry */
  ngtcp2_ringbuf ents;
  /* timeout is the duration within which this path validation should
     succeed. */
  ngtcp2_duration timeout;
  /* started_ts is the timestamp this path validation starts. */
  ngtcp2_tstamp started_ts;
  /* loss_count is the number of lost PATH_CHALLENGE */
  size_t loss_count;
  /* flags is bitwise-OR of zero or more of ngtcp2_pv_flag. */
  uint8_t flags;
};
```
This path validation struct as acts as a context for path validation.
Notice that it has a ringbuffer `ents` as its member.
This is created in `ngtcp2_pv_new`:
```c
rv = ngtcp2_ringbuf_init(&(*ppv)->ents, NGTCP2_PV_MAX_ENTRIES,
                           sizeof(ngtcp2_pv_entry), mem);
```
The above call will create a ringbuffer of size 4, the elements that the underlying
buffer will hold will be of sizeof(ngtcp2_pv_entry). 
```c
typedef struct {
  /* expiry is the timestamp when this PATH_CHALLENGE expires. */
  ngtcp2_tstamp expiry;
  /* data is a byte string included in PATH_CHALLENGE. */
  uint8_t data[8];
} ngtcp2_pv_entry;
```
Adding a path validation entry consists of getting a pointer to the front of
the ringbuffer and then initializing what that points to:
```c
void ngtcp2_pv_add_entry(ngtcp2_pv *pv, const uint8_t *data,
                         ngtcp2_tstamp expiry) {
  ngtcp2_pv_entry *ent = ngtcp2_ringbuf_push_back(&pv->ents);
  ngtcp2_pv_entry_init(ent, data, expiry);
}
```
So the max number of elements that this ringbuffer can store if 4, if more are
added then they start overwriting the first one. `ngtcp2_pv_validate` will
iterate over all the entries in the ringbuffer and compare the data/token
that the entries contain with the data expected:
```c
for (i = 0; i < len; ++i) {
  ent = ngtcp2_ringbuf_get(&pv->ents, i);
  if (memcmp(ent->data, data, sizeof(ent->data)) == 0) {
    ngtcp2_log_info(pv->log, NGTCP2_LOG_EVENT_PTV, "path has been validated");
    return 0;
  }
}
```
If any of the entries can be validated then 0 is returned, and otherwise
`NGTCP2_ERR_INVALID_ARGUMENT` will be returned.

So when are entries added?  
This happens when a PATH_CHALLENGE is writen using `conn_write_path_challenge`:
```c
ngtcp2_pv *pv = conn->pv;
...
if (ngtcp2_pv_full(pv)) {
    return 0;
}
rv = conn->callbacks.rand(conn, lfr.path_challenge.data,
                          sizeof(lfr.path_challenge.data),
                          NGTCP2_RAND_CTX_PATH_CHALLENGE, conn->user_data);

lfr.type = NGTCP2_FRAME_PATH_CHALLENGE;
```
Notice that if the ring buffer is full then the new entry is not added.
ngtcp2_pv_add_entry(pv, lfr.path_challenge.data, expiry);


Does each connection have it's own path validation context?
Yes, the ngtcp2_conn struct has a `ngtcp2_pv *pv` member.


When you see types/variables named hs this usually stands for handshake I think.

#### Ring buffer in ngtcp2

#### ngtcp2_ksl
Is a skip list implementation. Recall that this has a normal list and an 
express "lane/list". Searching for an item can take the express lane until it 
finds a node in the express lane that is greater than the item being looked up.
Then it can swich to the normal lane but it will have hopefully skipped a number
of items, or we know that the item is in the first section and we will only have
to possibly traverse all of them if the item being searched for it the last one.


#### QUIC encryption levels
```
* Plaintext
* Early Data/0-RTT Keys
* Handshake Keys
* Application Data/1-RTT Keys

In the server example there is a callback named `do_hs_encrypt`, do handshake 
encrypt which is of type ngtcp2_encrypt:
```c
typedef ssize_t (*ngtcp2_encrypt)(ngtcp2_conn *conn, uint8_t *dest,
                                  size_t destlen, const uint8_t *plaintext,
                                  size_t plaintextlen, const uint8_t *key,
                                  size_t keylen, const uint8_t *nonce,
                                  size_t noncelen, const uint8_t *ad,
                                  size_t adlen, void *user_data);
This callback is only for the initial packets (or handshake which is why I think
they are named do_hs_encrypt/do_hs_decrypt in the examples. Would it not be clearer
to name these do_initial_encrypt/do_initial_decrypt. Just the fact that I've had
to make a note here seems that this would make things a littler clearer.


```

Building OpenSSL
```console
$ ./config enable-tls1_3 --prefix=$PWD/build
$ make -j8
$ make -j8 install_sw
```

Building nghttp3
```console
$ autoreconf -i
$ ./configure --prefix=$PWD/build --enable-lib-only
$ make -j check
$ make install
```

Building: 
```console
$ ./configure PKG_CONFIG_PATH=$PWD/../openssl/build/lib/pkgconfig:$PWD/../nghttp3/build/lib/pkgconfig LDFLAGS="-O0 -Wl,-rpath,$PWD/../openssl/build/lib"
$ make -j8 
$ make check
```


To configure with debugging enabled:
```console
$ ./configure PKG_CONFIG_PATH=$PWD/../openssl/build/lib/pkgconfig:$PWD/../nghttp3/build/lib/pkgconfig LDFLAGS="-O0 -Wl,-rpath,$PWD/../openssl/build/lib" --enable-debug --disable-shared CFLAGS="-O0" CXXFLAGS="-O0"
```

```console
$ openssl req -nodes -new -x509 -keyout examples/server.key -out examples/server.cert
$ ./examples/server localhost 7777 examples/server.key examples/server.cert
$ ./client localhost 7777 https://something
```

ctags
```
$ ctags -R * ../openssl ../nghttp3
```


### ngtcp2 server example notes
The following configuration is done in `create_ssl_ctx`:
```c++
SSL_CTX_set_alpn_select_cb(ssl_ctx, alpn_select_proto_cb, nullptr);
```
Notice that the callback, `alpn_select_proto_cb` is being set. The last argument
is the could be anything that should be passed to the callback as the last argument.
The function declaration looks like this:
```c++
typedef int (*SSL_CTX_alpn_select_cb_func)(SSL *ssl,
                                           const unsigned char **out,
                                           unsigned char *outlen,
                                           const unsigned char *in,
                                           unsigned int inlen,
                                           void *arg);
```

```c++
SSL_CTX_set_client_hello_cb(ssl_ctx, client_hello_cb, nullptr);
```



### TLS Transport

+---------------------+------------------+-----------+
| Packet Type         | Encryption Level | PN Space  |
+---------------------+------------------+-----------+
| Initial             | Initial secrets  | Initial   |
|                     |                  |           |
| 0-RTT Protected     | 0-RTT            | 0/1-RTT   |
|                     |                  |           |
| Handshake           | Handshake        | Handshake |
|                     |                  |           |
| Retry               | N/A              | N/A       |
|                     |                  |           |
| Version Negotiation | N/A              | N/A       |
|                     |                  |           |
| Short Header        | 1-RTT            | 0/1-RTT   |
+---------------------+------------------+-----------+
The TLS handshake is considered confirmed at an
endpoint when the following two conditions are met: the handshake is
complete, and the endpoint has received an acknowledgment for a
packet sent with 1-RTT keys.

### CRYPTO frame (type=0x06) 
    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                          Offset (i)                         ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                          Length (i)                         ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                        Crypto Data (*)                      ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

The first CRYPTO frame from a client MUST be sent in a single packet.
The first client packet of the cryptographic handshake protocol MUST
   fit within a 1232 byte QUIC packet payload. 

The cryptographic handshake is carried in Initial and Handshake packets.


### Initial Packet
An Initial packet uses long headers with a type value of 0x0.
It carries the first CRYPTO frames sent by the client and server to
perform key exchange, and carries ACKs in either direction.

   +-+-+-+-+-+-+-+-+
   |1|1| 0 |R R|P P|
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                         Version (32)                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | DCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |               Destination Connection ID (0..160)            ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | SCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                 Source Connection ID (0..160)               ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                         Token Length (i)                    ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                            Token (*)                        ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                           Length (i)                        ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                    Packet Number (8/16/24/32)               ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                          Payload (*)                        ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

The CRYPTO frame would be in the Payload.


ConnectionID

Sender -> :
    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
   +-+-+-+-+-+-+-+-+
   |1|1|T T|X X X X|
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                         Version (32)                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | DCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |               Destination Connection ID (0..160)            ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | SCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                 Source Connection ID (0..160)               ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

The receiver sets the Destination Connection ID before sending. This allows 


ngtcp_cc.{h,cc} is congestion control
ngtcp2_idtr tracks the usage of stream ID.
This is used in conn_new in ngtcp2_conn.c:
```
 rv = ngtcp2_idtr_init(&(*pconn)->remote.bidi.idtr, !server, mem);
```
What is mem? It is a struct that looks like this:
```c
(ngtcp2_mem) $1 = {
  mem_user_data = 0x0000000000000000
  malloc = 0x000000010005fb00 (server`default_malloc at ngtcp2_mem.c:28)
  free = 0x000000010005fb20 (server`default_free at ngtcp2_mem.c:34)
  calloc = 0x000000010005fb40 (server`default_calloc at ngtcp2_mem.c:40)
  realloc = 0x000000010005fb70 (server`default_realloc at ngtcp2_mem.c:46)
}
```
This struct is declared in `includes/ngtcp2/ngtcp2.h`:
```c
typedef struct {
  /**
   * An arbitrary user supplied data.  This is passed to each
   * allocator function.
   */
  void *mem_user_data;
  /**
   * Custom allocator function to replace malloc().
   */
  ngtcp2_malloc malloc;
  /**
   * Custom allocator function to replace free().
   */
  ngtcp2_free free;
  /**
   * Custom allocator function to replace calloc().
   */
  ngtcp2_calloc calloc;
  /**
   * Custom allocator function to replace realloc().
   */
  ngtcp2_realloc realloc;
} ngtcp2_mem;
```
```
static const ngtcp2_mem mem_default = {NULL, default_malloc, default_free,
                                       default_calloc, default_realloc};

const ngtcp2_mem *ngtcp2_mem_default(void) { return &mem_default; }
```
So back to our call, what actually happens in this function:
```c
 rv = ngtcp2_idtr_init(&(*pconn)->remote.bidi.idtr, !server, mem);
```
By looking at this we are initializing tracking of bidirectional stream ids,
the connection is not a server initiated connection in this case, it is a client
connection and mem is the default mem from above.
```c
int ngtcp2_idtr_init(ngtcp2_idtr *idtr, int server, const ngtcp2_mem *mem) {
  int rv = ngtcp2_gaptr_init(&idtr->gap, mem);
  if (rv != 0) {
    return rv;
  }
  idtr->server = server;
  return 0;
}
```
So we are passing in a reference to the gap member of `idtr` which is a struct
of type ngtcp2_idtr:
```c
/*
 * ngtcp2_idtr tracks the usage of stream ID.
 */
typedef struct {
  /* gap maintains the range of ID which is not used yet. Initially,
     its range is [0, UINT64_MAX). */
  ngtcp2_gaptr gap;
  /* server is nonzero if this object records server initiated stream
     ID. */
  int server;
} ngtcp2_idtr;
```
Let's take a closer look at what `ngtcp2_gaptr_init` does:
```c
  ngtcp2_range range = {0, UINT64_MAX};
  ngtcp2_ksl_key key;

  rv = ngtcp2_ksl_init(&gaptr->gap, ngtcp2_ksl_range_compar,
                       sizeof(ngtcp2_range), mem);
```
ngtcp2_range is a 
```c
/*
 * ngtcp2_range represents half-closed range [begin, end).
 */
typedef struct {
  uint64_t begin;
  uint64_t end;
} ngtcp2_range;
```
The range [1,5) is half-open/half-closed, and consists of the values 1, 2, 3 and 4.
Now, let move our attention to `ngtcp2_ksl_key`.

This is a skip list implementation. Where does this initial `k` come from?
Perhaps is comes from that this is for a single key which is mentioned in 
the header comment.

TODO: Take a closer look at the skip list implementation.

The same thing is then done to set up tracking on unidirectional stream ids:
```c
  rv = ngtcp2_idtr_init(&(*pconn)->remote.uni.idtr, !server, mem);
```



### Pass by ref, or const?
```c++
struct HTTPHeader {
  HTTPHeader(const std::string &name, const std::string &value) :
    name(name),value(value) {}

  std::string name;
  std::string value;
};
```

Now, if the string will not be modified the we can pass it as a const
```c++
std::string const&
```

Modifying the string but not wanting the caller to see that change. 
Passing it in by value is preferable: (std::string)

Modifying the string but wanting the caller to see that change. 
Passing it in by reference is preferable: (std::string &)

Sending the string into the function and the caller of the function will never 
use the string again. Using move semantics might be an option (std::string &&)



Each encryption level has separate secret values for protection of
packets sent in each direction.  These traffic secrets are derived by TLS, 
and are used by QUIC for all encryption levels except the Initial encryption level.

The secrets for the Initial encryption level are computed based on the client's
initial Destination Connection ID.

The keys used for packet protection are computed from the TLS secrets
using the KDF (Key Derivation Function) provided by TLS

In TLS 1.3, the HKDF-Expand-Label function described in Section 7.1 is used,
using the hash function from the negotiated cipher suite.
This is done by ngtcp2_crypto_hkdf_expand_label which I've be wondering about 
the name expand label and what it refers to?

https://tools.ietf.org/html/rfc8446#section-7


The key derivation process makes use of the HKDF-Extract and
HKDF-Expand functions as defined for HKDF

Hashed Message Authentication Code (HMAC)-based key derivation function (HKDF)
A key derivation function (KDF) is a basic and essential component of
cryptographic systems.  Its goal is to take some source of initial
keying material and derive from it one or more cryptographically
strong secret keys.

HKDF follows the "extract-then-expand" paradigm, where the KDF
logically consists of two modules. 
The first stage takes the input keying material and "extracts" from it a 
ixed-length pseudorandom key K.
The second stage "expands" the key K into several additional pseudorandom keys 
(the output of the KDF).

So we first extract a secret from the peer which we then use to produce other
protection keys?

Where is this function called when using example in ngtcp2:
```console
ngtcp2_crypto_hkdf_expand_label
ngtcp2_crypto_derive_initial_secrets
ngtcp2_crypto_derive_and_install_initial_key
Handler::recv_client_initial
Server::recv_client_initial

```

quic_set_encryption_secrets extracts the client and server secret:
```c
    case ssl_encryption_handshake:
        c2s_secret = ssl->client_hand_traffic_secret;
        s2c_secret = ssl->server_hand_traffic_secret;
```
g

An EVP_MD abstracts the details of a specific hash function allowing code to 
deal with the concept of a "hash function" without needing to know exactly which 
hash function it is.

quic_set_encryption_secrets will later call `ssl->quic_method->set_encryption_secrets`
```c
if (!ssl->quic_method->set_encryption_secrets(ssl, level, c2s_secret,
                                              s2c_secret, len)) {
```
This will land back in server.cc the only thing set_encryption_secrets does
is extract the Hander from the ssl user data, using SSL_get_app_data(ssl) and
then calling the handler's on_key function:
```c
auto rv = h->on_key(util::from_ossl_level(ossl_level), read_secret, write_secret, secret_len);
```
Next, on_key will call `ngtcp2_crypto_derive_and_install_key`:
```c
std::array<uint8_t, 64> rx_key, rx_iv, rx_hp_key, tx_key, tx_iv, tx_hp_key;
...
if (ngtcp2_crypto_derive_and_install_key(
  	          conn_, ssl_, rx_key.data(), rx_iv.data(), rx_hp_key.data(),
  	          tx_key.data(), tx_iv.data(), tx_hp_key.data(), level, rx_secret,
  	          tx_secret, secretlen, NGTCP2_CRYPTO_SIDE_SERVER) != 0)
```
Notice that we have a rx_key (receive key), rx_iv, and rx_hp (header protection),
as well as tx_key (transmit key?), tx_iv, and tx_hp.
The rx_secret and tx_secret were extracted as mentioned above.
```c
ctx = ngtcp2_conn_get_crypto_ctx(conn);
```
Now, the connection, ngtcp2_conn contains a lot of information, it has the
registered callbacks, the connections ids, f
The above call will return a pointer, &conn->pktns.crypto.ctx, to a ngtcp2_crypto_ctx
struct, which will just contain empty members:
```console
(lldb) expr conn->pktns.crypto.ctx
(ngtcp2_crypto_ctx) $10 = {
  aead = (native_handle = 0x0000000000000000)
  md = (native_handle = 0x0000000000000000)
  hp = (native_handle = 0x0000000000000000)
}
```
These will then be populated.
```c
int ngtcp2_crypto_derive_packet_protection_key(
```

```c
int ngtcp2_crypto_hkdf_expand_label(uint8_t *dest, size_t destlen,
                                    const ngtcp2_crypto_md *md,
                                    const uint8_t *secret, size_t secretlen,
                                    const uint8_t *label, size_t labellen) {
  static const uint8_t LABEL[] = "tls13 ";
  uint8_t info[256];
  uint8_t *p = info;

  *p++ = (uint8_t)(destlen / 256);
  *p++ = (uint8_t)(destlen % 256);
  *p++ = (uint8_t)(sizeof(LABEL) - 1 + labellen);
  memcpy(p, LABEL, sizeof(LABEL) - 1);
  p += sizeof(LABEL) - 1;
  memcpy(p, label, labellen);
  p += labellen;
  *p++ = 0;

  return ngtcp2_crypto_hkdf_expand(dest, destlen, md, secret, secretlen, info,
                                   (size_t)(p - info));
}
```
Notice that the `info` variable is created here with a size of 256. So this is
just an array of bytes and p points to it.
`destlen` is 16

(lldb) expr p
(uint8_t *) $29 = 0x00007ffeefbeb411 "tls13 "
(lldb) expr p
(uint8_t *) $30 = 0x00007ffeefbeb417 "quic key"
(lldb) expr info
(uint8_t [256]) $31 = {
  [0] = '\x0e'
  [1] = 't'
  [2] = 'l'
  [3] = 's'
  [4] = '1'
  [5] = '3'
  [6] = ' '
  [7] = 'q'
  [8] = 'u'
  [9] = 'i'
  [10] = 'c'
  [11] = ' '
  [12] = 'k'
  [13] = 'e'
  [14] = 'y'
  [15] = '\0'

```c
int ngtcp2_crypto_derive_packet_protection_key(
    uint8_t *key, uint8_t *iv, uint8_t *hp_key, const ngtcp2_crypto_aead *aead,
    const ngtcp2_crypto_md *md, const uint8_t *secret, size_t secretlen) {
  static const uint8_t KEY_LABEL[] = "quic key";
  static const uint8_t IV_LABEL[] = "quic iv";
  static const uint8_t HP_KEY_LABEL[] = "quic hp";
  size_t keylen = ngtcp2_crypto_aead_keylen(aead);
  size_t ivlen = ngtcp2_crypto_packet_protection_ivlen(aead);

  if (ngtcp2_crypto_hkdf_expand_label(key, keylen, md, secret, secretlen,
                                      KEY_LABEL, sizeof(KEY_LABEL) - 1) != 0) {
    return -1;
  }

  if (ngtcp2_crypto_hkdf_expand_label(iv, ivlen, md, secret, secretlen,
                                      IV_LABEL, sizeof(IV_LABEL) - 1) != 0) {
    return -1;
  }

  if (hp_key != NULL && ngtcp2_crypto_hkdf_expand_label(
                            hp_key, keylen, md, secret, secretlen, HP_KEY_LABEL,
                            sizeof(HP_KEY_LABEL) - 1) != 0) {
    return -1;
  }

  return 0;
}
```
Notice that we are deriving 3 keys from the secret passed in. One is the `key`, 
one it the `iv`, and then we have the `hp_key`. 
And that is done for both the rx and tx

```c
int ngtcp2_crypto_derive_and_install_key(
    ngtcp2_conn *conn, void *tls, uint8_t *rx_key, uint8_t *rx_iv,
    uint8_t *rx_hp_key, uint8_t *tx_key, uint8_t *tx_iv, uint8_t *tx_hp_key,
    ngtcp2_crypto_level level, const uint8_t *rx_secret,
    const uint8_t *tx_secret, size_t secretlen, ngtcp2_crypto_side side) {
```
First we have:
```c
ngtcp2_crypto_derive_packet_protection_key(
           rx_key, rx_iv, rx_hp_key, aead, md, rx_secret, secretlen) != 0) {
```
and then:
```c
ngtcp2_crypto_derive_packet_protection_key(
           tx_key, tx_iv, tx_hp_key, aead, md, tx_secret, secretlen) != 0) {
```
After the secrets have been derived:
```
case NGTCP2_CRYPTO_LEVEL_HANDSHAKE:
     rv = ngtconn_install_handshake_key(conn, rx_key, rx_iv, rx_hp_key,
                                        tx_key, tx_iv, tx_hp_key, keylen,
                                        ivlen);
```



Initial packets are protected with a secret derived from the
Destination Connection ID field from the client's first Initial
packet of the connection.

initial_salt = 0x7fbcdb0e7c66bbe9193a96cd21519ebd7a02644a
initial_secret = HKDF-Extract(initial_salt, client_dst_connection_id)

client_initial_secret = HKDF-Expand-Label(initial_secret, "client in", "", Hash.length)
server_initial_secret = HKDF-Expand-Label(initial_secret, "server in", "", Hash.length)

The connection ID used with HKDF-Expand-Label is the Destination Connection ID in the 
Initial packet sent by the client.


### ngtcp2_rob
This is the re-order buffer which eassembles stream datareceived in out of order.


### session testing
Start the server:
```console
$ ./examples/server localhost 7777 examples/server.key examples/server.cert
```

Start the client with the transport parameters saved to a file:
```console
$ ./examples/client --tp-file=./tp_params localhost 7777
```
After this there will be file named `tb_params` with the following content:
```console
initial_max_streams_bidi=100
initial_max_streams_uni=3
initial_max_stream_data_bidi_local=262144
initial_max_stream_data_bidi_remote=262144
initial_max_stream_data_uni=262144
initial_max_data=1048576
```
Now, we cat start up the client again and specify that these values be used:
```console
$
```

### Client walk through
It is the  Client that generates the source connection id and the destination
connection id.
```c
  ngtcp2_cid scid, dcid;
  scid.datalen = 17;
  std::generate(std::begin(scid.data), std::begin(scid.data) + scid.datalen,
                [&dis]() { return dis(randgen); });
  if (config.dcid.datalen == 0) {
    dcid.datalen = 18;
    std::generate(std::begin(dcid.data), std::begin(dcid.data) + dcid.datalen,
                  [&dis]() { return dis(randgen); });
  } else {
    dcid = config.dcid;
  }
```
Noticet the check for `config.dcid.datalent`, this can be configured as an option
to the client `--dcid`.

```c
rv = ngtcp2_ringbuf_init(&(*pconn)->dcid.unused, NGTCP2_MAX_DCID_POOL_SIZE,
                         ngtcp2_dcid), mem);
```
Each connection will have a ringbuffer/circular buffer, which is a fixed size
buffer. This data structure is a good choice for buffering data streams as there
is not need to move/shift elements around. For first-in-first-out like we have
when we want to send data.

### Ring buffer
```
+---+----+----+----+----+----+----+
|   |    |    |    |    |    |    |
+---+----+----+----+----+----+----+
  ↑                             |
  |-----------------------------+

+---+----+----+----+----+----+----+
|   |    | 1  | 2  | 3  |    |    |
+---+----+----+----+----+----+----+
  ↑                             |
  |-----------------------------+
```
Remove two items:
```
+---+----+----+----+----+----+----+
|   |    |    |    | 3  |    |    |
+---+----+----+----+----+----+----+
  ↑                             |
  |-----------------------------+

```
Notice that the first two were removed and are now empty.

What if the buffer is full?
```
+---+----+----+----+----+----+----+
| 8 | 2  | 1  | 7  | 6  | 5  | 9  |
+---+----+----+----+----+----+----+
  ↑                             |
  |-----------------------------+
```
The implementation could overwrite the elements of raise an errro. 
What does ngtcp2 do?


### HTTP/3
When is nghttp3 used in the client?
```console
(lldb) br s -r 'nghttp3'
(lldb) r
* thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 3.374
  * frame #0: 0x0000000100738764 libnghttp3.0.dylib`nghttp3_conn_settings_default(settings=0x00007ffeefbebe60) at nghttp3_conn.c:3058:3 [opt]
    frame #1: 0x0000000100002810 client`Client::setup_httpconn(this=0x00007ffeefbfeb20) at client.cc:2004:3
    frame #2: 0x00000001000021ab client`Client::on_key(this=0x00007ffeefbfeb20, level=NGTCP2_CRYPTO_LEVEL_APP, rx_secret="{\x85��Ɍ�!�'%�&�9;I\x98\x9e�3\x80PDQ\x7f\b=��", tx_secret="��\x15ŵS=\x04�T��m�S�P\x9a\x158^,�]p4\x93l�N", secretlen=32) at client.cc:247:9
    frame #3: 0x00000001000168f5 client`(anonymous namespace)::set_encryption_secrets(ssl=0x0000000102004200, ossl_level=ssl_encryption_application, read_secret="{\x85��Ɍ�!�'%�&�9;I\x98\x9e�3\x80PDQ\x7f\b=��", write_secret="��\x15ŵS=\x04�T��m�S�P\x9a\x158^,�]p4\x93l�N", secret_len=32) at client.cc:2098:11
    frame #4: 0x0000000100202a1a libssl.3.dylib`quic_set_encryption_secrets(ssl=0x0000000102004200, level=ssl_encryption_application) at ssl_quic.c:251:14
    frame #5: 0x00000001002160c8 libssl.3.dylib`quic_change_cipher_state(s=0x0000000102004200, which=273) at tls13_enc.c:568:14
    frame #6: 0x0000000100214cfa libssl.3.dylib`tls13_change_cipher_state(s=0x0000000102004200, which=273) at tls13_enc.c:650:16
    frame #7: 0x0000000100248daa libssl.3.dylib`tls_process_finished(s=0x0000000102004200, pkt=0x00007ffeefbec870) at statem_lib.c:873:18
    frame #8: 0x000000010023c489 libssl.3.dylib`ossl_statem_client_process_message(s=0x0000000102004200, pkt=0x00007ffeefbec870) at statem_clnt.c:1064:16
    frame #9: 0x0000000100238931 libssl.3.dylib`read_state_machine(s=0x0000000102004200) at statem.c:641:19
    frame #10: 0x0000000100238085 libssl.3.dylib`state_machine(s=0x0000000102004200, server=0) at statem.c:435:21
    frame #11: 0x0000000100237be7 libssl.3.dylib`ossl_statem_connect(s=0x0000000102004200) at statem.c:251:12
    frame #12: 0x00000001001f829e libssl.3.dylib`SSL_do_handshake(s=0x0000000102004200) at ssl_lib.c:3776:19
    frame #13: 0x000000010002b478 client`ngtcp2_crypto_read_write_crypto_data(conn=0x0000000102000000, tls=0x0000000102004200, crypto_level=NGTCP2_CRYPTO_LEVEL_HANDSHAKE, data="xW\x7fuE\x83��c\bu\x11<!\x12;�V�K���a�L\\\x05\v\x95\x10\x81\x99`\\���\x12REEu�|z\x8d\x9b\x82\x02$Y\x02��'�%骤HVuG_\x1d;", datalen=388) at openssl.c:315:10
    frame #14: 0x0000000100007baf client`Client::recv_crypto_data(this=0x00007ffeefbfeb20, crypto_level=NGTCP2_CRYPTO_LEVEL_HANDSHAKE, data="xW\x7fuE\x83��c\bu\x11<!\x12;�V�K���a�L\\\x05\v\x95\x10\x81\x99`\\���\x12REEu�|z\x8d\x9b\x82\x02$Y\x02��'�%骤HVuG_\x1d;", datalen=388) at client.cc:1212:10
    frame #15: 0x0000000100004db5 client`(anonymous namespace)::recv_crypto_data(conn=0x0000000102000000, crypto_level=NGTCP2_CRYPTO_LEVEL_HANDSHAKE, offset=973, data="xW\x7fuE\x83��c\bu\x11<!\x12;�V�K���a�L\\\x05\v\x95\x10\x81\x99`\\���\x12REEu�|z\x8d\x9b\x82\x02$Y\x02��'�%骤HVuG_\x1d;", datalen=388, user_data=0x00007ffeefbfeb20) at client.cc:477:10
    frame #16: 0x0000000100044ed6 client`conn_call_recv_crypto_data(conn=0x0000000102000000, crypto_level=NGTCP2_CRYPTO_LEVEL_HANDSHAKE, offset=973, data="xW\x7fuE\x83��c\bu\x11<!\x12;�V�K���a�L\\\x05\v\x95\x10\x81\x99`\\���\x12REEu�|z\x8d\x9b\x82\x02$Y\x02��'�%骤HVuG_\x1d;", datalen=388) at ngtcp2_conn.c:109:8
    frame #17: 0x0000000100043109 client`conn_recv_crypto(conn=0x0000000102000000, crypto_level=NGTCP2_CRYPTO_LEVEL_HANDSHAKE, crypto=0x0000000102000598, fr=0x00007ffeefbecca8) at ngtcp2_conn.c:4813:10
    frame #18: 0x0000000100046c49 client`conn_recv_handshake_pkt(conn=0x0000000102000000, path=0x00007ffeefbee4e8, pkt="��, pktlen=454, ts=1571315241744230144) at ngtcp2_conn.c:4537:12
    frame #19: 0x0000000100036ac8 client`conn_recv_handshake_cpkt(conn=0x0000000102000000, path=0x00007ffeefbee4e8, pkt="��, pktlen=454, ts=1571315241744230144) at ngtcp2_conn.c:4610:13
    frame #20: 0x00000001000365d1 client`ngtcp2_conn_read_handshake(conn=0x0000000102000000, path=0x00007ffeefbee4e8, pkt="��, pktlen=454, ts=1571315241744230144) at ngtcp2_conn.c:6683:10
    frame #21: 0x00000001000363ef client`ngtcp2_conn_read_pkt(conn=0x0000000102000000, path=0x00007ffeefbee4e8, pkt="��, pktlen=454, ts=1571315241744230144) at ngtcp2_conn.c:6629:12
    frame #22: 0x00000001000062eb client`Client::feed_data(this=0x00007ffeefbfeb20, sa=0x00007ffeefbee658, salen=28, data="��, datalen=454) at client.cc:986:7
    frame #23: 0x000000010000671b client`Client::on_read(this=0x00007ffeefbfeb20) at client.cc:1029:9
    frame #24: 0x00000001000033f8 client`(anonymous namespace)::readcb(loop=0x0000000100723568, w=0x00007ffeefbfec68, revents=1) at client.cc:276:10
    frame #25: 0x000000010071e7aa libev.4.dylib`ev_invoke_pending + 93
    frame #26: 0x000000010071ec2d libev.4.dylib`ev_run + 1122
    frame #27: 0x000000010000c1fc client`(anonymous namespace)::run(c=0x00007ffeefbfeb20, addr="localhost", port="7777") at client.cc:2209:3
    frame #28: 0x000000010000b5c0 client`main(argc=4, argv=0x00007ffeefbfefd8) at client.cc:2617:7
    frame #29: 0x00007fff7638f3d5 libdyld.dylib`start + 1
    frame #30: 0x00007fff7638f3d5 libdyld.dylib`start + 1
```
So, we can see that Client::on_key will call `setup_httpconn`:
```c
if (setup_httpconn() != 0) {
      return -1;
    }
```

Much like ngtcp2 has callback so does nghttp3:
```c
nghttp3_conn_callbacks callbacks{
      ::http_acked_stream_data,
      nullptr, // stream_close
      ::http_recv_data,
      ::http_deferred_consume,
      ::http_begin_headers,
      ::http_recv_header,
      ::http_end_headers,
      ::http_begin_trailers,
      ::http_recv_trailer,
      ::http_end_trailers,
      ::http_begin_push_promise,
      ::http_recv_push_promise,
      ::http_end_push_promise,
      ::http_cancel_push,
      ::http_send_stop_sending,
      ::http_push_stream,
  };
```
And also various connection settings:
```c
  nghttp3_conn_settings settings;
  nghttp3_conn_settings_default(&settings);
  settings.qpack_max_table_capacity = 4096;
  settings.qpack_blocked_streams = 100;
  settings.max_pushes = 100;
```
We can see the qpack configuration. TODO: read up on qpack vs hpack.
If HPACK were used for HTTP/3 [HTTP3], it would induce head-of-line blocking
due to built-in assumptions of a total ordering across frames on all streams.
QPACK reuses core concepts from HPACK, but is redesigned to allow correctness
in the presence of out-of-order delivery, with flexibility for implementations
to balance between resilience against head-of-line blocking and optimal
compression ratio.

Recall that the idea here is that instead of sending headers over the wire 
with each request which was done with HTTP/1, instead both sides maintain a 
table with header names and values. 

QPACK uses two tables for associating header fields to indices.
1. A static table.
   This are all the know headers, like :path, :autority, :method, :status etc
2. A dynamic table which can be updated while the connection is alive.

Each HTTP/3 endpoint holds a dynamic table that is initially empty. Entries 
are added by encoder instructions received on the encoder stream.

An encoder sends encoder instructions on the encoder stream to set the capacity
of the dynamic table and add dynamic table entries. Instructions adding table
entries can use existing entries to avoid transmitting redundant information.
The name can be transmitted as a reference to an existing entry in the static
or the dynamic table or as a string literal.

```
  0   1   2   3   4   5   6   7
   +---+---+---+---+---+---+---+---+
   | 1 | T |    Name Index (6+)    |
   +---+---+-----------------------+
   | H |     Value Length (7+)     |
   +---+---------------------------+
   |  Value String (Length bytes)  |
   +-------------------------------+
```
An encoder adds an entry to the dynamic table where the header field name
matches the header field name of an entry stored in the static or the dynamic
table using an instruction that starts with the ‘1’ one-bit pattern. The second
(‘T’) bit indicates whether the reference is to the static or dynamic table.
The 6-bit prefix integer (see Section 4.1.1) that follows is used to locate the
table entry for the header name. When T=1, the number represents the static table
index; when T=0, the number is the relative index of the entry in the dynamic table.

QPACK defines unidirectional streams for sending instructions from encoder to
decoder and vice versa.

```c
  auto mem = nghttp3_mem_default();
  rv = nghttp3_conn_client_new(&httpconn_, &callbacks, &settings, mem, this);

```


QUIC connections are established as described in [QUIC-TRANSPORT].
During connection establishment, HTTP/3 support is indicated by
selecting the ALPN token "h3" in the TLS handshake.

While connection-level options pertaining to the core QUIC protocol
are set in the initial crypto handshake, HTTP/3-specific settings are
conveyed in the SETTINGS frame.  After the QUIC connection is
established, a SETTINGS frame (Section 7.2.4) MUST be sent by each
endpoint as the initial frame of their respective HTTP control stream


### priority queues
Where are these used? 
We can find them in `conn_new`:
```c
ngtcp2_pq_init(&(*pconn)->scid.used, ts_retired_less, mem);

```
So `ngtcp2_conn` has a number of structs as members in it, one is `scid`:
```c
  struct {
    /* used is a set of CID used by peer.  The sort function of this
       priority queue takes timestamp when CID is retired and sorts
       them in ascending order. */
    ngtcp2_pq used;
    ...
  } scid;
```
`ts_retired_less` is a comparator function that looks like this:
```c
static int ts_retired_less(const ngtcp2_pq_entry *lhs,
                           const ngtcp2_pq_entry *rhs) {
  const ngtcp2_scid *a = ngtcp2_struct_of(lhs, ngtcp2_scid, pe);
  const ngtcp2_scid *b = ngtcp2_struct_of(rhs, ngtcp2_scid, pe);

  return a->ts_retired < b->ts_retired;
}
```

An entry in the priority queue is just an index of type size_t, which is
a member of a struct named `ngtcp2_pq_entry`.
The `ngtcp2_pg` struct itself looks like this:
```c
typedef struct {
  /* The pointer to the pointer to the item stored */
  ngtcp2_pq_entry **q;
  const ngtcp2_mem *mem;
  /* The number of items stored */
  size_t length;
  /* The maximum number of items this pq can store. This is
     automatically extended when length is reached to this value. */
  size_t capacity;
  /* The less function between items */
  ngtcp2_less less;
} ngtcp2_pq;

```


### Streams
What is a stream really?  
It's a logical connection that is independent of other streams. So we 
have one udp connection between the client and the server. 

In HTTP/2 streams where handled by the HTTP layer, but in QUIC this is
handled by the QUIC protocol

In the client/server example the first stream is created when 

Recall that there are multiple levels of encryption in QUIC, there are
specific keys for the initial connection level, the handshake, app data,
and early data.
https://tools.ietf.org/html/draft-ietf-quic-tls-23#section-2.1
```
typedef enum ngtcp2_crypto_level {
  /**
   * NGTCP2_CRYPTO_LEVEL_INITIAL is Initial Keys encryption level.
   */
  NGTCP2_CRYPTO_LEVEL_INITIAL,
  /**
   * NGTCP2_CRYPTO_LEVEL_HANDSHAKE is Handshake Keys encryption level.
   */
  NGTCP2_CRYPTO_LEVEL_HANDSHAKE,
  /**
   * NGTCP2_CRYPTO_LEVEL_APP is Application Data (1-RTT) Keys
   * encryption level.
   */
  NGTCP2_CRYPTO_LEVEL_APP,
  /**
   * NGTCP2_CRYPTO_LEVEL_EARLY is Early Data (0-RTT) Keys encryption
   * level.
   */
  NGTCP2_CRYPTO_LEVEL_EARLY
} ngtcp2_crypto_level;
```
When client.cc `on_key` is called it is passed a level. This level is passed to `set_encryption_secrets` which is called by the OpenSSL library:
```console
(lldb) expr ossl_level
(OSSL_ENCRYPTION_LEVEL) $2 = ssl_encryption_handshake
```
This is converted into a ngtcp2_crypto_level before calling on_key:
```c
rv = c->on_key(util::from_ossl_level(ossl_level), read_secret, write_secret, secret_len);
```
We can see that we are also just passing through the pointer to read_secret and
write_secret from the OpenSSL layer. With this information we are going to call
ngtcp2_crypto_derive_and_install_key. So we are doing to extract and derive a
key for the handshake level. These keys are what protect packets in that layer.
```c
std::array<uint8_t, 64> rx_key, rx_iv, rx_hp_key;
std::array<uint8_t, 64> tx_key, tx_iv, tx_hp_key;
if (ngtcp2_crypto_derive_and_install_key(
          conn_, ssl_, rx_key.data(), rx_iv.data(), rx_hp_key.data(),
          tx_key.data(), tx_iv.data(), tx_hp_key.data(), level, rx_secret,
          tx_secret, secretlen, NGTCP2_CRYPTO_SIDE_CLIENT) != 0) {
    return -1;
  }
```
Notice that most of the arguments are values that will be filled in by this 
function call:
rx_key       package protection key for decryption
rx_iv        package protection iv for decryption
rx_hp_key    derived header protection key for decryption

I think 'r` in this case stands for recive.

tx_key       package protection key for encryption
tx_iv        package protection iv for encryption
tx_hp_key    derived header protection key for encryption

I think 't` in this case stands for transmit.

Each ngtcp2_conn instance has a ngtcp2_crypto_ctx:
```c
typedef struct ngtcp2_crypto_ctx {
  ngtcp2_crypto_aead aead;
  ngtcp2_crypto_md md;
  ngtcp2_crypto_cipher hp;
} ngtcp2_crypto_ctx;
```

So for each level we will extract the `quic key`, `quic iv`, and `quic hp`.
Headers are protected using a key that is derived separately to the packet 
protection key and IV.

Packets with long headers are Initial, 0-RTT, Handshake, and Retry.
Packets with short headers are intended for minimal overhead and are used after
a connection is established and when 1-RTT keys are available.
```
   0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
   +-+-+-+-+-+-+-+-+
   |1|1|T T|X X X X|
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                         Version (32)                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | DCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |               Destination Connection ID (0..160)            ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   | SCID Len (8)  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                 Source Connection ID (0..160)               ...
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```



### ngtcp2_path
This is a network path that contains the local and the remote endpoint addresses.

### ngtcp2_conn
Each connection has a ringbuffer with unused destination connection ids.

There is also member struct named scid
```c
  struct {
    /* set is a set of CID sent to peer.  The peer can use any CIDs in
       this set.  This includes used CID as well as unused ones. */
    ngtcp2_ksl set;
    /* used is a set of CID used by peer.  The sort function of this
       priority queue takes timestamp when CID is retired and sorts
       them in ascending order. */
    ngtcp2_pq used;
    /* last_seq is the last sequence number of connection ID. */
    uint64_t last_seq;
    /* num_initial_id is the number of Connection ID initially offered
       to the remote endpoint and is not retired yet.  It includes the
       initial Connection ID used during handshake and the one in
       preferred_address transport parameter. */
    size_t num_initial_id;
    /* num_retired is the number of retired Connection ID still
       included in set. */
    size_t num_retired;
  } scid;
```
This struct is initialized `conn_new`

```c
rv = ngtcp2_map_init(&(*pconn)->strms, mem);
```
`strms` is of type `ngtcp2_map`.


`ngtcp2_default_cc_init` is the congestion controller (cc).


```c
  rv = pktns_init(&(*pconn)->in_pktns, NGTCP2_CRYPTO_LEVEL_INITIAL,
                  &(*pconn)->cc, &(*pconn)->log, &(*pconn)->qlog, mem);
```
The ngtcp2_conn struct has the following members of type ngtcp2_pktns:
```c
  ngtcp2_pktns in_pktns;
  ngtcp2_pktns hs_pktns;
  ngtcp2_pktns pktns;
```
Notice that `pktns_init` is not function in ngtcp2_conn:
```c
static int pktns_init(ngtcp2_pktns *pktns,
                      ngtcp2_crypto_level crypto_level,
                      ngtcp2_default_cc *cc,
                      ngtcp2_log *log,
                      ngtcp2_qlog *qlog,
                      const ngtcp2_mem *mem) 
```
ngtcp2_pktns is a struct defined in lib/ngtcp_conn.c.

### ngtcp2_idtr
This stands for `id tracker` of stream ids (I think).
```c
typedef struct {
  /* gap maintains the range of ID which is not used yet. Initially,
     its range is [0, UINT64_MAX). */
  ngtcp2_gaptr gap;
  /* server is nonzero if this object records server initiated stream
     ID. */
  int server;
} ngtcp2_idtr;
````
And we can find `ngtcp2_gaptr` in ngtcp_gaptr.h:
```c
typedef struct {
  /* gap maintains the range of offset which is not received
     yet. Initially, its range is [0, UINT64_MAX). */
  ngtcp2_ksl gap;
  /* mem is custom memory allocator */
  const ngtcp2_mem *mem;
} ngtcp2_gaptr;
```


### Acks
And endpoint acknowledges all packets it recieves and process for packets that
require acking that is (ack-elicting packets).

The ACK frame contains one or more ACK Ranges. ACK Ranges identify acknowledged packets.


### Explicit Congestion Notification (ECN)
Classic TCP drives the network into congestion and then recovers, it actually
needs to see packet loss and then slow down and recover.
The idea with ECN is to avoid congestion which can be done by setting a bit in
the IP header related to ECN. This can then be an inspected by the receiver who
can inform the sender of this situation and it can adjust to that. For TCP this
would probably just do what it would normally do when there is packet loss. What
this means for QUIC is not completely clear to me yet.
Endpoints react to congestion by reducing their sending rate in response

To use ECN, QUIC endpoints first determine whether a path supports
ECN marking and the peer is able to access the ECN codepoint in the
IP header.  A network path does not support ECN if ECN marked packets
get dropped or ECN markings are rewritten on the path.  An endpoint
validates the use of ECN on the path, both during connection
establishment and when migrating to a new path



This is what an ACK frame looks line when using Wireshark:
```
Frame 7: 93 bytes on wire (744 bits), 93 bytes captured (744 bits) on interface lo0, id 0
Null/Loopback
Internet Protocol Version 6, Src: ::1, Dst: ::1
User Datagram Protocol, Src Port: 7777, Dst Port: 53160
QUIC IETF
    QUIC Connection information
        [Connection Number: 0]
    [Packet Length: 41]
    QUIC Short Header DCID=61ac5a112d1731c9d35a03ea687ac82eb4 PKN=2
        0... .... = Header Form: Short Header (0)
        .1.. .... = Fixed Bit: True
        ..0. .... = Spin Bit: False
        ...0 0... = Reserved: 0
        .... .0.. = Key Phase Bit: False
        .... ..00 = Packet Number Length: 1 bytes (0)
        Destination Connection ID: 61ac5a112d1731c9d35a03ea687ac82eb4
        Packet Number: 2
        Protected Payload: cfe10e33cd2398b5aa6ded932f6426e65be633fa3724
    ACK
        Frame Type: ACK (0x02)
        Largest Acknowledged: 0
        ACK Delay: 246
        ACK Range Count: 0
        First ACK Range: 0
```




### Connection IDs
So, when a connection is first initiated, the client will generate a source 
connection id and send this in the initial long packet header
Additional connection IDs are communicated to the peer using NEW_CONNECTION_ID
frames. We can see these in wireshark. This is what the ngtcp2_conn unused
ringbuffer holds. 
Endpoints store received connection IDs for future use and advertise the number
of connection IDs they are willing to store with the active_connection_id_limit
transport parameter.

An endpoint sends a NEW_CONNECTION_ID frame (type=0x18) to provide
its peer with alternative connection IDs that can be used to break
linkability when migrating connections. So when a connection migration takes
place and we are sending from a different local address, then one of the unused
connection ids are used. This is to prevent any correlating of the connection id.


retired connection IDs are sent in RETIRE_CONNECTION_ID frames and retransmitted
if the packet containing them is lost. Sending a RETIRE_CONNECTION_ID frame also
serves as a request to the peer to send additional connection IDs for future use


### PATH_CHALLENGE
Endpoints can use PATH_CHALLENGE frames (type=0x1a) to check
reachability to the peer and for path validation during connection migration.
The receiver of a PATH_CHALLENGE frame must reply by sending PATH_RESPONSE with
the same data from the PATH_CHANNENGE frame.
```c
typedef struct {
  uint8_t data[8];
} ngtcp2_path_challenge_entry;
```

### Probe Timeout (PTO)



### ngtcp2_gaptr 
This is a struct that contains a skip list and a memory allocator.
I'm still a little confused by the name gap but perhaps this is a common networking
term that I'm just not used to.
```c
typedef struct {
  /* gap maintains the range of offset which is not received
     yet. Initially, its range is [0, UINT64_MAX). */
  ngtcp2_ksl gap;
  /* mem is custom memory allocator */
  const ngtcp2_mem *mem;
} ngtcp2_gaptr;
```
```c
  ngtcp2_range range = {0, UINT64_MAX};
  ngtcp2_ksl_key key;

  rv = ngtcp2_ksl_init(&gaptr->gap, ngtcp2_ksl_range_compar,
                       sizeof(ngtcp2_range), mem);
```
So here we can see that a gap being initialized. The range is a struct as well:
```c
/*
 * ngtcp2_range represents half-closed range [begin, end).
 */
typedef struct {
  uint64_t begin;
  uint64_t end;
} ngtcp2_range;

```

### Reorder buffer (rob)
ngtcp2_rob is the reorder buffer which reassembles stream data received in out
of order.


### OpenSSL layer

When we see the following function call:
```c
SSL_set_tlsext_host_name(ssl_, addr_);
```
you have to keep in mind that this is a macro.
```c
# define SSL_set_tlsext_host_name(s,name) \
    SSL_ctrl(s, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, (void *)name)
```
we can find `SSL_ctrl` in ssl/ssl_lib.c:
```c
long SSL_ctrl(SSL *s, int cmd, long larg, void *parg)
```


I'm interested in learning about the interaction between OpenSSL and QUIC.

-> 3813	    s->handshake_func = s->method->ssl_connect;
   3814	    clear_ciphers(s);
   3815	}
   3816
Target 0: (client) stopped.
(lldb) expr s->method->ssl_connect
(int (*const)(SSL *)) $17 = 0x000000010023ebd0 (libssl.3.dylib`ossl_statem_connect at statem.c:250)


`Client::init` and the call `init_ssl`::
```c
  if (init_ssl() != 0) {
    return -1;
  }

  rv = setup_initial_crypto_context();
  if (rv != 0) {
    return -1;
  }
```

auto nwrite = ngtcp2_encode_transport_params(
   buf.data(), buf.size(), NGTCP2_TRANSPORT_PARAMS_TYPE_CLIENT_HELLO,
   &params);
if (SSL_set_quic_transport_params(ssl_, buf.data(), nwrite) != 1)
```
In `ssl_quic.c` we have
```c
ssl->ext.quic_transport_params = tmp;
ssl->ext.quic_transport_params_len = params_len;
```

Client::setup_initial_crypto_context:
```c
int Client::setup_initial_crypto_context() {
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_SECRETLEN> initial_secret, rx_secret, tx_secret;
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_KEYLEN> rx_key, rx_hp_key, tx_key, tx_hp_key;
  std::array<uint8_t, NGTCP2_CRYPTO_INITIAL_IVLEN> rx_iv, tx_iv;
```
After having created those arrays, we are going to call:
```c
auto dcid = ngtcp2_conn_get_dcid(conn_);
```
Recall that we have already created the ngtcp2_conn which is what `conn_` is
and instance of. So we are just getting the `conn->dcid.current.cid`.

Next we are going to derive and install the initial key:
```c
  if (ngtcp2_crypto_derive_and_install_initial_key(
          conn_, 
          rx_secret.data(), 
          tx_secret.data(), 
          initial_secret.data(),
          rx_key.data(), 
          rx_iv.data(), 
          rx_hp_key.data(), 
          tx_key.data(),
          tx_iv.data(), 
          tx_hp_key.data(), 
          dcid,
          NGTCP2_CRYPTO_SIDE_CLIENT) != 0) {
```
`dcid` in this case is `client_dcid` in the below calls. This was extracted
from `&conn->dcid.current.cid`

This function will create a new ngtcp2_crypto_ctx instance.
```c
  ngtcp2_crypto_ctx ctx;
  ngtcp2_crypto_ctx_initial(&ctx);
```
If we look at `ngtcp2_crypto_ctx_initial` we find:
```c
ngtcp2_crypto_ctx *ngtcp2_crypto_ctx_initial(ngtcp2_crypto_ctx *ctx) {
  ctx->aead.native_handle = (void *)EVP_aes_128_gcm();
  ctx->md.native_handle = (void *)EVP_sha256();
  ctx->hp.native_handle = (void *)EVP_aes_128_ctr();
  return ctx;
}
```
EVP_aes_128_gcm is AES Galios Counter Mode (GCM) for 128 bit keys.
This crypto context is then set on the connection:
```c
conn->in_pktns.crypto.ctx = *ctx;
```
Notice that this is setting `in_pktns`. Does this stand for initial packet name
space?  
First, we are going to derive the inital secrets:
```c
ngtcp2_crypto_derive_initial_secrets(rx_secret, tx_secret, initial_secret, client_dcid, side)
```
A new crypto_context will be created for this operation:
```c
  ngtcp2_crypto_ctx_initial(&ctx);

  if (ngtcp2_crypto_hkdf_extract(initial_secret,
                                 NGTCP2_CRYPTO_INITIAL_SECRETLEN, &ctx.md,
                                 client_dcid->data, client_dcid->datalen,
                                 (const uint8_t *)NGTCP2_INITIAL_SALT,
                                 sizeof(NGTCP2_INITIAL_SALT) - 1) != 0) {
```
So we are using the client_dcid, from `conn->dcid.current.cid` to derive a key
from that data and it will be in `intial_secret` after returning from this function.
This will be the secret and secretlen in the called function.

(lldb) memory read -f x secret -c 1 -s 18
0x10186fe00: 0xbe105149f711d5f858904182574691d3374d

(lldb) memory read -f x salt -c 1 -s 20
0x10006cd56: 0x02f5f9be6563b42b43d2a7115abb2ec712f7eec3

(lldb) memory read -f x dest -c 1 -s 32
0x7ffeefbfe318: 0xc463a395ab9c43f46635f4d05e450fa278b86b7b93ebfe052a74924671fd787c

From this secret we will expand it into to more keys, client_secret and 
server_secret.

There will then be keys expanded for transmission and reception:
rx_key
rx_iv
rx_hp_key
tx_key
tx_iv
tx_hp_key


These keys will be installed by calling `ngtcp2_conn_install_initial_key`
```c
rv = ngtcp2_conn_install_initial_key(conn,
                                     rx_key, rx_iv, rx_hp_key,
                                     tx_key, tx_iv, tx_hp_key,
                                     NGTCP2_CRYPTO_INITIAL_KEYLEN,
                                     NGTCP2_CRYPTO_INITIAL_IVLEN);
```
```c
rv = ngtcp2_crypto_km_new(&pktns->crypto.rx.ckm, rx_key, keylen, rx_iv, ivlen,
                          conn->mem);
```
I think this is the first time I've encountered ngtcp2_crypto_km (keying material):
```c
typedef struct {
  ngtcp2_vec key;
  ngtcp2_vec iv;
  /* pkt_num is a packet number of a packet which uses this keying
     material.  For encryption key, it is the lowest packet number of
     a packet.  For decryption key, it is the lowest packet number of
     a packet which can be decrypted with this keying material. */
  int64_t pkt_num;
  /* flags is the bitwise OR of zero or more of
     ngtcp2_crypto_km_flag. */
  uint8_t flags;
} ngtcp2_crypto_km;
```

That will set the receive key material.
```c
  rv = ngtcp2_vec_new(&pktns->crypto.rx.hp_key, rx_hp_key, keylen, conn->mem);
  rv = ngtcp2_crypto_km_new(&pktns->crypto.tx.ckm, tx_key, keylen, tx_iv, ivlen, conn->mem);
```

That takes care of `setup_initial_crypto_context` and we will return back to
client.cc.

After this we have the following libev function calls:
```c
  ev_io_set(&wev_, fd_, EV_WRITE);
  ev_io_set(&rev_, fd_, EV_READ);

  ev_io_start(loop_, &rev_);
  ev_timer_again(loop_, &timer_);

  ev_signal_start(loop_, &sigintev_);
```
In the constructor of Client we had:
```c
  ev_io_init(&wev_, writecb, 0, EV_WRITE);
  ev_io_init(&rev_, readcb, 0, EV_READ);
```
And a client had the following fields related to libev:
```c
  ev_io wev_;
  ev_io rev_;
  ev_timer timer_;
  ev_timer rttimer_;
  ev_timer change_local_addr_timer_;
  ev_timer key_update_timer_;
  ev_timer delay_stream_timer_;
  ev_signal sigintev_;
  struct ev_loop *loop_;
```
We have an io watcher for write events, `wev_` and one for read events, `rev_`.
Notice that the read worker is started.



### Round trip time
Each endpoint measures the time from a packet is set until it was acknowledges
as the round-trip time (RTT).
The endpoint then computes three values:
1) min_rtt
The minimal (shortest round-trip time

2) smoothed_rtt

3) rttvar
variance in the observed samples.

This information is stored in the `ngtcp2_rcvry_stat` struct:
```c
typedef struct ngtcp2_rcvry_stat {
  ngtcp2_duration latest_rtt;
  ngtcp2_duration min_rtt;
  double smoothed_rtt;
  double rttvar;
  // 
  size_t pto_count;
  /* probe_pkt_left is the number of probe packet to sent */
  size_t probe_pkt_left;
  ngtcp2_tstamp loss_detection_timer;
  /* last_tx_pkt_ts corresponds to
     time_of_last_sent_ack_eliciting_packet in
     draft-ietf-quic-recovery-23. */
  ngtcp2_tstamp last_tx_pkt_ts;
} ngtcp2_rcvry_stat;
```

### HTTP/3
In order to do HTTP over QUIC, changes were required and the results of this is
what we now call HTTP/3. These changes were required because of the different
nature that QUIC provides as opposed to TCP. These changes include:

* In QUIC the streams are provided by the transport itself, while in HTTP/2
  the streams were done within the HTTP layer.

* 8 Due to the streams being independent of each other, the header compression
  protocol used for HTTP/2 could not be used without it causing a head of block situation.

* QUIC streams are slightly different than HTTP/2 streams.


The client sends its HTTP request on a client-initiated bidirectional QUIC stream.
A request consists of a single HEADERS frame and might optionally be followed
by one or two other frames: a series of DATA frames and possibly a final HEADERS
frame for trailers. After sending a request, a client closes the stream for sending.

The server sends back its HTTP response on the bidirectional stream. A HEADERS
frame, a series of DATA frames and possibly a trailing HEADERS frame.
The HEADERS frames contain HTTP headers compressed using the QPACK algorithm.
QPACK itself uses two additional unidirectional QUIC streams between the two
end-points. They are used to carry dynamic table information in either direction.


For testing/debugging build with debug symbols enabled and static so that there
is a single executable that can be run (not a libtool wrapper script):

### Building ngtcp2 with debugging symbols

First, clone the OpenSSL fork:
```console
$ git clone --depth 1 -b quic-draft-15 https://github.com/tatsuhiro-t/openssl
$ ./config enable-tls1_3 --prefix=$PWD/build
$ make -j8
$ make install_sw
```
Next, clone nghttp3, configure and build:
```console
$ git clone https://github.com/ngtcp2/nghttp3
$ cd nghttp3
$ autoreconf -i
$ ./configure --prefix=$PWD/build --enable-lib-only
$ make -j8 check
$ make install
```
Now clone ngtcp2 and configure and build::
```console
$ autoreconf -i
$ ./configure PKG_CONFIG_PATH=$PWD/../openssl/build/lib/pkgconfig LDFLAGS="-Wl,-rpath,$PWD/../openssl/build/lib" --enable-debug --disable-shared
```
To enable debugging:
```console
$ ./configure PKG_CONFIG_PATH=$PWD/../openssl/build/lib/pkgconfig:$PWD/../nghttp3/build/lib/pkgconfig LDFLAGS="-O0 -Wl,-rpath,$PWD/../openssl/build/lib" --enable-debug --disable-shared CFLAGS="-O0" CXXFLAGS="-O0"
$ make -j8 check
```
The above will build as a static library which made debbugging a little easier.
 
DNS-Based Authentication of Named Entities (DANE)
