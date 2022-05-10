## node-gyp OpenSSL include issue

Issue description: https://github.com/nodejs/node/issues/40575

### Building
```console
$ node-gyp configure
$ node-gyp build
```

### Error
This is the error when running `node-gyp build` (with the addition of some
debugging of the macros involved to help troubleshoot this):
```console
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:83:9: note: ‘#pragma message: OPENSSL_API_COMPAT: 30000’
   83 | #pragma message "OPENSSL_API_COMPAT: " OPENSSL_MSTR(OPENSSL_API_COMPAT)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:141:9: note: ‘#pragma message: OPENSSL_VERSION_MAJOR: 3’
  141 | #pragma message "OPENSSL_VERSION_MAJOR: " OPENSSL_MSTR(OPENSSL_VERSION_MAJOR)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:142:9: note: ‘#pragma message: OPENSSL_VERSION_MINOR: 0’
  142 | #pragma message "OPENSSL_VERSION_MINOR: " OPENSSL_MSTR(OPENSSL_VERSION_MINOR)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:143:9: note: ‘#pragma message: OPENSSL_VERSION: (3 * 1000 + OPENSSL_MINOR * 100)’
  143 | #pragma message "OPENSSL_VERSION: " OPENSSL_MSTR((OPENSSL_VERSION_MAJOR * 1000 + OPENSSL_MINOR * 100))
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:144:9: note: ‘#pragma message: OPENSSL_API_LEVEL: (30000)’
  144 | #pragma message "OPENSSL_API_LEVEL: " OPENSSL_MSTR(OPENSSL_API_LEVEL)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:145:9: note: ‘#pragma message: OPENSSL_API_COMPAT: 30000’
  145 | #pragma message "OPENSSL_API_COMPAT: " OPENSSL_MSTR(OPENSSL_API_COMPAT)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:146:9: note: ‘#pragma message: OPENSSL_CONFIGURED_API: OPENSSL_CONFIGURED_API’
  146 | #pragma message "OPENSSL_CONFIGURED_API: " OPENSSL_MSTR(OPENSSL_CONFIGURED_API)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:148:4: error: #error "The requested API level higher than the configured API compatibility level"
  148 | #  error "The requested API level higher than the configured API compatibility level"
      |    ^~~~~
make: *** [example.target.mk:113: Release/obj.target/example/example.o] Error 1
```
Notice that `OPENSSL_CONFIGURED_API` has not been set which is the causs of
the error message above.

Now macros.c has the following include:
```c
#include <openssl/opensslconf.h>                                                
#include <openssl/opensslv.h>
```
In Node.js this is a "redirect" openssl header which choose different headers8
depending of whether ASM of NO_ASM was configured:
```c
#if defined(OPENSSL_NO_ASM)                                                        
# include "./opensslconf_no-asm.h"                                                 
#else                                                                              
# include "./opensslconf_asm.h"                                                    
#endif
```
And if we assume this using ASM this would end up in:
```c
#elif defined(OPENSSL_LINUX) && defined(__x86_64__)                                
# include "./archs/linux-x86_64/asm/include/openssl/opensslconf.h
```
And this file does not include configuration.h.

In OpenSSL the following headers are generated:
```console
$ find . -name '*.in'
./include/openssl/conf.h.in
./include/openssl/lhash.h.in
./include/openssl/crmf.h.in
./include/openssl/err.h.in
./include/openssl/safestack.h.in
./include/openssl/ess.h.in
./include/openssl/opensslv.h.in
./include/openssl/ocsp.h.in
./include/openssl/pkcs12.h.in
./include/openssl/asn1.h.in
./include/openssl/bio.h.in
./include/openssl/x509.h.in
./include/openssl/x509v3.h.in
./include/openssl/cmp.h.in
./include/openssl/pkcs7.h.in
./include/openssl/srp.h.in
./include/openssl/x509_vfy.h.in
./include/openssl/asn1t.h.in
./include/openssl/ct.h.in
./include/openssl/fipskey.h.in
./include/openssl/ui.h.in
./include/openssl/configuration.h.in
./include/openssl/crypto.h.in
./include/openssl/cms.h.in
./include/openssl/ssl.h.in
./include/crypto/bn_conf.h.in
./include/crypto/dso_conf.h.in
```
And notice that opensslconf.h is not among these.
What I think is happening is that we have an old opensslconf.h which may
have been generated with past versions but is not generated any more, instead
`configuration.h` is the file being generated.

If we replace this header, 
`/.cache/node-gyp/17.8.0/include/node/openssl/opensslconf.h`, with the header
from OpenSSL 3.0:
```console
$ cp opensslconf.h /home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/opensslconf.h
```
And the run the build again:
```console
$ node-gyp build
gyp info it worked if it ends with ok
gyp info using node-gyp@9.0.0
gyp info using node@17.8.0 | linux | x64
gyp info spawn make
gyp info spawn args [ 'BUILDTYPE=Release', '-C', 'build' ]
make: Entering directory '/home/danielbevenius/work/nodejs/node-gyp-openssl-issue/build'
  CC(target) Release/obj.target/example/example.o
In file included from /home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/././archs/linux-x86_64/asm/include/openssl/ssl.h:21,
                 from /home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/./ssl_asm.h:11,
                 from /home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/ssl.h:4,
                 from ../example.c:1:
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:83:9: note: ‘#pragma message: OPENSSL_API_COMPAT: 30000’
   83 | #pragma message "OPENSSL_API_COMPAT: " OPENSSL_MSTR(OPENSSL_API_COMPAT)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:141:9: note: ‘#pragma message: OPENSSL_VERSION_MAJOR: 3’
  141 | #pragma message "OPENSSL_VERSION_MAJOR: " OPENSSL_MSTR(OPENSSL_VERSION_MAJOR)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:142:9: note: ‘#pragma message: OPENSSL_VERSION_MINOR: 0’
  142 | #pragma message "OPENSSL_VERSION_MINOR: " OPENSSL_MSTR(OPENSSL_VERSION_MINOR)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:143:9: note: ‘#pragma message: OPENSSL_API_LEVEL: (30000)’
  143 | #pragma message "OPENSSL_API_LEVEL: " OPENSSL_MSTR(OPENSSL_API_LEVEL)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:144:9: note: ‘#pragma message: OPENSSL_API_COMPAT: 30000’
  144 | #pragma message "OPENSSL_API_COMPAT: " OPENSSL_MSTR(OPENSSL_API_COMPAT)
      |         ^~~~~~~
/home/danielbevenius/.cache/node-gyp/17.8.0/include/node/openssl/macros.h:145:9: note: ‘#pragma message: OPENSSL_CONFIGURED_API: 30000’
  145 | #pragma message "OPENSSL_CONFIGURED_API: " OPENSSL_MSTR(OPENSSL_CONFIGURED_API)
      |         ^~~~~~~
  SOLINK_MODULE(target) Release/obj.target/example.node
  COPY Release/example.node
make: Leaving directory '/home/danielbevenius/work/nodejs/node-gyp-openssl-issue/build'
gyp info ok 
```

### Solution
So we should remove this template from Node.js:
```console
$ git st .
On branch opensslconf
Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
	deleted:    deps/openssl/config/opensslconf.h
	deleted:    deps/openssl/config/opensslconf.h.tmpl
	deleted:    deps/openssl/config/opensslconf_no-asm.h
```

After this change we need to regenerate the headers:
```console
$ cd deps/openssl/config
$ make 
$ cd -
```
Next we can create the tar-headers file (by makeing some updates to the Makefile
to allow this to be built for a non-release):
```
$ make node-v19.0.0.tar-headers 
```
First we can revert the headers:
```console
$ node-gyp remove v17.8.0
```
And running node-gyp rebuild should fail with the above error message.

And then unzip the new headers to replace the headers used by node-gyp:
```console
$ tar xvzf node-v17.9.1-headers.tar.gz -C ~/.cache/node-gyp/17.8.0 --strip 1
```
And this running node-gyp should succeed:
```console
$ node-gyp build
gyp info it worked if it ends with ok
gyp info using node-gyp@9.0.0
gyp info using node@17.8.0 | linux | x64
gyp info spawn make
gyp info spawn args [ 'BUILDTYPE=Release', '-C', 'build' ]
make: Entering directory '/home/danielbevenius/work/nodejs/learning-nodejs/node-gyp-openssl-issue/build'
make: Nothing to be done for 'all'.
make: Leaving directory '/home/danielbevenius/work/nodejs/learning-nodejs/node-gyp-openssl-issue/build'
```

There are addons in Node.js that include openssl/ssl.h but this error does not
happen for those and I've not had time to find out why this is the case.

### OPENSSL_API_COMPAT
This macro specifies what is exposed to be exposed by openssl headers.
So if we want to only include stuff (functions, constants, macros) from 
3.0 then we would use:
```python
      "defines": [ "OPENSSL_API_COMPAT=30000"]
```

But if we only want older stuff to be exposed, for example also 1.1.1 we could
use: (1 * 1000 + 1 * 100 + 1 = 11001
```python
      "defines": [ "OPENSSL_API_COMPAT=11001"]
```

```console
$ node-gyp build
```

### Debug macros
To see the actual values of macros we can add the following pre-processor
statements, for example to
`/.cache/node-gyp/17.8.0/include/node/openssl/macros.h`:
```c
#pragma message "OPENSSL_API_COMPAT: " OPENSSL_MSTR(OPENSSL_API_COMPAT) 
