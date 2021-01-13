### Debugging Node.js applications/tests

#### Breakpoints in child process tests
This section shows one way of setting breakpoints in tests that use child
processes. The problem that one can run into when debugging these are that a
test is started using lldb like this:
```
$ lldb -- out/Debug/node /home/danielbevenius/work/nodejs/openssl/test/parallel/test-crypto-secure-heap.js
```
And then a break point is set in a C++ function of interest, for example:
```console
(lldb) br s -r DiffieHellman::*
(lldb) r
```
The breakpoint is never hit which can be somewhat suprising because you know
that one of the functions will be called and you can see output to the console.

The problem is that when the test is run it will spawn a new process and it is
that process that we really are interested in setting the breakpoint in.

What can be done is instead start debugging the javascript application and then
when the child process has been created attach to it and then set our breakpoint:

In this case a break point will be added in the child process code:
```js
if (process.argv[2] === 'child') {

  const a = secureHeapUsed();

  assert(a);
  assert.strictEqual(typeof a, 'object');
  assert.strictEqual(a.total, 65536);
  assert.strictEqual(a.min, 4);
  assert.strictEqual(a.used, 0);

  {
    const dh1 = createDiffieHellman(common.hasFipsCrypto ? 1024 : 256);
```
The last line above will have a breakpoint set on it and we can add
`--inspect-brk` to the fork function call argument:
```javascript

  const child = fork(                                                                
    process.argv[1],                                                                 
    ['child'],                                                                       
    { execArgv: ['--secure-heap=65536', '--secure-heap-min=4', '--inspect-brk'] });
```
We start the test just like we normally would:
```console
$ out/Debug/node /home/danielbevenius/work/nodejs/openssl/test/parallel/test-crypto-secure-heap.js
Debugger listening on ws://127.0.0.1:9229/2bc45af4-47cf-4b9e-8095-a5e2bfaec1c0
For help, see: https://nodejs.org/en/docs/inspector
Debugger attached.
```
Notice that the debugger is waiting to be connected to. We do this by opening
chrome and entering `chrome://inspect`. Now we can contine until we hit the
breakpoint we set.

Next we attach to this process by first finding the process id:
```console
$ ps ef | grep inspect-brk
```
Then we start lldb and attach to the process:
```console
$ lldb -- out/Debug/node
(lldb) process attach --pid 1275062
(lldb) br s -n DiffieHellman::New
Breakpoint 1: where = node`node::crypto::DiffieHellman::New(v8::FunctionCallbackInfo<v8::Value> const&) + 23 at crypto_dh.cc:201:45, address = 0x00000000012189bd
```
And now we can step through in the chrome devtools debugger and our breakpoint
will be triggered:
```console
Process 1275062 stopped
* thread #1, name = 'node', stop reason = breakpoint 1.1
    frame #0: 0x00000000012189bd node`node::crypto::DiffieHellman::New(args=0x00007fff25e4e210) at crypto_dh.cc:201:45
   189 	  if (group == nullptr)
   190 	    return THROW_ERR_CRYPTO_UNKNOWN_DH_GROUP(env);
   191 	
   192 	  initialized = diffieHellman->Init(group->prime,
   193 	                                    group->prime_size,
   194 	                                    group->gen);
   195 	  if (!initialized)
   196 	    THROW_ERR_CRYPTO_INITIALIZATION_FAILED(env);
   197 	}
   198 	
   199 	
   200 	void DiffieHellman::New(const FunctionCallbackInfo<Value>& args) {
-> 201 	  Environment* env = Environment::GetCurrent(args);
   202 	  DiffieHellman* diffieHellman =
```

