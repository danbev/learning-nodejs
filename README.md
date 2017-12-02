### Learning Node.js
The sole purpose of this project is to aid in learning Node.js internals.

## Prerequisites
You'll need to have checked out the node.js source.

### Compiling Node.js with debug enbled:

    $ ./configure --debug
    $ make -C out BUILDTYPE=Debug

After compiling (with debugging enabled) start node using lldb:

    $ cd node/out/Debug
    $ lldb ./node

Node uses Generate Your Projects (gyp) for which I was not familare with so there is a 
example project in [gyp](./gyp) to look into it.

### Running the Node.js tests

    $ make -j8 test

## Notes
The rest of this page contains notes gathred while setting through the code base:
(These are more sections than listed here but they might be hard to follow)

1. [Background](#background)
2. [Start up](#starting-node)
3. [Loading of builtins](#loading-of-builtins)
4. [Environment](#environment)
5. [TCPWrap](#tcpwrapinitialize)
6. [Running a script](#running-a-script)
7. [Event loop](#event-loop)
8. [setTimeout](#settimeout)
9. [setImmediate](#setimmediate)
10. [nextTick](#process._nexttick)
11. [AsyncWrap](#asyncwrap)
12. [lldb](#lldb)
13. [Promises](#promises)
14. [Libuv Thread pool](#libuv-thread-pool)

### Background
Node.js is roughly [Google V8](https://github.com/v8/v8), [libuv](https://github.com/libuv/libuv) and Node.js core which glues
everything together.

V8 bascially consists of the memory management of the heap and the execution stack (very simplified but helps
make my point). If you are used to web client side development you'll know about the WebAPIs that are also
available like DOM, AJAX, setTimeout etc. This functionality is not provided by V8 but in instead by chrome.
There is also nothing about a event loop in V8, this is also something that is provided by chrome.

    +------------------------------------------------------------------------------------------+
    | Google Chrome                                                                            |
    |                                                                                          |
    | +----------------------------------------+          +------------------------------+     |
    | | Google V8                              |          |            WebAPIs           |     |
    | | +-------------+ +---------------+      |          |                              |     |
    | | |    Heap     | |     Stack     |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | +-------------+ +---------------+      |          |                              |     |
    | |                                 |      |          |                              |     |
    | +----------------------------------------+          +------------------------------+     |
    |                                                                                          |
    |                                                                                          |
    | +---------------------+     +---------------------------------------+                    |
    | |     Event loop      |     |          Callback queue               |                    |
    | |                     |     |                                       |                    |
    | +---------------------+     +---------------------------------------+                    |
    |                                                                                          |
    |                                                                                          |
    +------------------------------------------------------------------------------------------+

The execution stack is a stack of frame pointers. For each function called, that function will be pushed onto
the stack. When a function returns it will be removed. If that function calls other functions
they will be pushed onto the stack.
When all functions have returned execution can proceed from the returned to point. If one of the functions performs
an operation that takes time, progress will not be made until it completes as the only way to complete is that the
function returns and is popped off the stack. This is what happens when you have a single threaded programming language.

Aychnronous work can be done by calling into the WebAPIs, for example calling setTimeout which will call out to the
WebAPI and then return. The functionality for setTimeout is provided by the WebAPI and when the timer is due the
WebAPI will push the callback onto the callback queue. Items from the callback queue will be picked up by the event
loop and pushed onto the stack for execution.

Now lets compare this with Node.js:

    +------------------------------------------------------------------------------------------+
    | Node.js                                                                                  |
    |                                                                                          |
    | +----------------------------------------+          +------------------------------+     |
    | | Google V8                              |          |        Node Core APIs        |     |
    | | +-------------+ +---------------+      |          |                              |     |
    | | |    Heap     | |     Stack     |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | |             | |               |      |          |                              |     |
    | | +-------------+ +---------------+      |          |                              |     |
    | |                                 |      |          |                              |     |
    | +----------------------------------------+          +------------------------------+     |
    |                                                                                          |
    |                                                                                          |
    | +---------------------+     +---------------------------------------+                    |
    | | libuv               |     |          Callback queue               |                    |
    | |     Event Loop      |     |                                       |                    |
    | +---------------------+     +---------------------------------------+                    |
    |                                                                                          |
    |                                                                                          |
    +------------------------------------------------------------------------------------------+

Taking the same example from above, `setTimeout`, this would be a call to Node Core API and then
the function will return. When the timer expires Node Core API will push the callback onto the
callback queue.
The event loop in Node is provided by libuv, whereas in chrome this is provided by the browser
(chromium I believe)

### Starting Node
To start and stop at first line in a js program use:

    $ lldb -- node --debug-brk test.js

Set a break point in node_main.cc:

    (lldb) breakpoint set --file node_main.cc --line 52
    (lldb) run

### Walkthrough
`node_main.cc` will bascially call node::Start which we can find in src/node.cc.

#### Start(int argc, char** argv)
Starts by calling PlatformInit

    default_platform = v8::platform::CreateDefaultPlatform(v8_thread_pool_size);
    V8::InitializePlatform(default_platform);
    V8::Initialize();
    ...
    Init(&argc, const_cast<const char**>(argv), &exec_argc, &exec_argv);

#### PlatformInit()
From what I understand this mainly sets up things like signals and file descriptor limits.

#### Init
Init has some libuv code that looks familiar to what I played around with in [learning-libuv](https://github.com/danbev/learning-libuv).

    uv_async_init(uv_default_loop(),
                 &dispatch_debug_messages_async,
                 DispatchDebugMessagesAsyncCallback);

Now I've not used `uv_async_init` but looking at the docs this is done to allow a different thread to wake up the event loop and have the
callback invoked. uv_async_init looks like this:

    int uv_async_init(uv_loop_t* loop, uv_async_t* async, uv_async_cb async_cb)

To understand this better this standalone [example](https://github.com/danbev/learning-libuv/blob/master/thread.c) helped my clarify things a bit.

    uv_unref(reinterpret_cast<uv_handle_t*>(&dispatch_debug_messages_async));

I believe this is done so that the ref count of the dispatch_debug_message_async handle is decremented. If this handle is the only thing 
referened that would cause the event loop to be considered alive and it will continue to iterate.

So a different thread can use uv_async_sent(&dispatch_debug_messages_async) to to wake up the eventloop and have the DispatchDebugMessagesAsyncCallback
function called.

### DispatchDebugMessagesAsyncCallback
If the debugger is not running this function will start it. This will print 'Starting debugger agent.' if it was not started. It will then start processing
debugger messages.

    ParseArgs(argc, argv, exec_argc, exec_argv, &v8_argc, &v8_argv);

Parses the command line arguments passed. If you want to inspect them you can use:

    (lldb) p *(char(*)[1]) new_v8_argv

This is something that I've not seen before either:

    if (v8_is_profiling) {
        uv_loop_configure(uv_default_loop(), UV_LOOP_BLOCK_SIGNAL, SIGPROF);
    }

What does uv_loop_configure do?  
It sets additional loop options. This [example](https://github.com/danbev/learning-libuv/blob/master/configure.c) was used to look a little closer 
at it.


    if (!use_debug_agent) {
       RegisterDebugSignalHandler();
    }

use_debug_agent is the flag `--debug` that can be provided to node. So when it is not give RegisterDebugSignalHandler will be called.


### RegisterDebugSignalHandler
First thing that happens is :

    CHECK_EQ(0, uv_sem_init(&debug_semaphore, 0));

We are creating a semaphore with a count of 0.

    sigset_t sigmask;
    sigfillset(&sigmask);
    CHECK_EQ(0, pthread_sigmask(SIG_SETMASK, &sigmask, &sigmask));

Calling `sigfillset` initializes a signal set to contain all signals. Then a pthreads_sigmask will replace the old mask with the new one.

     pthread_t thread;
     const int err = pthread_create(&thread, &attr, DebugSignalThreadMain, nullptr);

A new thread is created and its entry function will be DebugSignalThreadMain. The nullptr is the argument to the function.

     CHECK_EQ(0, pthread_sigmask(SIG_SETMASK, &sigmask, nullptr));

The last nullprt is the old set which can be stored (if it was not null that is)

    RegisterSignalHandler(SIGUSR1, EnableDebugSignalHandler);

This function will setup the sigaction struct and set the handler to EnableDebugSignalHandler. So sending USR1 to this process will invoke the
handler. But nothing has been sent at this time, only configured to handle these signals.

### DebugSignalThreadMain
Will block waiting for the semaphore to become non zero. If you check above, the counter for the semaphore is zero so 
any thread calling uv_sem_wait will block until it becomes non-zero. 

    for (;;) {
      uv_sem_wait(&debug_semaphore);
      TryStartDebugger();
    } 
    return nullptr;

So this thread will just wait until uv_sem_post(&debug_semaphore) is called. So where is that done? That is done in EnableDebugSignalHandler

### EnableDebugSignalHandler
This is where we signal the semaphore which will increment the counter, and any threads in the wait queue will now run. So our thread that is
blocked waiting for this debug_semaphore will be able to proceed and TryStartDebugger will be called.

    uv_sem_post(&debug_semaphore);

But what will actually send the signal for all this to happen? 
I think this is done DebugProcess(const FunctionCallbackInfo<Value>& args). Setting a break point confirmed this and the back trace:

	(lldb) bt
	* thread #1: tid = 0x11f57b1, 0x0000000100cafddc node`node::DebugProcess(args=0x00007fff5fbf4700) + 12 at node.cc:3754, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
	  * frame #0: 0x0000000100cafddc node`node::DebugProcess(args=0x00007fff5fbf4700) + 12 at node.cc:3754
	    frame #1: 0x000000010028618b node`v8::internal::FunctionCallbackArguments::Call(this=0x00007fff5fbf4878, f=(node`node::DebugProcess(v8::FunctionCallbackInfo<v8::Value> const&) at node.cc:3753))(v8::FunctionCallbackInfo<v8::Value> const&)) + 139 at arguments.cc:33
	    frame #2: 0x00000001002f58f3 node`v8::internal::MaybeHandle<v8::internal::Object> v8::internal::(anonymous namespace)::HandleApiCallHelper<false>(isolate=0x0000000104004000, args=BuiltinArguments<v8::internal::BuiltinExtraArguments::kTarget> @ 0x00007fff5fbf49d0)::BuiltinArguments<(v8::internal::BuiltinExtraArguments)1>) + 1619 at builtins.cc:3915
	    frame #3: 0x000000010031ce36 node`v8::internal::Builtin_Impl_HandleApiCall(args=v8::internal::(anonymous namespace)::HandleApiCallArgumentsType @ 0x00007fff5fbf4a38, isolate=0x0000000104004000)::BuiltinArguments<(v8::internal::BuiltinExtraArguments)1>, v8::internal::Isolate*) + 86 at builtins.cc:3939
	    frame #4: 0x00000001002f9c8f node`v8::internal::Builtin_HandleApiCall(args_length=3, args_object=0x00007fff5fbf4b28, isolate=0x0000000104004000) + 143 at builtins.cc:3936
	    frame #5: 0x00003ca66bf0961b
	    frame #6: 0x00003ca66c081e0d
	    frame #7: 0x00003ca66bf0d17a
	    frame #8: 0x00003ca66c01edb3
	    frame #9: 0x00003ca66c01e802
	    frame #10: 0x00003ca66bf0d17a
	    frame #11: 0x00003ca66c081b25
	    frame #12: 0x00003ca66c074fd2
	    frame #13: 0x00003ca66c074c6b
	    frame #14: 0x00003ca66bf38024
	    frame #15: 0x00003ca66bf22962
	    frame #16: 0x00000001006f11df node`v8::internal::(anonymous namespace)::Invoke(isolate=0x0000000104004000, is_construct=false, target=Handle<v8::internal::Object> @ 0x00007fff5fbf4f50, receiver=Handle<v8::internal::Object> @ 0x00007fff5fbf4f48, argc=0, args=0x0000000000000000, new_target=Handle<v8::internal::Object> @ 0x00007fff5fbf4f40) + 607 at execution.cc:97
	    frame #17: 0x00000001006f0f61 node`v8::internal::Execution::Call(isolate=0x0000000104004000, callable=Handle<v8::internal::Object> @ 0x00007fff5fbf50a8, receiver=Handle<v8::internal::Object> @ 0x00007fff5fbf50a0, argc=0, argv=0x0000000000000000) + 1313 at execution.cc:163
	    frame #18: 0x000000010023f4af node`v8::Function::Call(this=0x0000000104062c20, context=(val_ = 0x00000001040404c8), recv=(val_ = 0x00000001040628a0), argc=0, argv=0x0000000000000000) + 671 at api.cc:4404
	    frame #19: 0x000000010023f611 node`v8::Function::Call(this=0x0000000104062c20, recv=(val_ = 0x00000001040628a0), argc=0, argv=0x0000000000000000) + 113 at api.cc:4413
	    frame #20: 0x0000000100c8f3b8 node`node::AsyncWrap::MakeCallback(this=0x0000000104800d50, cb=(val_ = 0x00000001040404a0), argc=3, argv=0x00007fff5fbf5690) + 2600 at async-wrap.cc:284
	    frame #21: 0x0000000100c937e6 node`node::AsyncWrap::MakeCallback(this=0x0000000104800d50, symbol=(val_ = 0x000000010403e5b0), argc=3, argv=0x00007fff5fbf5690) + 198 at async-wrap-inl.h:110
	    frame #22: 0x0000000100d06c67 node`node::StreamBase::EmitData(this=0x0000000104800d50, nread=43, buf=(val_ = 0x0000000104040488), handle=(val_ = 0x0000000000000000)) + 551 at stream_base.cc:427
	    frame #23: 0x0000000100d0adc3 node`node::StreamWrap::OnReadImpl(nread=43, buf=0x00007fff5fbf58f8, pending=UV_UNKNOWN_HANDLE, ctx=0x0000000104800d50) + 675 at stream_wrap.cc:222
	    frame #24: 0x0000000100ca25a7 node`node::StreamResource::OnRead(this=0x0000000104800d50, nread=43, buf=0x00007fff5fbf58f8, pending=UV_UNKNOWN_HANDLE) + 119 at stream_base.h:171
	    frame #25: 0x0000000100d0b93f node`node::StreamWrap::OnReadCommon(handle=0x0000000104800df0, nread=43, buf=0x00007fff5fbf58f8, pending=UV_UNKNOWN_HANDLE) + 351 at stream_wrap.cc:246
	    frame #26: 0x0000000100d0b3d4 node`node::StreamWrap::OnRead(handle=0x0000000104800df0, nread=43, buf=0x00007fff5fbf58f8) + 116 at stream_wrap.cc:261
	    frame #27: 0x0000000100f70e93 node`uv__read(stream=0x0000000104800df0) + 1555 at stream.c:1192
	    frame #28: 0x0000000100f6cb8c node`uv__stream_io(loop=0x00000001019ee200, w=0x0000000104800e78, events=1) + 348 at stream.c:1259
	    frame #29: 0x0000000100f7b784 node`uv__io_poll(loop=0x00000001019ee200, timeout=7073) + 3492 at kqueue.c:276
	    frame #30: 0x0000000100f5e62f node`uv_run(loop=0x00000001019ee200, mode=UV_RUN_ONCE) + 207 at core.c:354
	    frame #31: 0x0000000100cb33a0 node`node::StartNodeInstance(arg=0x00007fff5fbfea60) + 912 at node.cc:4303
	    frame #32: 0x0000000100cb2f8d node`node::Start(argc=2, argv=0x0000000103404a60) + 253 at node.cc:4380
	    frame #33: 0x0000000100cede9b node`main(argc=2, argv=0x00007fff5fbfeb18) + 75 at node_main.cc:54
	    frame #34: 0x0000000100001634 node`start + 52

So to recap, SetupProcessObject sets up the process object for node and one of the methods it sets is '_debugProcess':

     env->SetMethod(process, "_debugProcess", DebugProcess);

SetupProcessObject is called from Environment::Start (src/env.cc):

    * thread #1: tid = 0x1207377, 0x0000000100cad2fc node`node::SetupProcessObject(env=0x00007fff5fbfe108, argc=2, argv=0x0000000103604a20, exec_argc=0, exec_argv=0x0000000103604410) + 11020 at node.cc:3205, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
     * frame #0: 0x0000000100cad2fc node`node::SetupProcessObject(env=0x00007fff5fbfe108, argc=2, argv=0x0000000103604a20, exec_argc=0, exec_argv=0x0000000103604410) + 11020 at node.cc:3205
       frame #1: 0x0000000100c91bc7 node`node::Environment::Start(this=0x00007fff5fbfe108, argc=2, argv=0x0000000103604a20, exec_argc=0, exec_argv=0x0000000103604410, start_profiler_idle_notifier=false) + 919 at env.cc:91
       frame #2: 0x0000000100cb32b1 node`node::StartNodeInstance(arg=0x00007fff5fbfeaa0) + 673 at node.cc:4274
       frame #3: 0x0000000100cb2f8d node`node::Start(argc=2, argv=0x0000000103604a20) + 253 at node.cc:4380
       frame #4: 0x0000000100cede9b node`main(argc=2, argv=0x00007fff5fbfeb58) + 75 at node_main.cc:54
       frame #5: 0x0000000100001634 node`start + 52


After that detour we are back in the Start method, and the next line is:

    default_platform = v8::platform::CreateDefaultPlatform(v8_thread_pool_size);
    (lldb) p v8_thread_pool_size
    (int) $30 = 4

We can find the implementation of this in `deps/v8/src/libplatform/default-platform.cc`.
The call is the same as was used in the hello_world example except here the size of the thread pool is being passed in 
and in the hello_world the no arguments method was called. I only skimmed this part when I was working through that 
example so it might be good to figure out what is going on here.

An instance of DefaultPlatform is created and then its SetThreadPoolSize method is called with v8_thread_pool_size. When
the size is not given it will default to `p SysInfo::NumberOfProcessors()`. 
Next, EnsureInitialized is called which does a check to see if the instance has already been initilized and if not:

     for (int i = 0; i < thread_pool_size_; ++i)
       thread_pool_.push_back(new WorkerThread(&queue_));

This will create new workers and threads for them. This call finds its way down into deps/v8/src/base/platform/platform-posix.c
and its Thread::Start method:

    LockGuard<Mutex> lock_guard(&data_->thread_creation_mutex_);
    result = pthread_create(&data_->thread_, &attr, ThreadEntry, this);    

We can see this is where the creation and starting of a new thread is done. The first argument is the pthread_t to associate with
the function ThreadEntry which is the top level entry point for the new thread. 
The second argument are additional attributes. The third argument is the function as already mentioned and the fourth parameter is
the argument to the function. So we can see that ThreadEntry takes the current instance as an argument (well it takes a void pointer):

    static void* ThreadEntry(void* arg) {
     Thread* thread = reinterpret_cast<Thread*>(arg);
     // We take the lock here to make sure that pthread_create finished first since
     // we don't know which thread will run first (the original thread or the new
     // one).
     { LockGuard<Mutex> lock_guard(&thread->data()->thread_creation_mutex_); }
     SetThreadName(thread->name());
     DCHECK(thread->data()->thread_ != kNoThread);
     thread->NotifyStartedAndRun();
     return NULL;
   }

ThreadEntry is using a LockGuard and creates a scope to use the Resource Acquisition Is Initialization (RAII) idiom for a mutex. The 
scope is very limited but like the comment says is really just trying to aquire the lock, which was the same that was used when 
creating the thread above.
So, lets take a look at thread->NotifyStartedAndRun()

### NotifyStartedAndRun

    void NotifyStartedAndRun() {
      if (start_semaphore_) start_semaphore_->Signal();
      Run();
   }

### LockGuard
So a lock guard is an implementation of Resource Acquisition Is Initialization (RAII) and takes a mutex in its constructor which it then
calls lock on. When this instance goes out of scope its descructor will be called and it will call unlock guarenteeing that the mutex 
will be unlocked even if an exception is thrown.
The Mutex class can be found in deps/v8/src/base/platform/mutex.h. On a Unix system the mutex will be of type pthread_mutex_t

We can verify this by inspecting the threads before and after 
the calls.
Before:

    (lldb) thread list
    Process 4614 stopped
    * thread #1: tid = 0xe0d19a, 0x0000000100f80cc1 node`v8::base::Thread::Start(this=0x0000000103206110) + 321 at platform-posix.cc:618, queue = 'com.apple.main-thread', stop reason = step over
      thread #2: tid = 0xe0d2f2, 0x00007fff858affae libsystem_kernel.dylib`semaphore_wait_trap + 10

After: 

    (lldb) thread list
    Process 4669 stopped
    * thread #1: tid = 0xe0e3a7, 0x0000000100f80cdb node`v8::base::Thread::Start(this=0x0000000103206530) + 347 at platform-posix.cc:619, queue = 'com.apple.main-thread', stop reason = step over
      thread #2: tid = 0xe0e46d, 0x00007fff858affae libsystem_kernel.dylib`semaphore_wait_trap + 10
      thread #3: tid = 0xe0f230, 0x0000000100f81570 node`v8::base::Thread::data(this=0x0000000103206530) at platform.h:463

What does one of these thread do?
Lets set a breakpoint in the ThreadEntry method:

    (lldb) breakpoint set --file platform-posix.cc --line 582


#### NodeInstanceData
In the Start method we can see a block with the creation of a new NodeInstanceData instance:

    int exit_code = 1;
    {
      NodeInstanceData instance_data(NodeInstanceType::MAIN,
                                     uv_default_loop(),
                                     argc,
                                     const_cast<const char**>(argv),
                                     exec_argc,
                                     exec_argv,
                                     use_debug_agent);
      StartNodeInstance(&instance_data);
      exit_code = instance_data.exit_code();
    }	

There are two NodeInstanceTypes, MAIN and WORKER.
The second argument is the libuv event loop to be used.

#### StartNodeInstance
We are passing the NodeInstanceData instance we created above.
The code in this method is very similar to the code that we used in the [hello-world.cc](https://github.com/danbev/learning-v8/blob/76ec09b60019e893cc23036aa2bc3bdc07c85f77/hello-world.cc#L63-L70).
A new Isolate is created. Remember that an Isolate is an independant copy of the V8 runtime, with its own heap.

    Environment* env = CreateEnvironment(isolate, context, instance_data);


#### CreateEnvironment(isolate, context, instance_data)

    Local<FunctionTemplate> process_template = FunctionTemplate::New(isolate);
    process_template->SetClassName(FIXED_ONE_BYTE_STRING(isolate, "process"));
    ...
    SetupProcessObject(env, argc, argv, exec_argc, exec_argv);

This looks like the node `process` object is being created here. 
All the JavaScript built-in objects are provided by the V8 runtime but the process object is not one of them. So here we are doing 
the same as in the hello-world example above but naming the object 'process'

    auto maybe = process->SetAccessor(env->context(),
                                 env->title_string(),
                                 ProcessTitleGetter,
                                 ProcessTitleSetter,
                                 env->as_external());
    CHECK(maybe.FromJust());

Notice that SetAccessor returns an "optional" MayBe type.

    READONLY_PROPERTY(process,
       "version",
       FIXED_ONE_BYTE_STRING(env->isolate(), NODE_VERSION));

The above is adding properties to the 'process' object. The first being version and then:

    process.moduleLoadList
    process.versions[
      http_parser,
      node,
      v8,
      vu,
      zlib,
      ares,
      icu,
      modules
    ]
    process.icu_data_dir
    process.arch
    process.platform
    process.release
    process.release.name
    process.release.lts
    process.release.sourceUrl
    process.release.headersUrl

    process.env
    process.pid
    process.features



    READONLY_PROPERTY(process,
                     "moduleLoadList",
                     env->module_load_list_array());
I was not aware of this one but process.moduleLoadList will return an array of modules loaded.

     READONLY_PROPERTY(process, "versions", versions);

Next up is process.versions which on my local machine returns:

    > process.versions
    { http_parser: '2.5.2',
      node: '4.4.3',
      v8: '4.5.103.35',
      uv: '1.8.0',
      zlib: '1.2.8',
      ares: '1.10.1-DEV',
      icu: '56.1',
      modules: '46',
      openssl: '1.0.2g' }

After setting up all the object (SetupProcessObject) this methods returns. There is still no sign of the loading of the 'bootstrap_node.js' script. 
This is done in LoadEnvironment.

#### LoadEnvironment

    Local<String> script_name = FIXED_ONE_BYTE_STRING(env->isolate(), "bootstrap_node.js");

#### lib/internal/bootstrap_node.js
This is the file that is loaded by LoadEnvironment as "bootstrap_node.js". 
I read that this file is actually precompiled, where/how?

This file is referenced in node.gyp and is used with the target node_js2c. This target calls tools/js2c.py which is a tool for converting 
JavaScript source code into C-Style char arrays. This target will process all the library_files specified in the variables section which 
lib/internal/bootstrap_node.js is one of. The output of this out/Debug/obj/gen/node_natives.h, depending on the type of build being performed. 
So lib/internal/bootstrap_node.js will become internal_bootstrap_node_native in node_natives.h. 
This is then later included in src/node_javascript.cc 

We can see the contents of this in lldb using:

    (lldb) p internal_bootstrap_node_native

### Loading of Node Native JavaScript
The JavaScript source files that are located in the lib directory are not loaded in the normal way the JavaScript sources you provide yourself.
Instead these are converted first into c arrays for faster execution. This is done by a build and more specifically a Python tool called `js2c.py`
(JavaScript to C).

### Loading of builtins
I wanted to know how builtins, like tcp\_wrap and others are loaded.
Lets take a look at the following line from src/tcp_wrap.cc:

    NODE_MODULE_CONTEXT_AWARE_BUILTIN(tcp_wrap, node::TCPWrap::Initialize)

Now, setting a breakpoint on this and printing the thread backtrace gives:

    -> 436 	NODE_MODULE_CONTEXT_AWARE_BUILTIN(tcp_wrap, node::TCPWrap::Initialize)
    (lldb) bt
    * thread #1: tid = 0x18d8053, 0x0000000100d1056b node`_register_tcp_wrap() + 11 at tcp_wrap.cc:436, queue = 'com.apple.main-thread', stop reason = breakpoint 5.1
      * frame #0: 0x0000000100d1056b node`_register_tcp_wrap() + 11 at tcp_wrap.cc:436
        frame #1: 0x00007fff5fc1310b dyld`ImageLoaderMachO::doModInitFunctions(ImageLoader::LinkContext const&) + 265
        frame #2: 0x00007fff5fc13284 dyld`ImageLoaderMachO::doInitialization(ImageLoader::LinkContext const&) + 40
        frame #3: 0x00007fff5fc0f8bd dyld`ImageLoader::recursiveInitialization(ImageLoader::LinkContext const&, unsigned int, ImageLoader::InitializerTimingList&, ImageLoader::UninitedUpwards&) + 305
        frame #4: 0x00007fff5fc0f743 dyld`ImageLoader::processInitializers(ImageLoader::LinkContext const&, unsigned int, ImageLoader::InitializerTimingList&, ImageLoader::UninitedUpwards&) + 127
        frame #5: 0x00007fff5fc0f9b3 dyld`ImageLoader::runInitializers(ImageLoader::LinkContext const&, ImageLoader::InitializerTimingList&) + 75
        frame #6: 0x00007fff5fc020f1 dyld`dyld::initializeMainExecutable() + 208
        frame #7: 0x00007fff5fc05d98 dyld`dyld::_main(macho_header const*, unsigned long, int, char const**, char const**, char const**, unsigned long*) + 3596
        frame #8: 0x00007fff5fc01276 dyld`dyldbootstrap::start(macho_header const*, int, char const**, long, macho_header const*, unsigned long*) + 512
        frame #9: 0x00007fff5fc01036 dyld`_dyld_start + 54

First things to note is that `NODE_MODULE_CONTEXT_AWARE_BUILDIN` is a macro defined in node.h which takes a `modname` and `regfunc` argument. This in turn calls another macro function named `NODE_MODULE_CONTEXT_AWARE_X`.
This macro is invoked with the following arguments:

    NODE_MODULE_CONTEXT_AWARE_X(modname, regfunc, NULL, NM_F_BUILTIN)

We already know that in our case modname is `tcp_wrap` and that `regfunc` is node::TCPWrap::Initialize. 

#### NODE\_MODULE\_CONTEXT\_AWARE\_X

    #define NODE_MODULE_CONTEXT_AWARE_X(modname, regfunc, priv, flags)    \
      extern "C" {                                                        \
        static node::node_module _module =                                \
        {                                                                 \
          NODE_MODULE_VERSION,                                            \
          flags,                                                          \
          NULL,                                                           \
          __FILE__,                                                       \
          NULL,                                                           \
          (node::addon_context_register_func) (regfunc),                  \
          NODE_STRINGIFY(modname),                                        \
          priv,                                                           \
          NULL                                                            \
        };                                                                \
        NODE_C_CTOR(_register_ ## modname) {                              \
          node_module_register(&_module);                                 \
        }                                                                 \
    }
    
First, extern "C" means that C linkage should be used and no C++ name mangling should occur. This is saying that everything in the block should have this kind of linkage.
With that out of the way we can focus on the contents of the block.

        static node::node_module _module =                                \
        {                                                                 \
          NODE_MODULE_VERSION,                                            \
          flags,                                                          \
          NULL,                                                           \
          __FILE__,                                                       \
          NULL,                                                           \
          (node::addon_context_register_func) (regfunc),                  \
          NODE_STRINGIFY(modname),                                        \
          priv,                                                           \
          NULL                                                            \
        };                                                                \

We are creating a static variable (it exists for the lifetime of the program, but the name is not visible outside of the block. Remember that we are in tcp_wrap.cc in this walk through so the preprocessor will add a definition of the `_module` to that tcp_wrap.
`node_module` is a struct in node.h and looks like this:

    struct node_module {
      int nm_version;
      unsigned int nm_flags;
      void* nm_dso_handle;
      const char* nm_filename;
      node::addon_register_func nm_register_func;
      node::addon_context_register_func nm_context_register_func;
      const char* nm_modname;
      void* nm_priv;
      struct node_module* nm_link;
    };

So we have created a struct with the values above. Next we have:

    NODE_C_CTOR(_register_ ## modname) {                              \
      node_module_register(&_module);                                 \
    }                                                                 \

``##`` will concatenate two symbols. In our case the value passed  is `_register_tcp_wrap`.
NODE\_C\_CTOR is another macro function (see below).


#### NODE\_C\_CTOR

    #define NODE_C_CTOR(fn)                                               \
      static void fn(void) __attribute__((constructor));                  \
      static void fn(void)
    #endif

In our case the value of fn is `_register_tcp_wrap`. ## will concatenate two symbols. So that leaves us with:
    
      static void _register_tcp_wrap(void) __attribute__((constructor));                  \
      static void _register_tcp_wrap(void)

Lets start with \_\_attribute\_\_((constructor)), what is this all about?  
In shared object files there are special sections which contains references to functions marked with constructor attributes. The attributes are a gcc feature. When the library gets loaded the dynamic loader program checks whether such sections exist and calls these functions.
The constructor attribute causes the function to be called automatically before execution enters main () so this can also be used without shared libraries. You can verify this by checking the backtrace above.

Now that we know that, lets look at these two lines:

      static void _register_tcp_wrap(void) __attribute__((constructor));                  \
      static void _register_tcp_wrap(void)

The first is the declaration of a function and the second line is the definition. You have to remember that the macro is expanded by the preprocessor so we have to look at the call as well:

    NODE_C_CTOR(_register_ ## modname) {                              \
      node_module_register(&_module);                                 \
    }                                                                 \

So this would become something like:

    static void _register_tcp_wrap(void) __attribute__((constructor));                  
    static void _register_tcp_wrap(void) {
      node_module_register(&_module);                                 
    }

To verify this we can run the preprocessor:

    $ clang -E src/tcp_wrap.cc
    ...
    extern "C" { 
      static node::node_module _module = { 
        48, 
        0x01, 
        __null, 
        "src/tcp_wrap.cc", 
        __null, 
        (node::addon_context_register_func) (node::TCPWrap::Initialize), 
        "tcp_wrap", 
        __null, 
        __null 
      }; 
       static void _register_tcp_wrap(void) __attribute__((constructor)); 
       static void _register_tcp_wrap(void) { 
         node_module_register(&_module); 
       } 
    }

### node\_module\_register
In this case since our call looked like this:

    NODE_MODULE_CONTEXT_AWARE_X(modname, regfunc, NULL, NM_F_BUILTIN)

Notice the `NM_F_BUILTIN`, this module will be added to the list of modlist_builtin. Note that this is a linked list.
There is also `NM_F_LINKED` which are "Linked" modules includes as part of the node project.
What are the differences here? 
TODO: answer this question

For a addon, the macro looks like:

    NODE_MODULE(binding, init);

    #define NODE_MODULE(modname, regfunc)                                 \
      NODE_MODULE_X(modname, regfunc, NULL, 0)

`NODE_MODULE_X` is identical `NODE_MODULE_CONTEXT_AWARE_X` apart from the type of the register function

    typedef void (*addon_register_func)(
      v8::Local<v8::Object> exports,
      v8::Local<v8::Value> module,
      void* priv);

    typedef void (*addon_context_register_func)(
      v8::Local<v8::Object> exports,
      v8::Local<v8::Value> module,
      v8::Local<v8::Context> context,
      void* priv);



### Environment
To create an Environment we need to have an v8::Isolate instance and also an IsolateData instance:

     inline Environment(IsolateData* isolate_data, v8::Local<v8::Context> context);

Such a call can be found during startup: 

    (lldb) bt
      * thread #1: tid = 0x946796, 0x00000001008fa39f node`node::Start(int, char**) + 307 at node.cc:4390, queue = 'com.apple.main-thread', stop reason = step over
        * frame #0: 0x00000001008fa39f node`node::Start(int, char**) + 307 at node.cc:4390
          frame #1: 0x00000001008fa26c node`node::Start(argc=<unavailable>, argv=0x0000000102a00000) + 205 at node.cc:4503
          frame #2: 0x0000000100000b34 node`start + 52

See IsolateData for details about that class and the members that are proxied through via an Environment instance.

An Environment has a number of nested classes:

    AsyncHooks
    AsyncHooksCallbackScope
    DomainFlag
    TickInfo

The above nested classes call the `DISALLOW_COPY_AND_ASSIGN` macro, for example:

    DISALLOW_COPY_AND_ASSIGN(TickInfo);

This macro uses `= delete` for the copy and assignment operator functions:

    #define DISALLOW_COPY_AND_ASSIGN(TypeName) \
    TypeName(const TypeName&) = delete;      \
    void operator=(const TypeName&) = delete

The last nested class is: 

    HandleCleanup

Environment also has a number of static methods:

    static inline Environment* GetCurrent(v8::Isolate* isolate);

This got me wondering, how can we get an Environment from an Isolate, an Isolate is a V8 thing
and an Environment a Node thing?

    inline Environment* Environment::GetCurrent(v8::Isolate* isolate) {
      return GetCurrent(isolate->GetCurrentContext());
    }

So we are going to use the current context to get the Environment pointer, but the context is also a V8 concept, not a node.js concept.

    inline Environment* Environment::GetCurrent(v8::Local<v8::Context> context) {
     return static_cast<Environment*>(context->GetAlignedPointerFromEmbedderData(kContextEmbedderDataIndex));
    }

Alright, now we are getting somewhere. Lets take a closer look at `context->GetAlignedPointerFromEmbedderData(kContextEmbedderDataIndex)`.
We have to look at the Environment constructor to see where this is set (env-inl.h):

    inline Environment::Environment(IsolateData* isolate_data, v8::Local<v8::Context> context) 
    ...
    AssignToContext(context);

So, we can see that `AssignToContext` is setting the environment on the passed-in context:

    static const int kContextEmbedderDataIndex = 5;

    inline void Environment::AssignToContext(v8::Local<v8::Context> context) {
      context->SetAlignedPointerInEmbedderData(kContextEmbedderDataIndex, this);
    }

So this how the Environment is associated with the context, and this enables us to get the environment for a context above. 
The argument to `SetAlignedPointerInEmbedderData` is a void pointer so it can be anything you want. 
The data is stored in a V8 FixedArray, the `kContextEmbedderDataIndex` is the index into this array (I think, still learning here).
TODO: read up on how this FixedArray and alignment works.

There are also static methods to get the Environment using a context.

So an Isolate is like single instance of V8 runtime.
A Context is a separate execution context that does not know about other context.

An Environment is a Node.js concept and multiple environments can exist within a single isolate.
What I'm trying to figure out is how a AtExit callback can be registered with an environment, 
and also how to force that callback to be called when that particular environment is about to
exit. Currently, this is done with a thread-local, but if there are multiple environments per
thread these will overwrite each other.

#### ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES
These are declared in env.h:

    #define ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES(V)                           \
      V(as_external, v8::External)                                                \
      V(async_hooks_destroy_function, v8::Function)                               \
      V(async_hooks_init_function, v8::Function)                                  \
      V(async_hooks_post_function, v8::Function)                                  \
      V(async_hooks_pre_function, v8::Function)                                   \
      V(binding_cache_object, v8::Object)                                         \
      V(buffer_constructor_function, v8::Function)                                \
      V(buffer_prototype_object, v8::Object)                                      \
      V(context, v8::Context)                                                     \
      V(domain_array, v8::Array)                                                  \
      V(domains_stack_array, v8::Array)                                           \
      V(fs_stats_constructor_function, v8::Function)                              \
      V(generic_internal_field_template, v8::ObjectTemplate)                      \
      V(jsstream_constructor_template, v8::FunctionTemplate)                      \
      V(module_load_list_array, v8::Array)                                        \
      V(pipe_constructor_template, v8::FunctionTemplate)                          \
      V(process_object, v8::Object)                                               \
      V(promise_reject_function, v8::Function)                                    \
      V(push_values_to_array_function, v8::Function)                              \
      V(script_context_constructor_template, v8::FunctionTemplate)                \
      V(script_data_constructor_function, v8::Function)                           \
      V(secure_context_constructor_template, v8::FunctionTemplate)                \
      V(tcp_constructor_template, v8::FunctionTemplate)                           \
      V(tick_callback_function, v8::Function)                                     \
      V(tls_wrap_constructor_function, v8::Function)                              \
      V(tls_wrap_constructor_template, v8::FunctionTemplate)                      \
      V(tty_constructor_template, v8::FunctionTemplate)                           \
      V(udp_constructor_function, v8::Function)                                   \
      V(write_wrap_constructor_function, v8::Function)                            \

Notice that `V` is passed in enabling different macros to be passed in. This is used
to create setters/getters like this:

    #define V(PropertyName, TypeName)                                             \
      inline v8::Local<TypeName> PropertyName() const;                            \
      inline void set_ ## PropertyName(v8::Local<TypeName> value);
      ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES(V)
    #undef V

The field itself is private and defined in env.h:

    #define V(PropertyName, TypeName)                                             \
      v8::Persistent<TypeName> PropertyName ## _;
      ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES(V)
    #undef V

The above is defining getters and setter for all the properties in `ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES`. Notice the usage of V and that is is passed into the macro.
Lets take a look at one:

    V(tcp_constructor_template, v8::FunctionTemplate)

Like before these are only the declarations, the definitions can be found in src/env-inl.h:

    #define V(PropertyName, TypeName)                                             \
      inline v8::Local<TypeName> Environment::PropertyName() const {              \
        return StrongPersistentToLocal(PropertyName ## _);                        \
      }                                                                           \
      inline void Environment::set_ ## PropertyName(v8::Local<TypeName> value) {  \
        PropertyName ## _.Reset(isolate(), value);                                \
      }
      ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES(V)
    #undef V 

So, in the case of `tcp_constructor_template` this would become:

    inline v8::Local<v8::FunctionTemplate> Environment::tcp_constructor_template() const {              
      return StrongPersistentToLocal(tcp_constructor_template_);                        
    }                                                                           
    inline void Environment::set_tcp_constructor_template(v8::Local<v8::FunctionTempalate> value) {  
      tcp_constructor_template_.Reset(isolate(), value);                                
    }

So where is this setter called?   
It is called from `TCPWrap::Initialize`:

    env->set_tcp_constructor_template(t); 

And when is `TCPWrap::Initialize` called?  
From Binding in `node.cc`:

    ...
    mod->nm_context_register_func(exports, unused, env->context(), mod->nm_priv);

Recall (from `Loading of builtins`) how a module is registred:

    NODE_MODULE_CONTEXT_AWARE_BUILTIN(tcp_wrap, node::TCPWrap::Initialize)

The `nm_context_register_func` is `node::TCPWrap::Initialize`, which is a static method declared in src/tcp_wrap.h:

    static void Initialize(v8::Local<v8::Object> target,
                           v8::Local<v8::Value> unused,
                           v8::Local<v8::Context> context);


    wrap_data->MakeCallback(env->onconnection_string(), arraysize(argv), argv);

`env->onconnection_string() is a simple getter generated by the preprocessor by a macro in env-inl.h


### TCPWrap::Initialize
First thing that happens is that the Environment is retreived using the current context.

Next, a function template is created:

    Local<FunctionTemplate> t = env->NewFunctionTemplate(New);

Just to be clear `New` is the address of the function and we are just passing that to the NewFunctionTemplate method. It will use that address when creating a NewFunctionTemplate.

### TcpWrap::New
This class is called TcpWrap because is wraps a libuv [uv_tcp_t](http://docs.libuv.org/en/v1.x/tcp.html) handle. 
    
    static void SetNoDelay(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void SetKeepAlive(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Bind(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Bind6(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Listen(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Connect(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Connect6(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Open(const v8::FunctionCallbackInfo<v8::Value>& args);

Each of the functions above, for example `SetNoDelay` will all wrap a function call in libuv:

    void TCPWrap::SetNoDelay(const FunctionCallbackInfo<Value>& args) {
      TCPWrap* wrap;
      ASSIGN_OR_RETURN_UNWRAP(&wrap,
                              args.Holder(),
                              args.GetReturnValue().Set(UV_EBADF));
      int enable = static_cast<int>(args[0]->BooleanValue());
      int err = uv_tcp_nodelay(&wrap->handle_, enable);
      args.GetReturnValue().Set(err);
    }

When a new instance of this class is created it will initialize the handle which must be of type uv_tcp_t:

    int r = uv_tcp_init(env->event_loop(), &handle_);

Now, a uv_tcp_t could be used for [accepting](https://github.com/danbev/learning-libuv/blob/master/server.c) connection but also for 
[connecting](https://github.com/danbev/learning-libuv/blob/master/client.c) to sockets. 

When this is used in JavaScript is would look like this:

    var TCP = process.binding('tcp_wrap').TCP;
    var handle = new TCP();

When the second line is executed the callback `New` will be invoked. This is set up by this line later in TCPWrap::Initialize:

    target->Set(FIXED_ONE_BYTE_STRING(env->isolate(), "TCP"), t->GetFunction());

New takes a single argument of type v8::FunctionCallbackInfo which holds information about the function call make. 
These are things like the number of arguments used, the arguments can be retreived using with the operator[]. `New` looks like this:

    void TCPWrap::New(const FunctionCallbackInfo<Value>& a) {
      CHECK(a.IsConstructCall());
      Environment* env = Environment::GetCurrent(a);
      TCPWrap* wrap;
      if (a.Length() == 0) {
        wrap = new TCPWrap(env, a.This(), nullptr);
      } else if (a[0]->IsExternal()) {
        void* ptr = a[0].As<External>()->Value();
        wrap = new TCPWrap(env, a.This(), static_cast<AsyncWrap*>(ptr));
      } else {
        UNREACHABLE();
      }
      CHECK(wrap);
    }
Like mentioned above when the constructor of TCPWrap is called it will initialize the uv_tcp_t handle.
Using the example above we can see that `Length` should be 0 as we did not pass any arguments to the TCP function. Just wondering, what could be passed as a parameter?  
What ever it might look like it should be a pointer to an AsyncWrap.

So this is where the instance of TCPWrap is created. Notice `a.This()` which is passed all the way up to BaseObject's constructor and made into a persistent handle.

    const req = new TCPConnectWrap();
    const err = client.connect(req, '127.0.0.1', this.address().port);

Now, new TcpConnectWrap() is setup in TCPWrap::Initalize and the only thing that happens here is that it configured with a constructor that checks that this function is called with the `new` keyword. So there is really nothing else happening at this stage. But, when we call `client.connect` something interesting does happen:
TCPWrap::Connect

    if (err == 0) {
    ConnectWrap* req_wrap = new ConnectWrap(env, req_wrap_obj, AsyncWrap::PROVIDER_TCPCONNECTWRAP);
    err = uv_tcp_connect(req_wrap->req(),
                         &wrap->handle_,
                         reinterpret_cast<const sockaddr*>(&addr),
                         AfterConnect);
    req_wrap->Dispatched();
    if (err)
      delete req_wrap;
  }

So we can see that we are creating a new ConnectWrap instance which extends AsyncWrap and also ReqWrap. Thinking about this makes sense I think. If we recall that the classes with Wrap in them wrap libuv concepts, and in this case we are going to make a tcp connection. If we look at our [client](https://github.com/danbev/learning-libuv/blob/master/client.c) example we can see that we are using uv_connect_t make the connection (named `connection_req`):

    r = uv_tcp_connect(&connect_req,
                       &tcp_client,
                       (const struct sockaddr*) &addr,
                       connect_cb);
    
`tcp_client` in the above example is of type `uv_tcp_t`.
But ConnectWrap also extend AsyncWrap. See the AsyncWrap section for details.
What might be of interest and something to look into a little deeper is that ReqWrap will add the request wrap (wrapping a uv_req_t remember) to the current env req_wrap_queue. Keep in mind that a reqest is shortlived.
The last thing that the ConnectWrap constructor does is call Wrap:

    Wrap(req_wrap_obj, this);

Now, you might not remember what this `req_wrap_obj` is, but it was the first argument to `client.connect` and was the new `TCPConnectWrap` instance. But this was nothing more than a constructor and nothing else:

    (lldb) p req_wrap_obj
    (v8::Local<v8::Object>) $34 = (val_ = 0x00007fff5fbfd018)
    (lldb) p *(*req_wrap_obj)
    (v8::Object) $35 = {}

We can see that this is a v8::Local<v8::Object> and we are going to store the ConnectWrap instance in this object:

    req_wrap_obj->SetAlignedPointerInInternalField(0, this);

So why is this being done?   
Well if you take a look in AfterConnect you can see that this will be accessed and passed as a parameter to the oncomplete function:

    ConnectWrap* req_wrap = static_cast<ConnectWrap*>(req->data);
    ...
    Local<Value> argv[5] = {
      Integer::New(env->isolate(), status),
      wrap->object(),
      req_wrap->object(),
      Boolean::New(env->isolate(), readable),
      Boolean::New(env->isolate(), writable)
    };
    req_wrap->MakeCallback(env->oncomplete_string(), arraysize(argv), argv);
  
This will then invoke the `oncomplete` callback set up on the `req` object:
    
      req.oncomplete = function(status, client_, req_, readable, writable) {
      }
       
### NewFunctionTemplate
NewFunctionTemplate in env.h specifies a default value for the second parameter `v8::Local<v8::Signature>() so it does not have to be specified. 

     v8::Local<v8::External> external = as_external();
     return v8::FunctionTemplate::New(isolate(), callback, external, signature);

    (lldb) p callback
    (v8::FunctionCallback) $0 = 0x0000000100db8540 (node`node::TCPWrap::New(v8::FunctionCallbackInfo<v8::Value> const&) at tcp_wrap.cc:107)

So `t` is a function template, a blueprint for a single function. You create an instance of the template by calling `GetFunction`. Recall that in JavaScript to create a new type of object you use a function. When this function is used as a constructor, using new, the returned object will be an instance of the InstanceTemplate (ObjectTemplate) that will be discussed shortly.

    t->SetClassName(FIXED_ONE_BYTE_STRING(env->isolate(), "TCP"));

The class name is is used for printing objects created with the function created from the
FunctionTemplate as its constructor.

     t->InstanceTemplate()->SetInternalFieldCount(1);

`InstanceTemplate` returns the ObjectTemplate associated with the FunctionTemplate. Every FunctionTemplate has one. Like mentioned before this is the object that is returned after having used the FunctionTemplate as a constructor.
`SetInternalFieldCount(1)` instructs V8 to allocate internal storage for every instance created using this template. Anything can be stored that space allocated, and
for node this is often done using `SetAlignedPointerInInternalField`. This could then be retrieved using `GetAlignedPointerFromInternalField`.

Next, the ObjectTemplate is set up. First a number of properties are configured:

    t->InstanceTemplate()->Set(String::NewFromUtf8(env->isolate(), "reading"),
                               Boolean::New(env->isolate(), false));

Then, a number of prototype methods are set:
 
    env->SetProtoMethod(t, "close", HandleWrap::Close);

Alright, lets take a look at this `SetProtoMethod` method in Environment: 

    inline void Environment::SetProtoMethod(v8::Local<v8::FunctionTemplate> that,
                                         const char* name,
                                         v8::FunctionCallback callback) {
    v8::Local<v8::Signature> signature = v8::Signature::New(isolate(), that);
    v8::Local<v8::FunctionTemplate> t = NewFunctionTemplate(callback, signature);
    // kInternalized strings are created in the old space.
    const v8::NewStringType type = v8::NewStringType::kInternalized;
    v8::Local<v8::String> name_string =
       v8::String::NewFromUtf8(isolate(), name, type).ToLocalChecked();
    that->PrototypeTemplate()->Set(name_string, t);
    t->SetClassName(name_string);  // NODE_SET_PROTOTYPE_METHOD() compatibility.
   }

A `Signature` has the following class documentation: "A Signature specifies which receiver is valid for a function.". So the receiver is set to be `that` which is `t`, our newly created FunctionTemplate.

Next, we are creating a FunctionTemplate for the call back `HandleWrap::Close` with the signature just created.
Then, we will set the function template as a PrototypeTemplate. Again we see `t->SetClassName` which I believe is for when this is printed.
There are few more prototype methods that use HandleWrap callbacks:
    
    env->SetProtoMethod(t, "ref", HandleWrap::Ref);
    env->SetProtoMethod(t, "unref", HandleWrap::Unref);
    env->SetProtoMethod(t, "hasRef", HandleWrap::HasRef);

So have have a class called `HandleWrap`, which I think requires a section of its own.

After this we find the following line:

    StreamWrap::AddMethods(env, t, StreamBase::kFlagHasWritev);

This method is defined in stream_wrap.cc:

    env->SetProtoMethod(target, "setBlocking", SetBlocking);
    StreamBase::AddMethods<StreamWrap>(env, target, flags);

I've been wondering about the class names that end with Wrap and what they are wrapping. My thinking now is that they are wrapping libuv things. For instance, take StreamWrap, in libuv src/unix/stream.c which is what SetBlocking calls:

     void StreamWrap::SetBlocking(const FunctionCallbackInfo<Value>& args) {
       StreamWrap* wrap;
       ASSIGN_OR_RETURN_UNWRAP(&wrap, args.Holder());

       CHECK_GT(args.Length(), 0);
       if (!wrap->IsAlive())
         return args.GetReturnValue().Set(UV_EINVAL);

       bool enable = args[0]->IsTrue();
       args.GetReturnValue().Set(uv_stream_set_blocking(wrap->stream(), enable));
    }

Lets take a look at `ASSIGN_OR_RETURN_UNWRAP`: 

    #define ASSIGN_OR_RETURN_UNWRAP(ptr, obj, ...)                                \
      do {                                                                        \
        *ptr =                                                                    \
            Unwrap<typename node::remove_reference<decltype(**ptr)>::type>(obj);  \
        if (*ptr == nullptr)                                                      \
          return __VA_ARGS__;                                                     \
    } while (0)

So what would this look like after the preprocessor has processed it (need to double check this):

    do {
      *wrap = Unwrap<uv_stream_t>(obj);
      if (*wrap == nullptr)
         return;
    } while (0);


What does `__VA_ARGS__` do?   
I've seen this before with variadic methods in c, but not sure what it means to return it. Turns out that is you don't pass anything apart from the required arguments then the `return __VA_ARGS_ statement will just be `return;`. There are other places when the usage of this macro does pass additional arguments, for example: 

    ASSIGN_OR_RETURN_UNWRAP(&wrap,
                           args.Holder(),
                           args.GetReturnValue().Set(UV_EBADF));

    do {
      *wrap = Unwrap<uv_stream_t>(obj);
      if (*wrap == nullptr)
         return args.GetReturnValue.Set(UV_EBADF);
    } while (0);

So we will be returning early with a BADF (bad file descriptor) error.

### BaseObject

    inline BaseObject(Environment* env, v8::Local<v8::Object> handle);

I'm thinking that the handle is the Node representation of a libuv handle. 

    inline v8::Persistent<v8::Object>& persistent();

A persistent handle lives on the heap just like a local handle but it does not correspond
to C++ scopes. You have to explicitly call Persistent::Reset. 


### ReqWrap

    class ReqWrap : public AsyncWrap

cares_wrap.cc has a subclass named `GetAddrInfoReqWrap`
node_file.cc has a subclass named `FSReqWrap`
stream_base.cc has a subclass name `ShutDownWrap`
stream_base.cc has a subclass name `WriteWrap`
udp_wrap.cc has a subclass named `SendWrap` 
connect_wrap.cc has a subclass named 'ConnectWrap` which is subclassed by PipeWrap and TCPWrap.


### AsyncWrap
Some background about AsyncWrap can be found [here](https://github.com/nodejs/diagnostics/blob/master/tracing/AsyncWrap/README.md)
So using AsyncWrap we can have callbacks invoked during the life of handle objects. A handle object would for example e a TCPWrap
which extends ConnectionWrap -> StreamWrap -> HandleWrap.

Being a builtin module it follows the same initialization as others. So lets take a look at the initialization function and see
what kind of functions are made available from JavaScript:

    env->SetMethod(target, "setupHooks", SetupHooks);
    env->SetMethod(target, "disable", DisableHooksJS);
    env->SetMethod(target, "enable", EnableHooksJS);

You can confirm this by using:

    > var aw = process.binding('async_wrap')
    undefined
    > aw
    { setupHooks: [Function: setupHooks],
      disable: [Function: disable],
      enable: [Function: enable],
      Providers:
       { NONE: 0,
         CRYPTO: 1,
         FSEVENTWRAP: 2,
         FSREQWRAP: 3,
         GETADDRINFOREQWRAP: 4,
         GETNAMEINFOREQWRAP: 5,
         HTTPPARSER: 6,
         JSSTREAM: 7,
         PIPEWRAP: 8,
         PIPECONNECTWRAP: 9,
         PROCESSWRAP: 10,
         QUERYWRAP: 11,
         SHUTDOWNWRAP: 12,
         SIGNALWRAP: 13,
         STATWATCHER: 14,
         TCPWRAP: 15,
         TCPCONNECTWRAP: 16,
         TIMERWRAP: 17,
         TLSWRAP: 18,
         TTYWRAP: 19,
         UDPWRAP: 20,
         UDPSENDWRAP: 21,
         WRITEWRAP: 22,
         ZLIB: 23 
      } 
    } 

The first thing to do is setup the hooks by calling `setupHooks`:

    var aw = process.binding('async_wrap');
    let asyncHooksObject = {}
    qw.setupHooks(asyncHooksObject);

So AsyncWrap::SetupHooks takes a single object as its parameter. It expects this object to have 4 functions:


    init(uid, provider, parentUid, parentHandle)
    pre(uid)
    post(uid, didThrow)
    destroy(uid);

These functions (if they exist, there is only a check for that the init function actually exist and if the
others do not exist or are not functions then they are simply ignored).

    env->set_async_hooks_init_function(init_v.As<Function>());

So, if you are like me you might have gone searching for this `set_async_hooks_init_function` and not finding it. You
might recall this coming up [before](#environment\_strong\_persistent\_properties). So every environment will have such setters and getters for 
  
     V(async_hooks_destroy_function, v8::Function)                               
     V(async_hooks_init_function, v8::Function)                                  
     V(async_hooks_post_function, v8::Function)                                  
     V(async_hooks_pre_function, v8::Function)

So, we are setting a field named async_hooks_init_function_ in the current env.
An example of this usage might be:

    const asyncWrap = process.binding('async_wrap');
    let asyncObject = {
      init: function(uid, provider, parentUid, parentHandle) {
        process._rawDebug('init uid:', uid, ', provider:', provider);
      },
      pre: function(uid) {
        process._rawDebug('pre uid:', uid);
      },
      post: function(uid, didThrow) {
        process._rawDebug('post. uid:', uid, 'didThrow:', didThrow);
      },
      destroy: function(uid) {
        process._rawDebug('destroy: uid:', uid);
      }
    };

Alright, but when are these different functions called?  
`init` is called from AsyncWrap's constructor:

    Local<Function> init_fn = env->async_hooks_init_function();

So lets print the value of this function:

    (lldb) p _v8_internal_Print_Object(*(v8::internal::Object**)(*init_fn))
    0x17bdd44f0d91: [Function]
     - map = 0x359df9f06ea9 [FastProperties]
     - prototype = 0xe23ea883f39
     - elements = 0x28b309c02241 <FixedArray[0]> [FAST_HOLEY_ELEMENTS]
     - initial_map =
     - shared_info = 0x2a17ee0cda59 <SharedFunctionInfo init>
     - name = 0x807c31bd419 <String[4]: init>
     - formal_parameter_count = 4
     - context = 0x17bdd4483b31 <FixedArray[8]>
     - literals = 0x28b309c04a49 <FixedArray[1]>
     - code = 0xf3fbca04481 <Code: BUILTIN>
     - properties = {
       #length: 0x28b309c50bd9 <AccessorInfo> (accessor constant)
       #name: 0x28b309c50c49 <AccessorInfo> (accessor constant)
       #prototype: 0x28b309c50cb9 <AccessorInfo> (accessor constant)

### HandleWrap
HandleWrap represents a libuv handle which represents . Take the following functions:

    static void Close(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Ref(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Unref(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void HasRef(const v8::FunctionCallbackInfo<v8::Value>& args);

There are libuv counter parts for these in uv_handle_t:

    void uv_close(uv_handle_t* handle, uv_close_cb close_cb)
    void uv_ref(uv_handle_t* handle)
    void uv_unref(uv_handle_t* handle)
    int uv_has_ref(const uv_handle_t* handle)

Just like in libuv where uv_handle_t is a base type for all libuv handles, HandleWrap is a base class for all Node.js Wrap classes.

Every uv_handle_t can have a [data member](http://docs.libuv.org/en/v1.x/handle.html#c.uv_handle_t.data), and this is being set in the constructor to this instance of HandleWrap.
    
    handle__->data = this;
    HandleScope scope(env->isolate());
    Wrap(object, this);

In HandleWrap's constructor the HandleWrap is added to the queue of HandleWraps in the Environment:

    env->handle_wrap_queue()->PushBack(this);

libuv has the following types of handle types:

    #define UV_HANDLE_TYPE_MAP(XX)                                               \
     XX(ASYNC, async)                                                            \
     XX(CHECK, check)                                                            \
     XX(FS_EVENT, fs_event)                                                      \
     XX(FS_POLL, fs_poll)                                                        \
     XX(HANDLE, handle)                                                          \
     XX(IDLE, idle)                                                              \
     XX(NAMED_PIPE, pipe)                                                        \
     XX(POLL, poll)                                                              \
     XX(PREPARE, prepare)                                                        \
     XX(PROCESS, process)                                                        \
     XX(STREAM, stream)                                                          \
     XX(TCP, tcp)                                                                \
     XX(TIMER, timer)                                                            \
     XX(TTY, tty)                                                                \
     XX(UDP, udp)                                                                \
     XX(SIGNAL, signal)                                                          \ 


    struct uv_tcp_s {
      UV_HANDLE_FIELDS
      UV_STREAM_FIELDS
      UV_TCP_PRIVATE_FIELDS
    };

We know that TCPWrap is a built-in module and that it's Initialize method is called, which sets up all the prototype functions available, 
among them `listen`:

    env->SetProtoMethod(t, "listen", Listen);

And in `Listen` we find:

    int backlog = args[0]->Int32Value();
    int err = uv_listen(reinterpret_cast<uv_stream_t*>(&wrap->handle_),
                        backlog,
                        OnConnection);
    args.GetReturnValue().Set(err);


We can find a similarity in Node where TCPWrap indirectly also extends StreamWrap (which extends HandleWrap).

### Wrap

    template <typename TypeName>
    void Wrap(v8::Local<v8::Object> object, TypeName* pointer) {
     CHECK_EQ(false, object.IsEmpty());
     CHECK_GT(object->InternalFieldCount(), 0);
     object->SetAlignedPointerInInternalField(0, pointer);
    }

Here we can see that we are setting a pointer in field 0. The `object` in question, and `pointer` the pointer to this HandleWrap.

persistent().Reset will destroy the underlying storage cell if it is non-empty, and create a new one the handle.

MakeWeak:

     inline void MakeWeak(void) {
       persistent().SetWeak(this, WeakCallback, v8::WeakCallbackType::kParameter);
       persistent().MarkIndependent();
    }

The above is installing a finalization callback on the persistent object. Marking the persistent object as independant means that the GC is free to ignore object 
groups containing this persistent object. Why is this done? I don't know enough about the V8 GC yet to answer this.

The callback may be called (best effort) and it looks like this:

    static void WeakCallback(const v8::WeakCallbackInfo<ObjectWrap>& data) {
      ObjectWrap* wrap = data.GetParameter();
      assert(wrap->refs_ == 0);
      wrap->handle_.Reset();
      delete wrap;
    }


### TcpWrap
TcpWrap extends ConnectionWrap
Lets take a look at the creation of a TcpWrap:

    wrap = new TCPWrap(env, args.This(), nullptr);

What is args.This(). That will be the (v8::Local<v8::Object>) object that will be wrapped. 

This be passed to ConnectionWrap's constructor, which in turn will pass it to StreamWrap's constructor, which will pass it to HandleWrap's constructor, which will pass it to AsyncWrap's constructor, which will pass it to BaseObject's constructor which will set this/create a persistent object to store the handle:

    : persistent_handle_(env->isolate(), handle)

I've not seen this before, initializing a member with two parameters, and I cannot find a function that matches this signature. What is going on there?   
Well, the type of `persistent_handle_` is :

    v8::Persistent<v8::Object> persistent_handle_;

And the constructor for Persistent looks like this:

     template <class S>
     V8_INLINE Persistent(Isolate* isolate, Local<S> that)
        : PersistentBase<T>(PersistentBase<T>::New(isolate, *that)) {
      TYPE_CHECK(T, S);
    }


### IsolateData
Has a public constructor that takes a pointer to Isolate, a pointer to uv_loop_t, and a pointer to uint32 zero_fill_field.
An IsolateData instance also has a number of public methods:

    #define VP(PropertyName, StringValue) V(v8::Private, PropertyName, StringValue)
    #define VS(PropertyName, StringValue) V(v8::String, PropertyName, StringValue)
    #define V(TypeName, PropertyName, StringValue)                                \
      inline v8::Local<TypeName> PropertyName(v8::Isolate* isolate) const;
      PER_ISOLATE_PRIVATE_SYMBOL_PROPERTIES(VP)
      PER_ISOLATE_STRING_PROPERTIES(VS)
    #undef V
    #undef VS
    #undef VP

What is happening here is that we are declaring methods for each for the PER_ISOLATE_PRIVATE_SYMBOL_PROPERTIES. Since VP is being 
passed and the type for those methods is v8::Private there will be the following methods:

    v8::Local<Private> alpn_buffer_private_symbol(v8::Isolate* isolate) const;
    v8::Local<Private> arrow_message_private_symbol(v8::Isolate* isolate) const;
    ...
But what is the StringValue used for?  
The StringValue is actually not used here, see [#7905](https://github.com/nodejs/node/pull/7905) for details.

The StringValue is used in the definition though which can be found in src/env-inl.h:

    inline IsolateData::IsolateData(v8::Isolate* isolate, uv_loop_t* event_loop,
                                  uint32_t* zero_fill_field)
      :
    #define V(PropertyName, StringValue)                                          \
      PropertyName ## _(                                                        \
          isolate,                                                              \
          v8::Private::New(                                                     \
              isolate,                                                          \
              v8::String::NewFromOneByte(                                       \
                  isolate,                                                      \
                  reinterpret_cast<const uint8_t*>(StringValue),                \
                  v8::NewStringType::kInternalized,                             \
                  sizeof(StringValue) - 1).ToLocalChecked())),
    PER_ISOLATE_PRIVATE_SYMBOL_PROPERTIES(V)
    #undef V
    #define V(PropertyName, StringValue)                                          \
      PropertyName ## _(                                                        \
          isolate,                                                              \
          v8::String::NewFromOneByte(                                           \
              isolate,                                                          \
              reinterpret_cast<const uint8_t*>(StringValue),                    \
              v8::NewStringType::kInternalized,                                 \
              sizeof(StringValue) - 1).ToLocalChecked()),
      PER_ISOLATE_STRING_PROPERTIES(V)
    #undef V

This is the definition of the IsolateData constructor, and it is setting each of the private member fields
to the StringValue. I created an [example](https://github.com/danbev/learning-cpp11/blob/master/src/fundamentals/macros/macros.cc) to try this out. While it might not be easy on the eyes this does have a major advantage of not having to maintain all of these accessor methods. Adding a new one is simply a matter of adding an entry to the macro.

So now that we understand the macro, lets take a look at the actual information that this class stores/provides.  
All the property accessors defined above are available using he IsolateData instance but also they can be called using an Environment instance which just passes the calls through to the IsolateData instance.
The per isolate private members are the following:

    V(alpn_buffer_private_symbol, "node:alpnBuffer")
    V(npn_buffer_private_symbol, "node:npnBuffer")
    V(selected_npn_buffer_private_symbol, "node:selectedNpnBuffer")

The above are used by node_crypto.cc which makes sense as Application Level Protocol Negotiation (ALPN) is an TLS protocol, as it Next Prototol Negotiation (NPN).

    V(arrow_message_private_symbol, "node:arrowMessage")
Not sure exactly what this does but from a quick search it looks like it has to do with exception handling and printing of error messages. TODO: revisit this later.

An IsolateData (and also an Environement as it proxies these members) actually has a lot of members, too many to list here it is easy to do a search for them.


### Running lint

    $ make lint
    $ make jslint

### Running tests
To run the test use the following command:

    $ make -j4 test

The -j is the number of processes to use.

#### Mac firewall exceptions
On mac you might find it popping up dialogs about the firwall blocking access to the `node` and `cctest` applications when running
the tests. There is a script in `node/tools` that can run to add rules to the firewall:

    $ sudo tools/macosx-firewall.sh

### Running a script
This section attempts to explain the process of running a javascript file. We will create a break point in the javascript source and see how it is executed.
Lets take one of the tests and use it as an example:

    $ node-inspector

With newer versions of Node.js the V8 Inspector is now available from Node.js (https://github.com/nodejs/node/pull/6792) and can be started using:

    $ ./node --inspect --debug-brk

Next, start `lldb` and 

    $ lldb -- out/Debug/node --debug-brk test/parallel/test-tcp-wrap-connect.js

or with a newer version of Node.js use the built in V8 inspector:

    $ lldb -- out/Debug/node --inspect --debug-brk test/parallel/test-tcp-wrap-connect.js

Now, when a script is executed it will be read and loaded. Where is this done?
To recap the loading is done by `LoadEnvironment` which loads and executes `lib/internal/bootstrap_node.js`. This is a function which is
then executed:

    Local<Value> arg = env->process_object();
    f->Call(Null(env->isolate()), 1, &arg);

As we can see the process_object which was configured earlier is passed into the function:

    (function(process) {
      function startup() {
        ...
      }
      //other functions
      
      startup();
    });

We can see that the `startup` function will be called when the the `f` is called. Since we are specifying a script to run we will
be looking at setting up the various object in the environment, mosty using the passed in process object (TODO: need to write out the
details for this later) and eventually running:

     preloadModules();
     run(Module.runMain);

Module.runMain is a function in `lib/module.js`:

    // bootstrap main module.
    Module.runMain = function() {
      // Load the main module--the command line argument.
      Module._load(process.argv[1], null, true);
      // Handle any nextTicks added in the first tick of the program
      process._tickCallback();
    };

#### _load
Will check the module cache for the filename and if it already exists just returns the exports object for this module. But otherwise
the filename will be loaded using the file extension. Possible extensions are `.js`, `.json`, and `.node` (defaulting to .js if no extension is given).

    Module._extensions[extension](this, filename);

We know our extension is `.js` so lets look closer at it:

     // Native extension for .js
     Module._extensions['.js'] = function(module, filename) {
       var content = fs.readFileSync(filename, 'utf8');
       module._compile(internalModule.stripBOM(content), filename);
     };

So lets take a look at `_compile_`

#### module._compile
After removing the shebang from the `content` which is passed in as the first parameter the content is wrapped:

    var wrapper = Module.wrap(content);

    var compiledWrapper = vm.runInThisContext(wrapper, {
      filename: filename,
      lineOffset: 0,
      displayErrors: true
    });

vm.runInThisContext :

    var dirname = path.dirname(filename);
    var require = internalModule.makeRequireFunction.call(this);
    var args = [this.exports, require, this, filename, dirname];
    var depth = internalModule.requireDepth;
    if (depth === 0) stat.cache = new Map();
    var result = compiledWrapper.apply(this.exports, args);


#### Module.wrap
This is declared as:

    const NativeModule = require('native_module');
    ....
    Module.wrap = NativeModule.wrap;

NativeModule can be found lib/internal/bootstrap_node.js:

     NativeModule.wrap = function(script) {
       return NativeModule.wrapper[0] + script + NativeModule.wrapper[1];
     };

     NativeModule.wrapper = [
       '(function (exports, require, module, __filename, __dirname) { ',
       '\n});'
     ];

We can see here that the content of our JavaScript file will be included/wrapped in

    (function (exports, require, module, __filename, __dirname) { 
	// script content
    });'

So this is also how `exports`, `require`, `module`, `__filename`, and `__dirname` are made available
to all scripts.

So, to recap we have a `wrapper` instance that is a function. The next thing that happens in `lib/modules.js` is:

    var compiledWrapper = vm.runInThisContext(wrapper, {
      filename: filename,
      lineOffset: 0,
      displayErrors: true
    });

So what does `vm.runInThisContext` do?  
This is defined in `lib/vm.js`:

    exports.runInThisContext = function(code, options) {
      var script = new Script(code, options);
      return script.runInThisContext(options);
    };

As described in the [vm](https://nodejs.org/api/vm.html) the vm module provides APIs for compiling and running code within V8 Virtual Machine contexts.
Creating a new Script will compile but not run the code. It can later be run multiple times.

So what is a Script? 
It is declared as:

    const binding = process.binding('contextify');
    const Script = binding.ContextifyScript;

What is Contextify about?  
This is related to V8 contexts and all JavaScript code is run in a context.

`src/node_contextify.cc` is a builtin module and contains an `Init` function that does the following (among other things): 

    env->SetProtoMethod(script_tmpl, "runInContext", RunInContext);
    env->SetProtoMethod(script_tmpl, "runInThisContext", RunInThisContext);

script.runInThisContext in vm.js overrides `runInThisContext` and then delegates to src/node_contextify.cc `RunInThisContext`.

     // Do the eval within this context
     Environment* env = Environment::GetCurrent(args);
     EvalMachine(env, timeout, display_errors, break_on_sigint, args, &try_catch);

After all this processing is done we will be back in node.cc and continue processing there. As everything is event driven the event loop start running
and trigger callbacks for anything that has been set up by the script.
Just think about a V8 example you create yourself, you set up the c++ code that is to be called from JavaScript and then V8 takes care of the rest. 
In node, the script is first wrapped in node specific JavaScript and then executed.  Node code uses libuv there are callbacks setup that are called 
by libuv and more actions taken, like invoking a JavaScript callback function.

### EvalMachine

Script->Run in deps/v8/src/api.cc 

### Tasks

#### Remove need to specify a no-operation immediate_idle_handle
When calling setImmediate, this will schedule the callback passed in to be scheduled for execution after I/O events:

    setImmediate(function() {
	console.log("In immediate...");
    });

Currently this is done by using a libuv uv_check_handle. Since checks are performed after polling for I/O, if there 
are no idle handle or prepare handle (need to check this) then the I/O polling would block as there would be nothing
for the event loop to process until there is an I/O event. But if we have an idle handler there is something for the 
event loop to do which will cause the poll timeout to be zero and the event loop will not block on I/O.

In src/node.cc there is currently an empty uv_idle_handle callback (IdleImmediateDummy) for this which could be removed 
if it was possible to pass in a NULL callback. Currently there is a check in libuv checcing if the callback is null and this might not be able to change. 

My first idea was to overload the function but C does not suppport overloading, so perhaps having a new function named something like:

     uv_idle_start_nop(&handle)

Another option might be to make uv_idle_start an varargs function and if the only one argument is passed (not null but actually missing) then assume that a nop-callback. But looking into a variadic function there is no way to know when there if an argument was provided or not (of the optional arguments that is). 
Currently I'm only adding a function for uv_idle_start_nop to uv-common.c to try this out and see if I can get some feedback on a better place for this.

This task did not come to anything yet. Perhaps with libuv 2.0 libuv might accepts a null callback.


### tcp\_wrap and pipe\_wrap
Lets take a look at the following statement:

    var TCPConnectWrap = process.binding('tcp_wrap').TCPConnectWrap;
    var req = new TCPConnectWrap();
    
We know from before that `binding` is set as function on the process object. This was done in SetupProcessObject in node.cc:

    env->SetMethod(process, "binding", Binding);

So we are invoking the Binding function in node.cc with the argument 'tcp_wrap':

    static void Binding(const FunctionCallbackInfo<Value>& args) {

Binding will extract the first (and only) argument which is the name of the module. 
Every environment seems to have a cache, and if the module is in this cache it is returned:

    Local<Object> cache = env->binding_cache_object();

It will also create a instance of Local<Object> exports which is the object that will be returned.

    Local<Object> exports;

So, when the tcp_wrap.cc was Initialized (see section about Builtins):

    // Create FunctionTemplate for TCPConnectWrap.
    auto constructor = [](const FunctionCallbackInfo<Value>& args) {
      CHECK(args.IsConstructCall());
    };
    auto cwt = FunctionTemplate::New(env->isolate(), constructor);
    cwt->InstanceTemplate()->SetInternalFieldCount(1);
    cwt->SetClassName(FIXED_ONE_BYTE_STRING(env->isolate(), "TCPConnectWrap"));
    target->Set(FIXED_ONE_BYTE_STRING(env->isolate(), "TCPConnectWrap"), cwt->GetFunction());

What is going on here. We create a new FunctionTemplate using the `constructor` lamba, this is then added to the target (the object that we are initializing).
The constructor is only checking that the passed in args can be used as a constructor (using new in JavaScript)  
The object returned from the constructor call does not have any methods as far as I can tell. 
The constructor would late be used like this:

    var client = new TCP();
    var req = new TCPConnectWrap();
    var err = client.connect(req, '127.0.0.1', this.address().port);

Now, we saw that TCP has a bunch of methods set up in Initialize, one of the being connect:

    void TCPWrap::Connect(const FunctionCallbackInfo<Value>& args) {
      ...
      Local<Object> req_wrap_obj = args[0].As<Object>();

This is the instance of TCPConnectWrap `req` created above and we can see that it is of type `v8::Local<v8::Local>`.

    ConnectWrap* req_wrap = new ConnectWrap(env, req_wrap_obj, AsyncWrap::PROVIDER_TCPCONNECTWRAP);

Remember that ConnectnWrap extends ReqWrap which extends AsyncWrap

We know that ConnectWrap takes `Local<Object>` as the `req_wrap_obj`

    err = uv_tcp_connect(req_wrap->req(), &wrap->handle_, reinterpret_cast<const sockaddr*>(&addr), AfterConnect);

uv_tcp_connect takes a pointer `uv_connect_t` and a pointer to `uv_tcp_t` handle. This will connect to the specified `sockaddr_in` and the
callback will be called when the connection has been established or if an error occurs. So it makes sense that ConnectWrap extends ReqWrap
as uv_connect_t is a request type in libuv:

    /* Request types. */
    typedef struct uv_req_s uv_req_t;
    typedef struct uv_getaddrinfo_s uv_getaddrinfo_t;
    typedef struct uv_getnameinfo_s uv_getnameinfo_t;
    typedef struct uv_shutdown_s uv_shutdown_t;
    typedef struct uv_write_s uv_write_t;
    typedef struct uv_connect_s uv_connect_t;         <--------------------
    typedef struct uv_udp_send_s uv_udp_send_t;
    typedef struct uv_fs_s uv_fs_t;
    typedef struct uv_work_s uv_work_t;

AsyncWrap extends BaseObject which 

    (lldb) p *this
    (node::BaseObject) $28 = {
      persistent_handle_ = {
        v8::PersistentBase<v8::Object> = (val_ = 0x0000000105010c60)
      }
      env_ = 0x00007fff5fbfe108
    }

So each BaseObject instance has a v8::Persistent<v8:Object>. This is a persistent object as it needs to be preserved accross C++ function boundries.
Also, we can see that each BaseObject instance also has a node::Environment associated with it.
The only thing that BaseObject's constructor does (baseobject-inl-h) is :

    // The zero field holds a pointer to the handle. Immediately set it to
    // nullptr in case it's accessed by the user before construction is complete.
    if (handle->InternalFieldCount() > 0)
      handle->SetAlignedPointerInInternalField(0, nullptr);

So after we have returned to AsyncWraps constructor, and then ReqWrap's we are back in ConnectWrap's constructor:

    Wrap(req_wrap_obj, this);

`Wrap` in util-inl.h:

    template <typename TypeName>
    void Wrap(v8::Local<v8::Object> object, TypeName* pointer) {
      CHECK_EQ(false, object.IsEmpty());
      CHECK_GT(object->InternalFieldCount(), 0);
      object->SetAlignedPointerInInternalField(0, pointer);
    }

We are now setting index 0 to the pointer which is the current 
Object is the `v8::Local<v8::Object>`, the one we created in our JavaScript file and passed to the connect method named `req`:

    var req = new TCPConnectWrap();
    var err = client.connect(req, '127.0.0.1', this.address().port);

So we are setting/storing a pointer to the ConnectWrap instance at index 0 of the `req_wrap_obj`.

After all that we are ready to make the uv_tcp_connect call:

    err = uv_tcp_connect(req_wrap->req(), &wrap->handle_, reinterpret_cast<const sockaddr*>(&addr), AfterConnect);

We can see the callback is node::ConnectionWrap<node::TCPWrap, uv_tcp_s>::AfterConnect(uv_connect_s*, int)


Notice that target is of type Local<Object>. 

    Local<Object> exports;
    ....
    exports = Object::New(env->isolate());
    ...
    mod->nm_context_register_func(exports, unused, env->context(), mod->nm_priv);

exports is what is returned to the caller. 

    args.GetReturnValue().Set(exports);

And we access the TCPConnectWrap member, which is a function which can be used as 
a constructor by using new. Lets start with where is ConnectWrap called?
It is called from tcp_wrap.cc and its Connect method.
ConnectWrap extends ReqWrap which extends AsyncWrap which extens BaseObject

    req.oncomplete = function(status, client_, req_) {

So, we know from earlier that our `req` object is basically empty. Here we are setting a property name `oncomplete` to be
a function. This will be called in connection_wrap.cc 111:

    req_wrap->MakeCallback(env->oncomplete_string(), arraysize(argv), argv);

oncomplete_string() is a generated method from a macro in env.h

    v8::Local<v8::Value> cb_v = object()->Get(symbol);
    CHECK(cb_v->IsFunction());
    return MakeCallback(cb_v.As<v8::Function>(), argc, argv);

`object()` will return the persistent object to out handle (from base-object-inl.h) :

    return PersistentToLocal(env_->isolate(), persistent_handle_);

We can see that the `persistent_handle_` is the handle that was created using which makes sense as this 
is the object that oncomplete was created for:

    var req = new TCPConnectWrap();

We are then calling Get(symbol) which will be a Symbol representing 'oncomplete'. And the calling it with number of arguments, and the
arguments themselves.


### tcp\_wrap.cc
In `OnConnect` I found the following:

    TCPWrap* tcp_wrap = static_cast<TCPWrap*>(handle->data);
    ....
    Local<Object> client_obj = Instantiate(env, static_cast<AsyncWrap*>(tcp_wrap));

I'm not sure this cast is needed as we have already have a TCPWrap instance

    Local<Object> client_obj = Instantiate(env, tcp_wrap);
    
class TCPWrap : public StreamWrap
class StreamWrap : public HandleWrap, public StreamBase
class HandleWrap : public AsyncWrap {

As far as I can tell TCPWrap is of type AsyncWrap. Looking at src/pipe_wrap.cc which has a very similar OnConnect method
(which I'm going to take a stab at refactoring) but does not have this cast.


### Refactoring tcpwrap and pipewrap
// TODO(bnoordhuis) maybe share with TCPWrap?
This comment exist on pipewarp OnConnect


    void PipeWrap::OnConnection(uv_stream_t* handle, int status) {
    PipeWrap* pipe_wrap = static_cast<PipeWrap*>(handle->data);
    CHECK_EQ(&pipe_wrap->handle_, reinterpret_cast<uv_pipe_t*>(handle));

The reinterpret_cast operator changes one data type into another. Recall how the types of libuv have a type of c inheritance allowing 
casting.

    /*
     * uv_pipe_t is a subclass of uv_stream_t.
     *
     * Representing a pipe stream or pipe server. On Windows this is a Named
     * Pipe. On Unix this is a Unix domain socket.
     */
    struct uv_pipe_s {
      UV_HANDLE_FIELDS
      UV_STREAM_FIELDS
      int ipc; /* non-zero if this pipe is used for passing handles */
      UV_PIPE_PRIVATE_FIELDS
   };

The main difference that I've been able to find is in pipewrap `status` is checked:

    if (status != 0) {
      pipe_wrap->MakeCallback(env->onconnection_string(), arraysize(argv), argv);
      return;
   } 

### src/stream_wrap.cc
Looking into a task where the public member field req_ in src/req_wrap.cc is to be made private, I came accross the 
following method:

    286 void StreamWrap::AfterShutdown(uv_shutdown_t* req, int status) {
    287   ShutdownWrap* req_wrap = ContainerOf(&ShutdownWrap::req_, req);
    288   HandleScope scope(req_wrap->env()->isolate());
    289   Context::Scope context_scope(req_wrap->env()->context());
    290   req_wrap->Done(status);
    291 }

What I did for the public req_ member is made it private and then added a public accessor method for it. This was easy
to update in most places but in src/stream_wrap.cc we have the following line:

   ShutdownWrap* req_wrap = ContainerOf(&ShutdownWrap::req_, req);

    class StreamWrap : public HandleWrap, public StreamBase
    class HandleWrap : public AsyncWrap 
    class AsyncWrap : public BaseObject
    class BaseObject

## Extracting AfterConnect into connection_wrap.cc
Just like `OnConnect` was extracted into connection_wrap and shared by both tcp_wrap and pipe_wrap the same should be done for `AfterConnect`.

The main difference I found was in `PipeWrap::AfterConnect`:

    bool readable, writable;

    if (status) {
      readable = writable = 0;
    } else {
      readable = uv_is_readable(req->handle) != 0;
      writable = uv_is_writable(req->handle) != 0;
    } 
    Local<Object> req_wrap_obj = req_wrap->object();
    Local<Value> argv[5] = {
      Integer::New(env->isolate(), status),
      wrap->object(),
      req_wrap_obj,
      Boolean::New(env->isolate(), readable),
      Boolean::New(env->isolate(), writable)
    };

AfterConnect is a callback that is passed to uv_pipe_connect. The status will be 0 if uv_connect() was successful and < 0 otherwise. 

The thing to notice is the difference compared to tcp_wrap:

    Local<Object> req_wrap_obj = req_wrap->object();
    Local<Value> argv[5] = {
      Integer::New(env->isolate(), status),
      wrap->object(),
      req_wrap_obj,
      v8::True(env->isolate()),
      v8::True(env->isolate())
    };

TCPWrap always sets the readable and writable values to true where as PipeWrap checks if the handle is readble/writeble. Seems like a the TCPWrap will always
be both readable and writable. 


## Making ReqWrap req_ member private
Currently the member req_ is public in src/req

One issue when doing this was that after renaming req_ to req() I had to rename a macro in src/node_file.cc to avoid a collision with the macro 
parameter with the same name.

The second issue I ran into was with src/stream_wrap.cc:

    void StreamWrap::AfterShutdown(uv_shutdown_t* req, int status) {
      ShutdownWrap* req_wrap = ContainerOf(&ShutdownWrap::req_, req);

We can find `ContainerOf` in src/util-inl.h :

    template <typename Inner, typename Outer>
    inline ContainerOfHelper<Inner, Outer> ContainerOf(Inner Outer::*field, Inner* pointer) {
      return ContainerOfHelper<Inner, Outer>(field, pointer);
    }

The call in question is auto-deducing the paremeter types from the arguments, it could also have been explicit:

    ShutdownWrap* req_wrap = ContainerOf<uv_shutdown_t*, ShutdownWrap>(&ShutdownWrap::req_, req);


## ContainerOfHelper
src/util.h declares a class named ContainerOfHelper:

    // The helper is for doing safe downcasts from base types to derived types.
    template <typename Inner, typename Outer>
    class ContainerOfHelper {
     public:
       inline ContainerOfHelper(Inner Outer::*field, Inner* pointer);
       template <typename TypeName>
       inline operator TypeName*() const;
     private:
       Outer* const pointer_;
 };

So back to our call using ContainerOf which will invoke:

    template <typename Inner, typename Outer>
    ContainerOfHelper<Inner, Outer>::ContainerOfHelper(Inner Outer::*field, Inner* pointer)
        : pointer_(reinterpret_cast<Outer*>(reinterpret_cast<uintptr_t>(pointer) - reinterpret_cast<uintptr_t>(&(static_cast<Outer*>(0)->*field)))) {
    }

First, note that the parameter `field` is a pointer-to-member, which gives the offset of the member within the class object as opposed to using the
address-of operator on a data member bound to an actual class object which yields the member's actual address in memory.
`uintptr_t` is an unsigned int that is capable of storing a pointer. Such a type can be used when you need to perform integer operations on a pointer.
[reinterpret_cast](http://en.cppreference.com/w/cpp/language/reinterpret_cast) is a compiler directive which instructs the compiler to treat the sequence
of bits as if it had the new type:

    reinterpret_cast<uintptr_t>(pointer) 

reinterpret_cast is used to convert any pointer type to any other pointer type and the result is a binary copy of the value. 

        reinterpret_cast<uintptr_t>(&(static_cast<ShutdownWrap*>(0)->*field))

I've not seen this usage before using 0 as the argument to static_cast:

    static_cast<ShutdownWrap*>(0)->*field)

The static_cast part of this expression will give a nullptr, but we are not accessing a member, but a pointer-to-member which remember is the offset.
A pointer is only a memory address but the type of the object determines how a pointer can be used, like using a member it needs to know the offsets 
of those members.
So we creating a pointer to Outer which by using the offset of the field and substracting that from `pointer`. So when using a pointer and dereferencing 
`field` this will point to same value of `pointer`


Why does the protected field req_ have to be last:

    Command: out/Release/node /Users/danielbevenius/work/nodejs/node/test/parallel/test-child-process-stdio-big-write-end.js
    --- CRASHED (Signal: 10) ---
    === release test-cluster-disconnect ===
    Path: parallel/test-cluster-disconnect
    /Users/danielbevenius/work/nodejs/node/out/Release/node[84341]: ../src/connection_wrap.cc:83:static void node::ConnectionWrap<node::TCPWrap, uv_tcp_s>::AfterConnect(uv_connect_t *, int) [WrapType = node::TCPWrap, UVType = uv_tcp_s]: Assertion `(req_wrap->env()) == (wrap->env())' failed.
     1: node::Abort() [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     2: node::RunMicrotasks(v8::FunctionCallbackInfo<v8::Value> const&) [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     3: node::ConnectionWrap<node::TCPWrap, uv_tcp_s>::AfterConnect(uv_connect_s*, int) [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     4: uv__stream_io [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     5: uv__io_poll [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     6: uv_run [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     7: node::Start(int, char**) [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     8: start [/Users/danielbevenius/work/nodejs/node/out/Release/node]
     9: 0x2

"req_wrap_queue_ needs to be at a fixed offset from the start of the struct because it is used by ContainerOf to calculate the address of the embedding ReqWrap.
ContainerOf compiles down to simple, fixed pointer arithmetic. sizeof(req_) depends on the type of T, so req_wrap_queue_ would no longer be at a fixed offset if it came after req_."

This is what ReqWrap currently looks like:

     private:
      friend class Environment;
      ListNode<ReqWrap> req_wrap_queue_;

Notice that this is not a pointer and when a ReqWrap instance is created the ListNode::ListNode() constructor will be called:

    template <typename T>
    ListNode<T>::ListNode() : prev_(this), next_(this) {}

So every instance will have it's own doubly link linked list and each entry contains a ReqWrap instance which has a type T member. Depending on the type of T
the size of the ReqWrap object in memory will be different. So it would not be possible to have req_wrap_queue after req_, or req_ before req_wrap_queue as this
would make the offset different during runtime (compile time would still work fine).

Every Environment instance has the following queues:

    HandleWrapQueue handle_wrap_queue_;
    ReqWrapQueue req_wrap_queue_; 

And a typedef for this is created using a pointer-to-member: 

    typedef ListHead<ReqWrap<uv_req_t>, &ReqWrap<uv_req_t>::req_wrap_queue_> ReqWrapQueue;

Each time a instance of ReqWrap is created that instance will be added to the queue:

    env->req_wrap_queue()->PushBack(reinterpret_cast<ReqWrap<uv_req_t>*>(this));


### Share AfterWrite with with udp_wrap and stream_wrap 
So, the task is basically to follow this comment in udb_wrap.cc:

    // TODO(bnoordhuis) share with StreamWrap::AfterWrite() in stream_wrap.cc
    void UDPWrap::OnSend(uv_udp_send_t* req, int status) {

At first glance this don't look that similar that they could be shared:

     void UDPWrap::OnSend(uv_udp_send_t* req, int status) {
       SendWrap* req_wrap = static_cast<SendWrap*>(req->data);
       if (req_wrap->have_callback()) {
         Environment* env = req_wrap->env();
         HandleScope handle_scope(env->isolate());
         Context::Scope context_scope(env->context());
         Local<Value> arg[] = {
           Integer::New(env->isolate(), status),
           Integer::New(env->isolate(), req_wrap->msg_size),
         };
         req_wrap->MakeCallback(env->oncomplete_string(), 2, arg);
      }
      delete req_wrap;
    }

`have_callback()` is a method on the SendWrap class and does not exist for WriteWrap.

   void StreamWrap::AfterWrite(uv_write_t* req, int status) {
    WriteWrap* req_wrap = WriteWrap::from_req(req);
    CHECK_NE(req_wrap, nullptr);
    HandleScope scope(req_wrap->env()->isolate());
    Context::Scope context_scope(req_wrap->env()->context());
    req_wrap->Done(status);
  }

First thing to notice is the checking for a callback, StreamWrap::AfterWrite seems to assume that there will
always be a callback by looking at `req_wrap->Done`:

      inline void Done(int status, const char* error_str = nullptr) {
         Req* req = static_cast<Req*>(this);
         Environment* env = req->env();
         if (error_str != nullptr) {
           req->object()->Set(env->error_string(), OneByteString(env->isolate(), error_str));
         }
        cb_(req, status);
      }



When `DoShutdown` is called the last thing that is done is:

    req_wrap->Dispatched();

which will set req_.data = this; this being the Shutdown wrap instance. Later when the `AfterShutdown` method is called that instance will be available 
by using the req->data.


### Stream class hierarchy

    class TTYWrap : public StreamWrap

    class PipeWrap : public ConnectionWrap<PipeWrap, uv_pipe_t>
    class TCPWrap : public ConnectionWrap<TCPWrap, uv_tcp_t>
    
    class ConnectionWrap : public StreamWrap
    class StreamWrap : public HandleWrap, public StreamBase
    class HandleWrap : public AsyncWrap
    class AsyncWrap : public BaseObject
    class BaseObject

    class StreamBase : public StreamResource
    class StreamResource


### Wrapped 

    var TCP = process.binding('tcp_wrap').TCP;
    var TCPConnectWrap = process.binding('tcp_wrap').TCPConnectWrap;
    var ShutdownWrap = process.binding('stream_wrap').ShutdownWrap;

    var client = new TCP();
    var shutdownReq = new ShutdownWrap();

This above will invoke the constructor set up by TCPWrap::Initialize:

    auto constructor = [](const FunctionCallbackInfo<Value>& args) {
      CHECK(args.IsConstructCall());
    };
    auto cwt = FunctionTemplate::New(env->isolate(), constructor);
    cwt->InstanceTemplate()->SetInternalFieldCount(1);
    SetClassName(FIXED_ONE_BYTE_STRING(env->isolate(), "TCPConnectWrap"));
    Set(FIXED_ONE_BYTE_STRING(env->isolate(), "TCPConnectWrap"), GetFunction());

The only thing the constructor does is check that `new` is used with the function (as in new ShutdownWrap).

    var err = client.shutdown(shutdownReq);

The methods available to a TCP instance are also configured in TCPWrap::Initialize. The `shutdown` method is set up using the 
following call:

    StreamWrap::AddMethods(env, t, StreamBase::kFlagHasWritev);

`src/stream_base-inl.h` contains the shutdown method:

    env->SetProtoMethod(t, "shutdown", JSMethod<Base, &StreamBase::Shutdown>); 

So we are using a referece to StreamBase::Shutdown which can be found in src/stream_base.cc:

   int StreamBase::Shutdown(const FunctionCallbackInfo<Value>& args) {
     Environment* env = Environment::GetCurrent(args);
 
     CHECK(args[0]->IsObject());
     Local<Object> req_wrap_obj = args[0].As<Object>();

     ShutdownWrap* req_wrap = new ShutdownWrap(env,
                                               req_wrap_obj,
                                               this,
                                               AfterShutdown);

The Shutdown constructor delegates to ReqWrap:

    ReqWrap(env, req_wrap_obj, AsyncWrap::PROVIDER_SHUTDOWNWRAP),

Which delegates to AsyncWrap:

    AsyncWrap(env, req_wrap_obj, AsyncWrap::PROVIDER_SHUTDOWNWRAP),

Which delegates to BaseObject:

    BaseObject(env, req_wrap_obj)

req_wrap_obj is refered to handle in BaseObject and is made into a persistent V8 handle

`AfterShutdown` is of type typedef void (*DoneCb)(Req* req, int status). This callback is passed to the constructor of 
StreamReq:

    StreamReq<ShutdownWrap>(cb)

This will simply store the callback in a private field.

The `StreamBase` instance (`this` in the call above) will be set as a private member of Shutdown wrap.
There is a single function call in the constructor which is:

    Wrap(req_wrap_obj, this);

    void Wrap(v8::Local<v8::Object> object, TypeName* pointer) {
      CHECK_EQ(false, object.IsEmpty());
      CHECK_GT(object->InternalFieldCount(), 0);
      object->SetAlignedPointerInInternalField(0, pointer);
    }

So we are setting the ShutdownWrap instance pointer on the V8 local object. So wrap means that we are wrapping the ShutdownWrap instance
in the req_warp_obj.

## Compiling the test in this project
First step is that Google Test needs to be added. Follow the steps in "Adding Google test to the project" before proceeding.

### Building and running the tests

    make check 

### Clean

    make clean

## Adding Google test to the project

### Build the gtest lib:

    $ mkdir lib
    $ mkdir deps ; cd deps
    $ git clone git@github.com:google/googletest.git
    $ cd googletest/googletest
    $ mkdir build ; cd build
    $ c++ -std=gnu++0x -stdlib=libstdc++ -I`pwd`/../include -I`pwd`/../ -pthread -c `pwd`/../src/gtest-all.cc
    $ ar -rv libgtest.a gtest-all.o
    $ cp libgtest.a ../../../../lib

We will be linking against Node.js which is build (on mac) using c++ and using the GNU Standard library. 
Before OS X 10.9.x the default was libstdc++, but after OS X 10.9.x the default is libc++. I'm ususing 10.11.5 so the default would be libc++ in my case. I ran into an issue when compiling and not explicitely specifying `-stdlib=libstdc++` as this would mix two different standard library implementations. 
Instead of our program crashing at runtime we get a link time error. libc++ uses a C++11 language feature called inline namespace to change the ABI of std::string without impacting the API of std::string. That is, to you std::string looks the same. But to the linker, std::string is being mangled as if it is in namespace std::__1. Thus the linker knows that std::basic_string and std::__1::basic_string are two different data structures (the former coming from gcc's libstdc++ and the latter coming from libc++).

### Writing a test file

    $ mkdir test
    $ vi main.cc
    #include "gtest/gtest.h"
    #include "base-object_test.cc"

    int main(int argc, char* argv[]) {
      ::testing::InitGoogleTest(&argc, argv);
      return RUN_ALL_TESTS();
    }

    $ vi base-object_test.cc
    #include "gtest/gtest.h"

    TEST(BaseObject, base) {
    }

then compile using:

    $ clang++ -I`pwd`/../deps/googletest/googletest/include -pthread main.cc ../lib/libgtest.a -o base-object_test

Run the test:

    ./base-object_test


#### use of undeclared identifier 'node'
After making sure that I can include the 'base-object.h' header I get the following error when compiling:

    In file included from test/main.cc:2:
    test/base-object_test.cc:9:3: error: use of undeclared identifier 'node'
    node::BaseObject bo;
     ^
    1 error generated.
    make: *** [test/base-object_test] Error 1

After taking a closer look at `src/base-object.j` I noticed this line:

    #if defined(NODE_WANT_INTERNALS) && NODE_WANT_INTERNALS

I've not set this in the test, so there is not much being included by the preprocessor.
Adding `#define NODE_WANT_INTERNALS 1` should fix this.


#### Default implicit destructor
When working on a task involving extracting commmon code to a superclass I caused an issue
with the CI builds. 

What I had originally done was added an empty destructor:

    ~ConnectionWrap() {
    }

I later changed this to be an explicitly defaulted destructor generated by the compiler

    ~ConnectionWrap() = default;

While I did not see any failures on my local machine during development the CI server did. I currently don't have more information than this but will try to gather some.

My understanding/assumption was that these two would be equivalent. So what is doing on?
Let's start by taking a look a the inheritance tree and the various destructors:


    class ConnectionWrap : public StreamWrap
      protected:
        ~ConnectionWrap() {}

    class StreamWrap : public HandleWrap, public StreamBase
      protected:
        ~StreamWrap() { }

    class HandleWrap : public AsyncWrap
      protected:
        ~HandleWrap() override;

    class AsyncWrap : public BaseObject
      public:
        inline virtual ~AsyncWrap();

    class BaseObject
      public:
        inline virtual ~BaseObject();

    class StreamBase : public StreamResource
      public:
        virtual ~StreamBase() = default;

    class StreamResource
      public:
        virtual ~StreamResource() = default;

From looking at the error:

    In file included from ../src/pipe_wrap.h:7:0,
                 from ../src/pipe_wrap.cc:1:
    ../src/connection_wrap.h:26:3: internal compiler error: in use_thunk, at cp/method.c:338
    ~ConnectionWrap() = default;
    ^
    Please submit a full bug report,
   with preprocessed source if appropriate.
   See <file:///usr/share/doc/gcc-4.8/README.Bugs> for instructions.
   Preprocessed source stored into /tmp/ccvbqQz3.out file, please attach this to your bugreport.
   ERROR: Cannot create report: [Errno 17] File exists: '/var/crash/_usr_lib_gcc_x86_64-linux-gnu_4.8_cc1plus.1000.crash'
    make[2]: *** [/home/iojs/build/workspace/node-test-commit-linux/nodes/ubuntu1204-64/out/Release/obj.target/node/src/pipe_wrap.o] Error 1

it looks like GCC (G++) 4.8 is being used. The reason for asking is I did a search and found a few indications that this might be a bug in the compiler. This is reported as sovled in 4.8.3 which is also why I'm curious about the compiler version. The centos machines use devtoolset-2, which comes with g++ 4.8.2.

If a class has no user-declared destructor, one is declared implicitly by the compiler and is called an implicitly-declared destructor. An implicitly-declared destructor is inline.
Another aspect about destructors that is important to understand is that even if the body of a destructor is empty, it doesn’t mean that this destructor won’t execute any code. The C++ compiler augments the destructor with calls to destructors for bases and non-static data members


### Chrome debugger
Open developer tools from Chrome `CMD+OPT+I`

#### Debugging
`CMD+;`         step into  
`CMD+'`         step over  
`CMD+SHIFT+;`   step out  
`CMD+\`         continue  
`CTRL+.`        next call frame  
`CTRL+,`        previous call frame  
`CMD+B`         toggle breakpoint  
`CTRL+SHIFT+E`  run highlighted snipped and show output in console.  

#### Searching
`CMD+F`         search current file  
`CMD+ALT+F`     search all sources  
`CMD+P`         go to source file. Opens a dialog where you can type in a file name  
`CTRL+G`        go to line  

#### Editor
`SHIFT+CMD+P`   go to member  
`CMD+P`         open file  
`CMD+OPT+F`     search all files
  
`ESC`           toggle drawer  
`CTRL+~`        jump to console  
`CMD+[`         next panel  
`CMD+]`         previous panel  
`CMD+ALT+[`     next panel in history  
`CMD+ALT+]`     previous panel history  
`CMD+SHIFT+D`   toggle location of panels (separate screen/docked)  
`?`             show settings dialog  
                You can see all the shortcuts from here    
`ESC`           close settings/dialog  


### Node Package Manager (NPM) 
I was curious about what type of program it is. Looking at the shell script on my machine it is a simple wrapper that calls node with the javascript file being the shell script itself. Kinda like doing:

    #!/bin/sh
    // 2>/dev/null; exec "`dirname "~/.nvm/versions/node/v4.4.3/bin/npm"`/node" "$0" "$@"

    console.log("bajja");

### Make
GNU make has two phases. During the first phase it reads all the makefiles, and internalizes all variables. Make will expand any variables or functions in that section as the makefile is parsed. This is called
immediate expansion since this happens during the first phase. The expansion is called deferred if it is not performed immediately.

Take a look at this rule:

    config.gypi: configure
        if [ -f $@ ]; then
                $(error Stale $@, please re-run ./configure)
        else
                $(error No $@, please run ./configure first)
        fi

The recipe in this case is a shell if statement, which is a deferred construct. But the control function `$(error)` is an immediate construct which will cause the makefile processing to stop processing.
If I understand this correctly the only possible outcome of this rule is the Stale config.gypi message which will be done in the first phase and then exit. The shell condition will not be considered.

For example, if we delete `config.gypi` we would expect the result to be an error saying that `No config.gypi, please run ./configure first`. But the result is:

    Makefile:81: *** Stale config.gypi, please re-run ./configure.  Stop.

Keep in mind that `config.gypi` is not a .PHONY target, so it is a file on the file system and if it is missing the recipe will be run.
So we could use a simple echo statement and and exit to work around this:

    config.gypi: configure
        @if [ -f $@ ]; then \
          echo Stale $@, please re-run ./$<; \
        else \
          echo No $@, please run ./$< first; \
        fi
        @exit 1;

But that will produce the kind of ugly result:

    $ make config.gypi
    Stale config.gypi, please re-run ./configure
    make: *** [config.gypi] Error 1


### AtExit
    // TODO(bnoordhuis) Turn into per-context event.
    4278 void RunAtExit(Environment* env) {


What exactly is a AtExit function. An "AtExit" hook is a function that is invoked after the Node.js event loop has ended but before the JavaScript VM is terminated and Node.js shuts down.

So in node.cc you can find:

    void AtExit(void (*cb)(void* arg), void* arg) {

This would be called like this:

    static void callback(void* arg) {
    }

    AtExit(callback);

    static AtExitCallback* at_exit_functions_;

I notices that AtExist is declared in node.h:

    NODE_EXTERN void RunAtExit(Environment* env);

`NODE_EXTERN` is declared as:

So the idea is that at_exit_functions_ should be a per-environment property rather than a global.
Like bnoordhuis pointed out, AtExit does not take a pointer to an Environment but we have to add the callbacks to the Environment
associated with the addon.
Is the environemnt available when the addons init function is called?  

To answer that question, what is the type contained in the init function of an addon?  

    void init(Local<Object> target) {
      AtExit(at_exit_cb1, target->CreationContext()->GetIsolate());
    }
 
    NODE_MODULE(binding, init);

So a user will still have to call AtExit but instead of node.cc holding a static linked list of callbacks to call these should be
added to the current environment.

    void AtExit(void (*cb)(void* arg), void* arg) {

So AtExit takes a function pointer as its first argument, and a void pointer as its second.
The function pointer is to a function that returns void and takes a void pointer as an argument.

mp->nm_register_func(exports, module, mp->nm_priv);

The above call can be found in `DLOpen` in src/node.cc`. The first thing that happens in DLOpen is:

    Environment* env = Environment::GetCurrent(args);

I've covered the setting of the Environment in `AssignToContext` previously. This is done by the Environment contructor and by 
node_contextify.cc. 


The only `Start` function exposed in node.h is the one that takes `argc` and `argv`. Calling node::Start multiple times does
not work and result in the following error:

# Fatal error in ../deps/v8/src/isolate.cc, line 2021
# Check failed: thread_data_table_.
#
==== C stack trace ===============================

    0   cctest                              0x0000000100324fce v8::base::debug::StackTrace::StackTrace() + 30
    1   cctest                              0x0000000100325005 v8::base::debug::StackTrace::StackTrace() + 21
    2   cctest                              0x000000010031dd94 V8_Fatal + 452
    3   cctest                              0x0000000100cc053c v8::internal::Isolate::Isolate(bool) + 2092
    4   cctest                              0x0000000100cc0ad5 v8::internal::Isolate::Isolate(bool) + 37
    5   cctest                              0x0000000100370a59 v8::Isolate::New(v8::Isolate::CreateParams const&) + 41
    6   cctest                              0x000000010003323f node::Start(uv_loop_s*, int, char const* const*, int, char const* const*) + 79
    7   cctest                              0x0000000100032e38 node::Start(int, char**) + 200
    8   cctest                              0x00000001000cdb33 EnvironmentTest_StartMultipleTimes_Test::TestBody() + 51
    9   cctest                              0x000000010014089a void testing::internal::HandleSehExceptionsInMethodIfSupported<testing::Test, void>(testing::Test*, void (testing::Test::*)(), char const*) + 122
    10  cctest                              0x00000001001190be void testing::internal::HandleExceptionsInMethodIfSupported<testing::Test, void>(testing::Test*, void (testing::Test::*)(), char const*) + 110
    11  cctest                              0x0000000100118fa5 testing::Test::Run() + 197
    12  cctest                              0x0000000100119f98 testing::TestInfo::Run() + 216
    13  cctest                              0x000000010011b227 testing::TestCase::Run() + 231
    14  cctest                              0x0000000100129ccc testing::internal::UnitTestImpl::RunAllTests() + 908
    15  cctest                              0x00000001001444aa bool testing::internal::HandleSehExceptionsInMethodIfSupported<testing::internal::UnitTestImpl, bool>(testing::internal::UnitTestImpl*, bool (testing::internal::UnitTestImpl::*)(), char const*) + 122
    16  cctest                              0x00000001001298be bool testing::internal::HandleExceptionsInMethodIfSupported<testing::internal::UnitTestImpl, bool>(testing::internal::UnitTestImpl*, bool (testing::internal::UnitTestImpl::*)(), char const*) + 110
    17  cctest                              0x00000001001297b5 testing::UnitTest::Run() + 373
    18  cctest                              0x0000000100147a81 RUN_ALL_TESTS() + 17
    19  cctest                              0x0000000100147a5b main + 43
    20  cctest                              0x00000001000010f4 start + 52
make: *** [cctest] Illegal instruction: 4

The Environment created when using the above start function is done in

    inline int Start(Isolate* isolate, IsolateData* isolate_data,
                     int argc, const char* const* argv,
                     int exec_argc, const char* const* exec_argv) {


Would it be safe to use GetCurrent using the isolate in 



### Thread-local

    static thread_local Environment* thread_local_env;

The object is allocated when the thread begins and deallocated when the thread ends. Each thread has its own instance of the object. 
Only objects declared thread_local have this storage duration.  thread_local can appear together with static or extern to adjust linkage.

So we are specifying static only to specify that it should only have internal linkage, meaning that it can be referred to from all scopes in the current translation unit. It does not 
mean that it is static as in "static storage" meaning that it would be allocated when the program begins and deallocated when the program ends.
But without the static linkage it would be external by default which is not what we want.

When used in a declaration of an object, it specifies static storage duration (except if accompanied by thread_local). When used in a declaration at 
namespace scope, it specifies internal linkage.


Using a `while(more == true)' :
    0x1011d81a9 <+1177>: jmp    0x1011d81ae               ; <+1182> at node.cc:4453
    0x1011d81ae <+1182>: movb   -0xd31(%rbp), %al         ; move byte value of -0xd31(%rpb) (move variable) into al register
    0x1011d81b4 <+1188>: andb   $0x1, %al                 ; AND 1 and the content of move variable
    0x1011d81b6 <+1190>: movzbl %al, %ecx                 ; conditional move into eax if zero
    0x1011d81b9 <+1193>: cmpl   $0x1, %ecx                ; compare 1 and the contents of eax
    0x1011d81bc <+1196>: je     0x1011d80e9               ; <+985> at node.cc:4437

    0x1011d81c2 <+1202>: leaq   -0xd30(%rbp), %rdi
    0x1011d81c9 <+1209>: callq  0x1002214e0               ; v8::SealHandleScope::~SealHandleScope at api.cc:926


Compared to using `while(more)`:

    0x1011d81a9 <+1177>: jmp    0x1011d81ae               ; <+1182> at node.cc:4453
    0x1011d81ae <+1182>: testb  $0x1, -0xd31(%rbp)        ; AND 1 and more
    0x1011d81b5 <+1189>: jne    0x1011d80e9               ; <+985> at node.cc:4437

    0x1011d81bb <+1195>: leaq   -0xd30(%rbp), %rdi
    0x1011d81c2 <+1202>: callq  0x1002214e0               ; v8::SealHandleScope::~SealHandleScope at api.cc:926


#### Calling conventions
Are the rules when making functions calls regarding how parameters are passed, who is responsible for cleaning up the stack, 
how the return value is to be retrieved, and also how the function calls are decorated.

### cdecl
A calling convention that is used for standard C where the the stack must be cleaned up by the callee as there is support for varargs
and there is now way for the called function to know the actual number of values pushed onto the stack before the function was called.
Function name is decorated by prefixing it with an underscore character '_' .

### stdcall
Here arguments are fixed and the called function can to the stack clean up. The advantage here is that the stack clean up code is only
done once in one place.
Function name is decorated by prepending an underscore character and appending a '@' character and the number of bytes of stack space required.

### Issue
When running the Node.js build on windows (trying to get cctest to work for a test I added), I got the following link error:

    env.obj : error LNK2001: unresolved external symbol 
    "public: __cdecl node::Utf8Value::Utf8Value(class v8::Isolate *,class v8::Local<class v8::Value>)" (??0Utf8Value@node@@QEAA@PEAVIsolate@v8@@V?$Local@VValue@v8@@@3@@Z) [c:\workspace\node-compile-windows\label\win-vs2015\cctest.vcxproj]

Now, we can see that the calling convention used is `__cdecl` but the name mangling does not look correct as it is using @@



    process_title.len = argv[argc - 1] + strlen(argv[argc - 1]) - argv[0];

This would be the same as :

    (lldb) p (size_t) argv[argc-1] + (size_t) strlen(argv[argc-1]) - (size_t)argv[0]
    (unsigned long) $9 = 56

When in my unit test the same gives me:

    (lldb) p (size_t) argv[argc-1] + (size_t) strlen(argv[argc-1]) - (size_t)argv[0]
    (unsigned long) $10 = 34693

What is happening is that we are taking the memory address of argv[argc-1] + 

#### Debugging a Node addon
The task a hand was to debug Realm's addon to see why test were just hanging even though I made sure to call Tape test's end function.
So, realm is a normal dependency and exist in node_modules.

Setup:

    $ npm install --save realm
    $ cd node_modules/realm
    $ env REALMJS_USE_DEBUG_CORE=true node-pre-gyp install --build-from-source --debug
    $ lldb -- node test/datastores/realm-store-test.js
    (lldb) breakpoint set --file node_init.cpp --line 26

It turns out that when breaking in the debugger (CTRL+C) and then stepping through it was in a kevent and this migth be some kind of
listerner for events, and there is a realm.removeAllListeners() that can be called and this solved my issue.


### Generate Your Project
For node the various targets in node.gyp will generate make files in the `out` directory.
For example the target named `cctest` will generate out/cctest.target.mk file.

### Profiling
You can use Google V8's built in profiler using the `--prof` command line option:

    $ out/Debug/node --prof test.js


This will generate a file in the current directory named something like `isolate-0x104005e00-v8.log`.
Now we can process this file:

    $ export D8_PATH=~/work/google/javascript/v8/out/x64.debug
    $ deps/v8/tools/mac-tick-processor isolate-0x104005e00-v8.log

or you can use node's `---prof-process` option:

    $ ./out/Debug/node --prof-process isolate-0x104005e00-v8.log

    Statistical profiling result from isolate-0x104005e00-v8.log, (332 ticks, 86 unaccounted, 0 excluded).


The profiler is sample based so with wakes up and takes a sample. The intervals that is wakes up is called a tick. It will look
at where the instruction pointer is RIP and reports the function if that function can be resolved. If cannot resolve the function
this will be reported as an unaccounted tick.

    [Summary]:
     ticks  total  nonlib   name
        0    0.0%    0.0%  JavaScript
      236   71.1%   73.3%  C++
        4    1.2%    1.2%  GC
       10    3.0%          Shared libraries
       86   25.9%          Unaccounted

We can see that `71.1%` of the time was spent in C++ code. Inspecting the C++ section you should be able to see were the most
time is being spent and the sources.


    [C++]:
     ticks  total  nonlib   name
       66   19.9%   20.5%  node::ContextifyScript::New(v8::FunctionCallbackInfo<v8::Value> const&)
       20    6.0%    6.2%  node::Binding(v8::FunctionCallbackInfo<v8::Value> const&)
        5    1.5%    1.6%  v8::internal::HandleScope::ZapRange(v8::internal::Object**, v8::internal::Object**)

The `[Bottom up]` section shows us which the primary callers of the above are:


    [Bottom up (heavy) profile]:
    Note: percentage shows a share of a particular caller in the total amount of its parent calls.
    Callers occupying less than 2.0% are not shown.

     ticks parent  name
       86   25.9%  UNKNOWN

       66   19.9%  node::ContextifyScript::New(v8::FunctionCallbackInfo<v8::Value> const&)
       66  100.0%    v8::internal::Builtin_HandleApiCall(int, v8::internal::Object**, v8::internal::Isolate*)
       66  100.0%      LazyCompile: ~runInThisContext bootstrap_node.js:427:28
       66  100.0%        LazyCompile: ~NativeModule.compile bootstrap_node.js:509:44
       66  100.0%          LazyCompile: ~NativeModule.require bootstrap_node.js:443:34
       15   22.7%            LazyCompile: ~startup bootstrap_node.js:12:19
       11   16.7%            Function: ~<anonymous> module.js:1:11
        8   12.1%            Function: ~<anonymous> stream.js:1:11
        7   10.6%            LazyCompile: ~setupGlobalVariables bootstrap_node.js:192:32
        6    9.1%            Function: ~<anonymous> util.js:1:11
        6    9.1%            Function: ~<anonymous> tty.js:1:11
        3    4.5%            LazyCompile: ~setupGlobalTimeouts bootstrap_node.js:226:31
        2    3.0%            LazyCompile: ~createWritableStdioStream internal/process/stdio.js:134:35
        2    3.0%            Function: ~<anonymous> fs.js:1:11
        2    3.0%            Function: ~<anonymous> buffer.js:1:11

LazyCompile: Simply means that the function was complied lazily and not that this was the time spent compiling.
* before function name means that time is being spent in optimized function.
~ before a function means that is was not optimized.

The % in the parent column shows the percentage of samples for which the function in the row above was called by the
function in the current row.
So, 

       66   19.9%  node::ContextifyScript::New(v8::FunctionCallbackInfo<v8::Value> const&)
       66  100.0%    v8::internal::Builtin_HandleApiCall(int, v8::internal::Object**, v8::internal::Isolate*)

would be read as when `v8::internal::Builting_HandleApiCall` was sampled it called node:ContextifyScript every time.
And

       66  100.0%          LazyCompile: ~NativeModule.require bootstrap_node.js:443:34
       15   22.7%            LazyCompile: ~startup bootstrap_node.js:12:19
that when startup in bootstrap_node.js was called, in 22% of the samples it called NativeModule.require.


    [Shared libraries]:
     ticks  total  nonlib   name
        6    1.8%          /usr/lib/system/libsystem_kernel.dylib
        2    0.6%          /usr/lib/system/libsystem_platform.dylib
        1    0.3%          /usr/lib/system/libsystem_malloc.dylib
        1    0.3%          /usr/lib/system/libsystem_c.dylib



### setTimeout

Let's take the following example:

    setTimeout(function () {
      console.log('bajja');
    }, 5000);

    $ ./out/Debug/node --inspect --debug-brk settimeout.js

In Node you can call setTimeout with out having a require. This is done by lib/boostrap_node.js:

    function setupGlobalTimeouts() {
      const timers = NativeModule.require('timers');
      global.clearImmediate = timers.clearImmediate;
      global.clearInterval = timers.clearInterval;
      global.clearTimeout = timers.clearTimeout;
      global.setImmediate = timers.setImmediate;
      global.setInterval = timers.setInterval;
      global.setTimeout = timers.setTimeout;
   }

So we can see that we are able to call setTimout without having to require any module and that it is part of a
native modules named timers. This is located in lib/timers.js.

The first thing that will happen is a new Timeout will be created in `createSingleTimeout`. A timeout looks like:

    function Timeout(after, callback, args) {
      this._called = false;
      this._idleTimeout = after;  // this will be 5000 in our use-case
      this._idlePrev = this;
      this._idleNext = this;
      this._idleStart = null;
      this._onTimeout = callback; // this is our callback that just logs to the console
      this._timerArgs = args;
      this._repeat = null;
    }

This `timer` instance is then passed to `active(timer)` which will insert the timer by calling `insert`:

     insert(item, false);

(`item` is the timer, and false is the value of the unrefed argument)

    item._idleStart = TimerWrap.now();

So we can see that we are using timer_wrap which is located in src/timer_wrap.cc and the now function which is 
initialized to:

    env->SetTemplateMethod(constructor, "now", Now);

Back in the insert function we then have the following:

    const lists = unrefed === true ? unrefedLists : refedLists;

We know that unrefed is false so lists will be the refedLists which is an object keyed with the millisecond that a timeout is due
to expire. The value of each key is a linkedlist of timers that expire at the same time. 

    var list = lists[msecs];

If there are other timers that also expire after 5000ms then there might already be a list for them. But in this case there is not
and a new list will be created:

    lists[msecs] = list = createTimersList(msecs, unrefed);

    const list = new TimersList(msecs, unrefed); // 5000 and false

    function TimersList(msecs, unrefed) {
      this._idleNext = null; // Create the list with the linkedlist properties to
      this._idlePrev = null; // prevent any unnecessary hidden class changes.
      this._timer = new TimerWrap();
      this._unrefed = unrefed; // will be false in our case
      this.msecs = msecs; // will be 5000 in our case
   }

The `new TimerWrap` call will invoke `New` in timer_wrap.cc as setup in the initialize function:

    Local<FunctionTemplate> constructor = env->NewFunctionTemplate(New);

`New` will invoke TimerWrap's constructor which does:

    int r = uv_timer_init(env->event_loop(), &handle_);

So we can see that it is setting up a libuv [timer](https://github.com/danbev/learning-libuv/blob/master/timer.c).
Shortly after we have the following code (back in JavaScript land and lib/timers.js):

Next the list (TimerList) is initialized setting _idleNext and _idlePrev to list. After this we are adding
a field to the list:

    list._timer._list = list;

    list._timer.start(msecs);

Start is initialized using :

    env->SetProtoMethod(constructor, "start", Start);

    static void Start(const FunctionCallbackInfo<Value>& args) {
      TimerWrap* wrap = Unwrap<TimerWrap>(args.Holder());

      CHECK(HandleWrap::IsAlive(wrap));

      int64_t timeout = args[0]->IntegerValue();
      int err = uv_timer_start(&wrap->handle_, OnTimeout, timeout, 0);
      args.GetReturnValue().Set(err);
   }

Compare this with [timer.c](https://github.com/danbev/learning-libuv/blob/master/timer.c). and you can see that these is not
that much of a difference. Let's look at the callback OnTimeout:

    static void OnTimeout(uv_timer_t* handle) {
      TimerWrap* wrap = static_cast<TimerWrap*>(handle->data);
      Environment* env = wrap->env();
      HandleScope handle_scope(env->isolate());
      Context::Scope context_scope(env->context());
      wrap->MakeCallback(kOnTimeout, 0, nullptr);
    }

The callback in question looks like:

    0xa90abea6961: [Function]
     - map = 0x2fecee786da1 [FastProperties]
     - prototype = 0x1b3829484539
     - elements = 0x2203fd302241 <FixedArray[0]> [FAST_HOLEY_ELEMENTS]
     - initial_map =
     - shared_info = 0x28b2bad27aa1 <SharedFunctionInfo listOnTimeout>
     - name = 0x28b2bad26b31 <String[13]: listOnTimeout>
     - formal_parameter_count = 0
     - context = 0x19bfe9663951 <FixedArray[48]>
     - feedback vector cell = 0x28b2bad2a549 <Cell value= 0x2203fd302311 <undefined>>
     - code = 0x26d0e2004941 <Code BUILTIN>
     - properties = 0x2203fd302241 <FixedArray[0]> {
        #length: 0x35bd747eed51 <AccessorInfo> (const accessor descriptor)
        #name: 0x35bd747eedc1 <AccessorInfo> (const accessor descriptor)
        #prototype: 0x35bd747eee31 <AccessorInfo> (const accessor descriptor)
     }

Notice that the callback is `listOnTimeout` and this can be found in lib/timer.js.

### setImmediate
The very simple JavaScript looks like this:

    setImmediate(function () {
      console.log('bajja');
    });

Like setTimeout the implementation is found in lib/timers.js. 
A new Immediate will be created in `createImmediate` which looks like this:

    function Immediate() {
      // assigning the callback here can cause optimize/deoptimize thrashing
      // so have caller annotate the object (node v6.0.0, v8 5.0.71.35)
      this._idleNext = null;
      this._idlePrev = null;
      this._callback = null;
      this._argv = null;
      this._onImmediate = null;
      this.domain = process.domain;
    }

The following check will then be done:

    if (!process._needImmediateCallback) {
      process._needImmediateCallback = true;
      process._immediateCallback = processImmediate;
    }

In this case `process._needImmediateCallback` is false so we'll enter the above block and set process._needImmediateCallback
to `true`. 

Also, notice that we are setting the processImmediate instance as a member of the process object. 
`processImmediate` is a function defined in timer.js. There is a V8 accessor for the field `_immediateCallback` on the process object which is set up in node.cc (SetupProcessObject function):

    auto need_immediate_callback_string =
        FIXED_ONE_BYTE_STRING(env->isolate(), "_needImmediateCallback");
    CHECK(process->SetAccessor(env->context(), need_immediate_callback_string,
                               NeedImmediateCallbackGetter,
                               NeedImmediateCallbackSetter,
                               env->as_external()).FromJust());

So when we do `process_.immediateCallback` `NeedImmediateCallbackSetter` will be invoked.
Looking closer at this function and comparing it with a [libuv check example](https://github.com/danbev/learning-libuv/blob/master/check.c) we should see some similarties.

    uv_check_t* immediate_check_handle = env->immediate_check_handle();

    uv_idle_t* immediate_idle_handle = env->immediate_idle_handle();

    uv_check_start(immediate_check_handle, CheckImmediate);
    // Idle handle is needed only to stop the event loop from blocking in poll.
    uv_idle_start(immediate_idle_handle, IdleImmediateDummy);

So we can see that when this setter is called it will set up check handle (if the value
was true as in `process._needImmediateCallback = true`).
When the check phase is reached the `CheckImmediate` callback will be invoked. Lets set a breakpoint in that function and verify this:

    (lldb) breakpoint set --file node.cc --line 286 

    static void CheckImmediate(uv_check_t* handle) {
      Environment* env = Environment::from_immediate_check_handle(handle);
      HandleScope scope(env->isolate());
      Context::Scope context_scope(env->context());
      MakeCallback(env, env->process_object(), env->immediate_callback_string());
    }

Following `MakeCallback` will will find ourselves in timers.js and its `processImmediate` function which you might recall that we set:

     process._immediateCallback = processImmediate;

     immediate._callback = immediate._onImmediate;

`immediate._onImmediate` will be our callback function (anonymous in setimmediate.js)

    tryOnImmediate(immediate, tail);

will call:

    runCallback(immediate);

will call:

    return timer._callback();

And the callback is:

    function () {
       console.log('bajja');
    }

And there we have how setImmediate works in Node.js.

### process._nextTick
The very simple JavaScript looks like this:

    process.nextTick(function () {
      console.log('bajja');
    });

`nextTick` is defined in `lib/internal/process/next_tick.js`.
After a few checks what happens is that the callback is added to the nextTickQueue:

    nextTickQueue.push({
      callback,
      domain: process.domain || null,
      args
    });

`nextTickQueue` is an array:

    var nextTickQueue = [];

And we are pushing an object with the callback as a function named callback, domain
and args. So for every nextTick called an entry will be added to the queue. 

    tickInfo[kLength]++;

Recall that TickInfo is an inner class of Environment. Lets back up a little. `bootstrap_node.js` will call next_tick's setup() function from its start function:

    NativeModule.require('internal/process/next_tick').setup();

    exports.setup = setupNextTick;

    var microtasksScheduled = false;

    // Used to run V8's micro task queue.
    var _runMicrotasks = {};

    // *Must* match Environment::TickInfo::Fields in src/env.h.
    var kIndex = 0;
    var kLength = 1;

    process.nextTick = nextTick;
    // Needs to be accessible from beyond this scope.
    process._tickCallback = _tickCallback;
    process._tickDomainCallback = _tickDomainCallback;

    // This tickInfo thing is used so that the C++ code in src/node.cc
    // can have easy access to our nextTick state, and avoid unnecessary
    // calls into JS land.
    const tickInfo = process._setupNextTick(_tickCallback, _runMicrotasks);

`process._setupNextTick` is initialized in `SetupProcessObject` in src/node.cc:

    env->SetMethod(process, "_setupNextTick", SetupNextTick);

Lets take a look at what SetupNextTick does...

    env->set_tick_callback_function(args[0].As<Function>());

    env->SetMethod(args[1].As<Object>(), "runMicrotasks", RunMicrotasks);

So, here we are setting a method named `runMicrotasks` on the `_runMicrotasks` object
passed to `_setupNextTick`.

    // Do a little housekeeping.
    env->process_object()->Delete(
        env->context(),
        FIXED_ONE_BYTE_STRING(args.GetIsolate(), "_setupNextTick")).FromJust();

Looks like this removes the _setupNextTick function from the process object.

    uint32_t* const fields = env->tick_info()->fields();
    uint32_t const fields_count = env->tick_info()->fields_count();

What are 'fields'? What are 'fields_count'?  

    (lldb) p fields_count
    (uint32_t) $23 = 2

    Local<ArrayBuffer> array_buffer =
        ArrayBuffer::New(env->isolate(), fields, sizeof(*fields) * fields_count);

    args.GetReturnValue().Set(Uint32Array::New(array_buffer, 0, fields_count));

So `tickInfo` returned will be an ArrayBuffer:

    const tickInfo = process._setupNextTick(_tickCallback, _runMicrotasks);

Next we assign the `RunMicroTasks` callback to the `_runMicrotasks` variable:

    _runMicrotasks = _runMicrotasks.runMicrotasks;

After this we are done in bootstrap_node.js and the setup of next_tick.
So, lets continue and break in our script and follow process.setNextTick.

    nextTickQueue.push({
      callback,
      domain: process.domain || null,
      args
    });

So we are again showing that we add callback info to the nextTickQueue (after a few checks)
Then we do the following:

    tickInfo[kLength]++;

For each object added to the nextTickQueue we will increment the second element of the tickInfo
array.

And that is it, the stack frames will start returning and be poped off the call stack. What we
are interested in is in module.js and `Module.runMain`:
  
    process._tickCallback();


    do {
      while (tickInfo[kIndex] < tickInfo[kLength]) {
        tock = nextTickQueue[tickInfo[kIndex]++];
        ...
        _combinedTickCallback(args, callback);
        if (kMaxCallbacksUntilQueueIsShortened < tickInfo[kIndex])
           tickDone();
      }
    } while (tickInfo[kLength] !== 0);

The check is to see if tickInfo[kIndex] (is this the index of being processed?) is less than
the number of tick callbacks in the `nextTickQueue`.
Next tickInfo[kIndex] is retrieved from the nextTickQueue and then tickInfo[kIndex] is incremented.

`tickDone()`  

    function tickDone() {
      if (tickInfo[kLength] !== 0) {
        if (tickInfo[kLength] <= tickInfo[kIndex]) {
          nextTickQueue = [];
          tickInfo[kLength] = 0;
        } else {
          nextTickQueue.splice(0, tickInfo[kIndex]);
          tickInfo[kLength] = nextTickQueue.length;
        }
      }
      tickInfo[kIndex] = 0;
     }

Lets take a look at:

    if (tickInfo[kLength] <= tickInfo[kIndex]) {

If the number of callbacks added is less than or equal to the just processed callbacks index this would mean
that all of the callbacks in the queue have been processed and the following clause will make nextTickQueue 
point to an empty array and reset tickInfo[kLength] to zero.
But if there are more callback in the queue than the just processed callbacks index the else clause will be 
taken:

    nextTickQueue.splice(0, tickInfo[kIndex]);
    tickInfo[kLength] = nextTickQueue.length;

splice will remove all elements from 0 to tickInfo[kIndex], which is removing all the processed callbacks.
The new length is set as tickInfo[kLength]. This is done so that the nextTickQueue array does not become
too large and run the process out of memory. By shortning the array this reduces the likelyhood of this 
happening.

#### Compiling with a different version of libuv
What I'd like to do is use my local fork of libuv instead of the one in the deps
directory. I think the way to do this is to `make install` and then run configure with the following options:

    $ ./configure --debug --shared-libuv --shared-libuv-includes=/usr/local/include

The location of the library is `/usr/local/lib`, and `/usr/local/include` for the headers on my machine.

### Updating addons test
Some of the addons tests are not version controlled but instead generate using:

   $ ./node tools/doc/addon-verify.js doc/api/addons.md

The source for these tests can be found in `doc/api/addons.md` and these might need to be updated if a 
change to all tests is required, for a concrete example we wanted to update the build/Release/addon directory
to be different depending on the build type (Debug/Release) and I forgot to update these tests.


### Using nvm with Node.js source
Install to the nvm versions directory:

    $ make install DESTDIR=~/.nvm/versions/node/ PREFIX=v8.0.0

You can then use nvm to list that version and versions:
  
   $ nvm ls 
         v6.5.0
         v7.0.0
         v7.4.0
         v8.0.0

   $ nvm use 8

### lldb
There is a [.lldbinit](./.lldbinit) which contains a number of useful alias to 
print out various V8 objects. This are most of the aliases defined in [gdbinit](https://github.com/v8/v8/blob/master/tools/gdbinit).

For example, you can print a v8::Local<v8::Function> using the builtin print command:

    (lldb) p init_fn
    (v8::Local<v8::Function>) $3 = (val_ = 0x000000010484f900)

This does not give much, but if we instead use jlh:

    (lldb) jlh init_fn
    0x19417e265ba9: [Function]
     - map = 0x382d7ba86ea9 [FastProperties]
     - prototype = 0xd21f3203f39
     - elements = 0x18ede4802241 <FixedArray[0]> [FAST_HOLEY_ELEMENTS]
     - initial_map =
     - shared_info = 0x23c6dbac1ce1 <SharedFunctionInfo init>
     - name = 0x21a813bbd419 <String[4]: init>
     - formal_parameter_count = 4
     - context = 0x19417e203b41 <FixedArray[8]>
     - literals = 0x18ede4804a49 <FixedArray[1]>
     - code = 0x1aa594184481 <Code: BUILTIN>
     - properties = {
       #length: 0x18ede4850bd9 <AccessorInfo> (accessor constant)
       #name: 0x18ede4850c49 <AccessorInfo> (accessor constant)
       #prototype: 0x18ede4850cb9 <AccessorInfo> (accessor constant)
     }

So that gives us more information, but lets say you'd like to see the name of the function:

    (lldb) jlh init_fn->GetName()
    #init

### Promises
The section is about understanding how ECMAScript 6 Promise API works.

    let promise = new Promise(function(resolve, reject) {
      if (true) {
        resolve("resolved");
      } else {
        reject("rejected");
      }  
    }

    promise.then(function (message) {
      console.log(message);
    });

    $ lldb -- ./out/Debug/node --harmony --inspect --debug-brk manual.js
    (lldb) breakpoint set -f isolate.cc -l 1717

So when we do `new Promise` our break point in isolate.cc will be hit:

    void Isolate::PushPromise(Handle<JSObject> promise) {
      ThreadLocalTop* tltop = thread_local_top();
      PromiseOnStack* prev = tltop->promise_on_stack_;
      Handle<JSObject> global_promise =
        Handle<JSObject>::cast(global_handles()->Create(*promise));
      tltop->promise_on_stack_ = new PromiseOnStack(global_promise, prev);
    }

So lets take a close look a `PromiseOnStack` which can be found in isolate.h

    class PromiseOnStack {
      public:
        PromiseOnStack(Handle<JSObject> promise, PromiseOnStack* prev)
          : promise_(promise), prev_(prev) {}
        Handle<JSObject> promise() { return promise_; }
        PromiseOnStack* prev() { return prev_; }

     private:
       Handle<JSObject> promise_;
       PromiseOnStack* prev_;
    };


    (lldb) breakpoint set -f runtime-debug.cc -l 251
    

I was having trouble understanding why I was not able to set a break point in V8 src/js/promise.js file as it was
never availble in devtools. In the same way that Node performs a javascript to c (js2c) (see [bootstrap_node.js](#lib/internal/bootstrap_node.js)
for more information). GN has a target that takes all the files in src/js and generates 
$target_gen_dir/libraries.cc. You can inspect this file (out/x64.debug/obj/gen/libraries.cc).
But I could not find a reference to libraries.cc in the source code base. This is instead used
by target in src/v8.gyp which is v8_snapshot.

out/Debug/obj/gen/libraries.cc and libraries.bin. 


    * thread #1: tid = 0x8ea959, 0x0000000100c91504 node`v8::internal::Isolate::PushPromise(this=0x0000000105004e00, promise=Handle<v8::internal::JSObject> @ 0x00007fff5fbfc238) + 20 at isolate.cc:1717, queue = 'com.apple.main-thread', stop reason = breakpoint 3.1
  * frame #0: 0x0000000100c91504 node`v8::internal::Isolate::PushPromise(this=0x0000000105004e00, promise=Handle<v8::internal::JSObject> @ 0x00007fff5fbfc238) + 20 at isolate.cc:1717
    frame #1: 0x0000000100f277a2 node`v8::internal::__RT_impl_Runtime_DebugPushPromise(args=Arguments @ 0x00007fff5fbfc290, isolate=0x0000000105004e00) + 226 at runtime-debug.cc:1813
    frame #2: 0x0000000100f27559 node`v8::internal::Runtime_DebugPushPromise(args_length=1, args_object=0x00007fff5fbfc348, isolate=0x0000000105004e00) + 297 at runtime-debug.cc:1809



(v8::PromiseRejectCallback) $1 = 0x00000001012a92a0 (node`node::PromiseRejectCallback(v8::PromiseRejectMessage) at node.cc:1169)


src/js/promise.js:

    (function(global, utils, extrasUtils) {

    "use strict";

    %CheckIsBootstrapping();

This is compiled by a call from bootstrapper.cc:

    Handle<Object> args[] = {global, utils, extras_utils};
    return Bootstrapper::CompileNative(isolate, name, source_code, arraysize(args), args, NATIVES_CODE);


$ out/Debug/node --v8-options


### Debug JavaScript tests
Just example commands that I use in different projects to run the debugger with 
different test suites.

#### Mocha

    $ mocha --inspect --debug-brk  -u exports --recursive -t 10000 ./test/setup.js  test/sync/test_index.js

### crypto
The current version of openssl is 1.0.2k (run process.versions.openssl). So this is major version 1, minor 0
and patch 2k I guess.
To investigate lets take a look what happens when one requires crypto:

    const crypto = require('crypto');

    $ lldb -- ./out/Debug/node crypto.js
    
src/node_crypto.cc is a builtin:

    NODE_MODULE_CONTEXT_AWARE_BUILTIN(crypto, node::crypto::InitCrypto)

So, lets set a breakpoint in `InitCrypto`:

    (lldb) breakpoint set -f node_crypto.cc -l 6007
    (lldb) breakpoint set -f node_crypto.cc -l 5880

First things that happens is that libcrypto must be initializes. My understanding is that OpenSSL has two libraries which are 
libssl which used libcrypto. Node is using libcrypto in this case.

From InitCryptOnce:

    SSL_load_error_strings();
    OPENSSL_no_config();

OPENSSL_no_config() marks OpenSSL as configured. It seems that if this is not done to avoid some of OpenSSLs standard init functions
that automatically call the configuration to just return hence do nothing.

   if (!openssl_config.empty())
This path would be taken if a openssl config had been passed using `--openssl-config`.

Next, we have:

    SSL_library_init();

This function can be found in `deps/openssl/openssl/ssl/ssl_algs.c`

    EVP_add_cipher(EVP_des_cbc());


EVP I think stands for envelope and has a number of high level cryptographic functions.

#### CNNIC
China Internet Network Information Center (CNNIC) is referenced in some code. It is a Certificate Authority (may be other things as well).


#### Signed Public Key and Challenge (SPKAC)
Also known as Netscape SPKI.

#### Building with shared openssl
Building an [locally built version](https://github.com/danbev/learning-libcrypto#building-openssl) of OpenSSL.

    $ ./configure --shared-openssl --shared-openssl-libpath=/Users/danielbevenius/work/security/openssl --prefix=/Users/danielbevenius/work/nodejs/build --shared-openssl-includes=/Users/danielbevenius/work/security/openssl/include/


#### Building OpenSSL without elliptic curve support

    $ ./Configure no-ec --debug --prefix=/Users/danielbevenius/work/security/openssl/build  --libdir="openssl" darwin64-x86_64-cc

Then building Node against that version:

    $ ./configure --debug --shared-openssl --shared-openssl-libpath=/Users/danielbevenius/work/security/openssl/build/openssl --prefix=/Users/danielbevenius/work/nodejs/build --shared-openssl-includes=/Users/danielbevenius/work/security/openssl/build/include

This will not compile are the headers for ec will not exist in the `--shared-openssl-includes` directory. You'll have to use the source
include directory instead so that all the headers can be found. 

    $ ./configure --debug --shared-openssl --shared-openssl-libpath=/Users/danielbevenius/work/security/openssl/build/openssl --prefix=/Users/danielbevenius/work/nodejs/build --shared-openssl-includes=/Users/danielbevenius/work/security/openssl/include

There will instead be a runtime error if you try to call functions that require EC but you'll be able to build.

Notice here that we have configured OpenSSL without Elliptic curve support

I was wondering what the values will if you just specify `--shared-openssl` which I've seen. In this case `pkg-config` will be called to retrieve information about
install libraries in the system. For my system this will be:

    'libraries': ['-lcrypto', '-lssl']},

### Building on Solaris
I used VirtualBox to build and run the test suite on Solaris

    $ uname -a
    SunOS solaris 5.11 11.3 i86pc i386 i86pc

#### Setup

    $ sudo pkgadd -d http://get.opencsw.org/now

Install git:
  
    $ sudo /opt/csw/bin/pkgutil -y -i git
    $ export PATH=/opt/csw/bin:$PATH      // added to ~/.bashrc

Install binutils:

    $ sudo pkgutil -y -i binutils
    $ export PATH=/opt/csw/bin:/opt/csw/gnu:$PATH

Set GNU Make as the default:

    $ sudo ln -s /usr/bin/gmake /usr/bin/make

Clone node:

    $ git clone https://github.com/nodejs/node.git

Install gcc 49:

    $ sudo pkg install --accept --license gcc-49

    $ gmake CXXFLAGS+="--function-sections -fdata-sections"

Install stdc++6:

    $ sudo pkgchk -L CSWlibstdc++6
    $ export LD_LIBRARY_PATH=/opt/csw/lib/:$LD_LIBRARY_PATH

Patches:
danbev@solaris:~/work/node$ git show 8ff7afd
commit 8ff7afd2aba1cc13348e5d639f292b2fbb3b86d0
Author: Daniel Bevenius <daniel.bevenius@gmail.com>
Date:   Thu Mar 16 06:59:05 2017 +0100

    add include ldflag for solaris
    
    It looks like when cctest is to be compiled the includes are
    missing. Trying to add the SHARED_INTERMEDIATE_DIR and see if
    that fixes one of the includes. If that works I'll add the rest
    if required.

diff --git a/node.gyp b/node.gyp
index 2407844..4bd3769 100644
--- a/node.gyp
+++ b/node.gyp
@@ -667,6 +667,9 @@
             ]},
           ],
         }],
+        ['OS=="solaris"', {
+          'ldflags': [ '-I<(SHARED_INTERMEDIATE_DIR)' ]
+        }],
       ]
     }
   ], # end targets

danbev@solaris:~/work/node$ git show 68c396b
commit 68c396be00896801bb92b5705da240d9aef30890
Author: Daniel Bevenius <daniel.bevenius@gmail.com>
Date:   Thu Mar 16 12:21:24 2017 +0100

    fix for building on solaris

diff --git a/common.gypi b/common.gypi
index 3aad8e7..e001a1d 100644
--- a/common.gypi
+++ b/common.gypi
@@ -282,7 +282,8 @@
       }],
       [ 'OS in "linux freebsd openbsd solaris android aix"', {
         'cflags': [ '-Wall', '-Wextra', '-Wno-unused-parameter', ],
-        'cflags_cc': [ '-fno-rtti', '-fno-exceptions', '-std=gnu++0x' ],
+        #'cflags_cc': [ '-fno-rtti', '-fno-exceptions', '-std=gnu++0x' ],
+        'cflags_cc': [ '-fno-rtti', '-fno-exceptions' ],
         'ldflags': [ '-rdynamic' ],
         'target_conditions': [
           # The 1990s toolchain on SmartOS can't handle thin archives.
@@ -323,6 +324,8 @@
             'ldflags': [ '-m64', '-march=z196' ],
           }],
           [ 'OS=="solaris"', {
+            'defines': ['_GLIBCXX_USE_C99_MATH'],
+            'cflags_cc': [ '-std=c++11' ],
             'cflags': [ '-pthreads' ],
             'ldflags': [ '-pthreads' ],
             'cflags!': [ '-pthread' ],



Build and run node tests:

    $ gmake cctest


### Building on Windows
I used VirtualBox to build and run the test suite on Windows

    $ .\vcbuild test


### Debugging 

    $ lldb -- out/Debug/cctest
    (lldb) r
    [ RUN      ] EnvironmentTest.MultipleEnvironmentsPerIsolate
    cctest(86419,0x7fff799ca000) malloc: *** error for object 0x104401058: incorrect checksum for freed object - object was probably modified after being freed.
*** set a breakpoint in malloc_error_break to debug
Process 86419 stopped
* thread #1: tid = 0x2bd84d0, 0x00007fff97229f06 libsystem_kernel.dylib`__pthread_kill + 10, queue = 'com.apple.main-thread', stop reason = signal SIGABRT
    frame #0: 0x00007fff97229f06 libsystem_kernel.dylib`__pthread_kill + 10
libsystem_kernel.dylib`__pthread_kill:
->  0x7fff97229f06 <+10>: jae    0x7fff97229f10            ; <+20>
    0x7fff97229f08 <+12>: movq   %rax, %rdi
    0x7fff97229f0b <+15>: jmp    0x7fff972247cd            ; cerror_nocancel
    0x7fff97229f10 <+20>: retq

    (lldb) memory read 0x104401058


    (lldb) jlh handle
    0x1872340551b1: [Symbol]
     - hash: 60730982
     - name: 0x187234028391 <String[14]: node:npnBuffer>
     - private: 1


(lldb) jlh result
0x1e9a8f728239: [Symbol]
 - hash: 171677908
 - name: 0x1e9a8f728211 <String[15]: node:alpnBuffer>
 - private: 1


### Switching between clang and gcc

    CXX=g++ CXX.host=g++ && ./configure -- -Dclang=0.


### [Ninja](https://ninja-build.org/)

Macosx:
 
    $ ./configure --ninja
    $ ninja -C out/Release

    $ ./configure && tools/gyp_node.py -f ninja && ninja -C out/Release && ln -fs out/Release/node node

This will generate object files in `out/Release/src/` but the names will be `obj/src/node.node.o` instead of `obj/src/node/node.o`. This matters
as we generete object files for different operating systems. 

If you take a look in out/Release/ninja.build you'll find a bunch of subninja commands which are used to include other ninja build files:
  
    ....
    subninja obj/node.ninja

#### Building with Ninja linux

    $ dnf install ninja-build
    $ ./configure --debug --ninja
    $ ninja-build -C out/Release
    $ out/Release/cctest

#### Building with Ninja on windows
You'll need to install Visual Studion 2015 and make sure you select Common Tools for C++.

Open cmd with administrator priveliges (Start -> Search for cmd ->CTRL+SHIFT+ENTER):

    > python configure --debug --ninja --dest-cpu=x86 --without-intl
    > tools\gyp_node.py -f ninja
    > ninja -C out\Release
    > out\Release\cctest.exe


### Linux getauxval
A good description of this can be found here:
https://lwn.net/Articles/519085/

The getauxval is a function that was added in glibc 2.16

    #if defined(__linux__) && defined(__GLIBC__) && defined(__GLIBC_PREREQ)
    # if __GLIBC_PREREQ(2, 16)
    #   define HAS_GETAUXVAL 1
    #   include <sys/auxv.h>
    # endif //  HAS_GETAUXVAL
    #endif

    # LD_SHOW_AUXV=1 ./node
    AT_SYSINFO_EHDR: 0x7fff503ee000
    AT_HWCAP:        9f8bfbff
    AT_PAGESZ:       4096
    AT_CLKTCK:       100
    AT_PHDR:         0x400040
    AT_PHENT:        56
    AT_PHNUM:        9
    AT_BASE:         0x7f223f1d6000
    AT_FLAGS:        0x0
    AT_ENTRY:        0x859c90
    AT_UID:          0
    AT_EUID:         0
    AT_GID:          0
    AT_EGID:         0
    AT_SECURE:       0
    AT_RANDOM:       0x7fff503dddc9
    AT_EXECFN:       ./node
    AT_PLATFORM:     x86_64

To force the setting of AT_SECURE:

    $ setcap cap_net_raw+ep out/Release/node
    $ getcap out/Release/node
    $ useradd beve
    $ su beve
    $ ./out/Release/node

#### Show all v8 exceptions

    $ out/Release/node --print_all_exceptions /work/node/test/parallel/test-process-setuid-setgid.js

#### Creating patches
I've found that I need to create patches from old patches that worked with a previous version. At work we 
apply patches to node sources and when new versions are released these patches might not apply cleanly making
it a manual task to make updates to that tag and then generating the patches to be applied.

   $ patch -p1 < 000x-something.patch
   $ git diff --patch-with-stat > patch.out
Then I just copy this and replace the original patch section, but keeping the rest of the original patch.
Then try to apply the patch again to make sure it applied cleanly


#### Cherry pick a V8 commit

    $ git format-patch -1 --stdout f5fad6d > out.patch
    $ git am --directory deps/v8  ~/work/google/javascript/v8/verbose.patch

Don't forget to bump the patch version in deps/v8/include/v8-version.h


#### HTTP/2

    const server = h2.createServer();

createServer is defined in lib/internal/http2/core.js and it returns a 
new Http2Server.
Http2Server extends Server in net.js. After calling the super classes constructor
the following call is performed:

    this.on('newListener', setupCompat);

setupCompat is a event listener callback which only handles 'request' events, 
in which case it 


### Messages/Exceptions with V8
Each V8 Isolate allows listeners to be added for various error messages/exceptions.

    isolate->AddMessageListener(OnMessage);
    isolate->SetFatalErrorHandler(OnFatalError);
    isolate->SetAbortOnUncaughtExceptionCallback(ShouldAbortOnUncaughtException);

`AddMessageListener` is a callback that will be called when an error occurs. How does this work then?

When a script is run, for example:

    const char *js = "age = ajj40";  // intentionally trigger an exception
    Local<String> source = String::NewFromUtf8(isolate, js, NewStringType::kNormal).ToLocalChecked();
    Local<Script> script = Script::Compile(context, source).ToLocalChecked();
    Local<Value> result = script->Run(context).ToLocalChecked();

Script::Run can be found in api.cc 

    (lldb) br s -f api.cc -l 2017

    has_pending_exception = !ToLocal<Value>(i::Execution::Call(isolate, fun, receiver, 0, nullptr), &result);

See the returned value is a bool indicating if there was an error. 
`i::Execution::Call` will call:

    return CallInternal(isolate, callable, receiver, argc, argv, MessageHandling::kReport)

Notice that in the MessageHandling::kReport being passed in. CallInternal looks like this (in our case):

    return Invoke(isolate, false, callable, receiver, argc, argv, isolate->factory()->undefined_value(), message_handling);

    MUST_USE_RESULT MaybeHandle<Object> Invoke(
        Isolate* isolate, bool is_construct, Handle<Object> target,
        Handle<Object> receiver, int argc, Handle<Object> args[],
        Handle<Object> new_target, Execution::MessageHandling message_handling)

In our case the target is a JavaScript Function which can be checked by:

    (lldb) p target->IsJSFunction()
    (bool) $58 = true

This will cause us to enter the following block in the Invoke function:

    if (target->IsJSFunction()) {
      Handle<JSFunction> function = Handle<JSFunction>::cast(target);
     
But there is a check:

   if ((!is_construct || function->IsConstructor()) &&
        function->shared()->IsApiFunction()) {
 
which causes us to exit the block.

    // Placeholder for return value.
    Object* value = NULL;

    typedef Object* (*JSEntryFunction)(Object* new_target, Object* target,
                                      Object* receiver, int argc,
                                      Object*** args);

So we are declaring a JSEntryFunction which is of type pointer to function that returns a pointer to Object
and takes the arguments listed.

    JSEntryFunction stub_entry = FUNCTION_CAST<JSEntryFunction>(code->entry());

    if (FLAG_clear_exceptions_on_js_entry) isolate->clear_pending_exception();

    // Call the function through the right JS entry stub.
    Object* orig_func = *new_target;
    Object* func = *target;
    Object* recv = *receiver;
    Object*** argv = reinterpret_cast<Object***>(args);
    if (FLAG_profile_deserialization && target->IsJSFunction()) {
      PrintDeserializedCodeInfo(Handle<JSFunction>::cast(target));
    }
    RuntimeCallTimerScope timer(isolate, &RuntimeCallStats::JS_Execution);
    value = CALL_GENERATED_CODE(isolate, stub_entry, orig_func, func, recv, argc, argv);

    (lldb) br s -f execution.cc -l 145

CALL_GENERETED_CODE is a macro which is used to call code generated by one of the compilers. 
I'm on a x64 some guessing that src/x64/simulator-x64.h is getting called which does:

    // TODO(X64): Don't pass p0, since it isn't used?
   #define CALL_GENERATED_CODE(isolate, entry, p0, p1, p2, p3, p4) \
   (entry(p0, p1, p2, p3, p4))

Setting a breakpoint after this call we can inspect the value returned:

    (lldb) job value
    #exception

    // Update the pending exception flag and return the value.
    bool has_exception = value->IsException(isolate);
    DCHECK(has_exception == isolate->has_pending_exception());
    if (has_exception) {
      if (message_handling == Execution::MessageHandling::kReport) {
        isolate->ReportPendingMessages();
      }
      return MaybeHandle<Object>();
    } else {
      isolate->clear_pending_message();
    }

Remember that we passed Execution::MessageHandling::kReport earlier so we will call isolate-ReportPendingMessages()

    void Isolate::ReportPendingMessages() {
      DCHECK(AllowExceptions::IsAllowed(this));

      Object* exception = pending_exception();

pending_exception() performs some checks and then returns:

    return thread_local_top_.pending_exception_;

    (lldb) job exception
    0x94c7c108af1: [JS_ERROR_TYPE]
    - map = 0xcc576b8e179 [FastProperties]
    - prototype = 0x1993f4b15221
    - elements = 0x37d706602241 <FixedArray[0]> [FAST_HOLEY_SMI_ELEMENTS]
    - properties = 0x94c7c108ec9 <FixedArray[3]> {
     #stack: 0x3aeec9e69bf1 <AccessorInfo> (const accessor descriptor)
     #message: 0x94c7c108ac9 <String[20]: ajj40 is not defined> (data field 0)
     0x37d706604d71 <Symbol: stack_trace_symbol>: 0x94c7c109099 <JSArray[6]> (data field 1)


    // Try to propagate the exception to an external v8::TryCatch handler. If
    // propagation was unsuccessful, then we will get another chance at reporting
    // the pending message if the exception is re-thrown.
    bool has_been_propagated = PropagatePendingExceptionToExternalTryCatch();
    if (!has_been_propagated) return;

Looking into PropagatePendingExceptionToExternalTryCatch:

    bool Isolate::PropagatePendingExceptionToExternalTryCatch() {
      Object* exception = pending_exception();

The first thing it does is again call pending_exceptions() invoking the same checks are before
which should really be the same. I wonder if there might be use for an overloaded function taking
a pointer to exception?

    HandleScope scope(this);
    Handle<JSMessageObject> message(JSMessageObject::cast(message_obj), this);
    Handle<JSValue> script_wrapper(JSValue::cast(message->script()), this);
    Handle<Script> script(Script::cast(script_wrapper->value()), this);
    int start_pos = message->start_position();
    int end_pos = message->end_position();
    MessageLocation location(script, start_pos, end_pos);
    MessageHandler::ReportMessage(this, &location, message);

`MessageHandler::ReportMessage` prepares the error message (very simplified) and ends up calling:

    ReportMessageNoExceptions(isolate, loc, message, api_exception_obj);


    v8::MessageCallback callback =FUNCTION_CAST<v8::MessageCallback>(callback_obj->foreign_address());
    Handle<Object> callback_data(listener->get(1), isolate);
    {
      // Do not allow exceptions to propagate.
      v8::TryCatch try_catch(reinterpret_cast<v8::Isolate*>(isolate));
      callback(api_message_obj, callback_data->IsUndefined(isolate) ? api_exception_obj : v8::Utils::ToLocal(callback_data));
    }

This is the call that invokes are message callback. After this we will back out of the frame stacks. On thing I notice that there
was an ExceptionScope which the deconstructor sets the exception object. Need to look into why this is done.
So we will eventually end up back where in v8::Script::Run:

    has_pending_exception = !ToLocal<Value>(i::Execution::Call(isolate, fun, receiver, 0, nullptr), &result);

    (lldb) p has_pending_exception
    (bool) $208 = true

     RETURN_ON_FAILED_EXECUTION(Value);
     RETURN_ESCAPED(result);

Lets take a closer look at RETURN_ON_FAILED_EXECUTION(Value):

#define RETURN_ON_FAILED_EXECUTION(T) \
  EXCEPTION_BAILOUT_CHECK_SCOPED(isolate, MaybeLocal<T>())

So that will be EXCEPTION_BAILOUT_CHECK_SCOPED(isolate, MaybeLocal<Value>()) which becomes:

    #define EXCEPTION_BAILOUT_CHECK_SCOPED(isolate, value) \
      do {                                                 \
        if (has_pending_exception) {                       \
          call_depth_scope.Escape();                       \
          return value;                                    \
        }                                                  \
     } while (false)

So in our case the value returned will be a MaybeLocal<Value> object.
This is what gets returned here:

    Local<Value> result = script->Run(context).ToLocalChecked();

Now, notice that we are calling ToLocalChecked(), which 

    if (V8_UNLIKELY(val_ == nullptr)) V8::ToLocalEmpty();

    Utils::ApiCheck(false, "v8::ToLocalChecked", "Empty MaybeLocal.");

    if (!condition) Utils::ReportApiFailure(location, message);


    FatalErrorCallback callback = isolate->exception_behavior();

    callback(location, message);

And this is where our OnFatalError function is called.
But without the ToLocalChecked our OnFatalError would not be called.




Well, during invokation of a Script, recall from above it was mentioned that we'll end up 
in `CALL_GENERATED_CODE`. Now, if we set a breakpoint in file = 'isolate.cc', line = 1062 
which is the Throw function we can backtrace and see how we ended up there.
ic.cc:2395:

    v8::internal::Runtime_LoadGlobalIC_Miss
    Handle<Object> result;
    ASSIGN_RETURN_FAILURE_ON_EXCEPTION(isolate, result, ic.Load(name));
    return *result;

    MaybeHandle<Object> LoadIC::Load(Handle<Object> object, Handle<Name> name)
This will throw an ReferenceError in our case:

    return ReferenceError(name);

    THROW_NEW_ERROR(isolate(), NewReferenceError(MessageTemplate::kNotDefined, name), Object);

That call will bring us back to isolate.cc (1064) which is the Throw function we breaked in.
This time we have a try_catch_handler:

    (lldb) p *try_catch_handler()
    (v8::TryCatch) $2 = {
      isolate_ = 0x0000000105000000
      next_ = 0x0000000000000000
      exception_ = 0x00003107fe782351
      message_obj_ = 0x00003107fe782351
      js_stack_comparable_address_ = 0x00007fff5fbfea50
      is_verbose_ = true
      can_continue_ = true
      capture_message_ = true
      rethrow_ = false
      has_terminated_ = false
    }

ReportPendingMessages:

    // Determine whether the message needs to be reported to all message handlers
    // depending on whether and external v8::TryCatch or an internal JavaScript
    // handler is on top.
    bool should_report_exception;
    if (IsExternalHandlerOnTop(exception)) {
      // Only report the exception if the external handler is verbose.
      should_report_exception = try_catch_handler()->is_verbose_;
    } else {
      // Report the exception if it isn't caught by JavaScript code.
      should_report_exception = !IsJavaScriptHandlerOnTop(exception);
    }

Is this case we have a TryCatch RAII and have set verbose to true. There is no javascript
try/catch so the MessageHandler we set by calling AddMessageHandler on the isolate should
be the target handler.


`SetFatalErrorHandler`
If this callback handler is not set then the default behaviour in V8 will be to  
print a stactrace and exit, for example:

    $ ./exceptions
    OnMessage...

    #
    # Fatal error in v8::ToLocalChecked
    # Empty MaybeLocal.
    #

    Received signal 4 <unknown> 000109100351

    ==== C stack trace ===============================

     [0x00010910322e]
     [0x000109103265]
     [0x000109103186]
     [0x7fff8a2c252a]
     [0x000107ac8423]
     [0x00010624ffbc]
     [0x000106254bef]
     [0x000106254c1d]
     [0x00010621d4dc]
     [0x7fff86cc45ad]
     [0x000000000001]
    [end of stack trace]
    Illegal instruction: 4

You can set a handler for this that does something before exiting of choose to not exit.
    
When an exceptions is raised in V8 it will cause the function Throw in e

    Object* Isolate::Throw(Object* exception, MessageLocation* location) {

#### TryCatch
Is used to create a try/catch block in V8 which used RAII:
    {
      TryCatch try_catch(isolate);
      try_catch.SetVerbose(true);

      ... perform operations

      if (try_catch.HasCaught()) {
        printf("Caught: %s\n", *String::Utf8Value(try_catch.Exception()));
      }

How does setting `verbose` affect things?
In Isolate::Throw:
Which can be called if there is a JavaScript error and if an external TryCatch exist and 
verbose is true. If that is the case the Message will be created:

    Handle<Object> message_obj = CreateMessage(exception_handle, location);
    thread_local_top()->pending_message_obj_ = *message_obj;
    ...
    set_pending_exception(*exception_handle);
    return heap()->exception();

So that is what throw does, sets the message_obj and the exception_handle and then returns.

What if we set verbose to false:

    (lldb) expr try_catch.SetVerbose(false);

In this case the message will still be created and the exception set on the thread_local, but 
when we get to ReportPendingMessages is_verbose_ will be false and the callback will be skipped.


Member functions of SSLWrap:
void DestroySSL();
void WaitForCertCb(CertCb cb, void* arg);
void SetSNIContext(SecureContext* sc);
int SetCACerts(SecureContext* sc);


### Shared 
You can configure node using `--shared` in which case


### Compiling on windows
I looking into an issue on windows:
https://github.com/nodejs/node/issues/12952

The issue is a link error with the cctest target. In this particular case on windows it was built using:

    .\vcbuild.bat dll debug x64 vc2015

This will result in the following options:

    configure --debug --shared --dest-cpu=x64 --tag=

So this is saying that node should be created as a shared library but
not any of its dependencies. In this case the focus is on OpenSSL which
will be a static library.
The link error is:

    openssl.lib(err.obj) : error LINK2005: ERR_put_error already defined in node.lib(node.dll

We can find the exported symbols of Debug/node.dll using:

    dumpbin /EXPORTS Debug/node.dll > node-exports

We can find the ERR_put_error is indeed exported from node.dll
This is done because in node.gyp we have:

      [ 'OS=="win" and '
        'node_use_openssl=="true" and '
        'node_shared_openssl=="false" and node_shared=="false"', {
        'use_openssl_def': 1,
      }, {
        'use_openssl_def': 0,
      }],

In our case use_openssl_def will be 1 which is the used in node.gypi:

      # openssl.def is based on zlib.def, zlib symbols
      # are always exported.
      ['use_openssl_def==1', {
        'sources': ['<(SHARED_INTERMEDIATE_DIR)/openssl.def'],
      }],
      ['OS=="win" and use_openssl_def==0', {
        'sources': ['deps/zlib/win32/zlib.def'],

A .def file is a module definition file which describes attributes of a DLL. In our case openssl.def can be found in Debug\obj\global_intermediate:

    EXPORTS
    ...
    ERR_put_error

So we can see this function is indeed exported, so if we link against openssl.lib 
this symbol (and the others) will be duplicates.


### V8 Platform
This is used by an embedder and is an interface that must be implemented. This interface is defined in deps/v8/include/v8-platform.h.
This interface has a number of functions related to threading and running task on threads:
* CallOnBackgroundThread
* CallOnForegroundThread
* CallDelayedOnForegroundThread
...
* AddTraceEvent

Node can be configured --without-v8-platform which will set environment variables that will be picked up by the pre-processor. For example, if you
take a look in src/node.cc you will find:

    #if NODE_USE_V8_PLATFORM
    #include "libplatform/libplatform.h"
    #endif  // NODE_USE_V8_PLATFORM

libplatform/libplatform.h is the interface for a default v8::Platform implementation in V8.
Next, we have a v8_platform struct that will use the above default v8::Platform implementation is NODE_USE_V8_PLATFORM is set.
But what does it mean to not use the default v8::Platform implementation?
Basically this will just create noop functions or functions that throw an error:

    #else  // !NODE_USE_V8_PLATFORM
    void Initialize(int thread_pool_size) {}
    void PumpMessageLoop(Isolate* isolate) {}
    void Dispose() {}
    bool StartInspector(Environment *env, const char* script_path,
                      const node::DebugOptions& options) {
      env->ThrowError("Node compiled with NODE_USE_V8_PLATFORM=0");
      return true;
    }

    void StartTracingAgent() {
      fprintf(stderr, "Node compiled with NODE_USE_V8_PLATFORM=0, "
                      "so event tracing is not available.\n");
    }
    void StopTracingAgent() {}


When trying to run a test --without-v8-platform I run into the following error:


    #
    # Fatal error in ../deps/v8/src/v8.cc, line 110
    # Check failed: platform_.
    #

    ==== C stack trace ===============================

      0   node                                0x00000001019d2dae v8::base::debug::StackTrace::StackTrace() + 30
      1   node                                0x00000001019d2de5 v8::base::debug::StackTrace::StackTrace() + 21
      2   node                                0x00000001019ccf84 V8_Fatal + 452
      3   node                                0x00000001012bcea8 v8::internal::V8::GetCurrentPlatform() + 72
      4   node                                0x0000000100ed0c7c v8::internal::Isolate::Init(v8::internal::Deserializer*) + 1692
      5   node                                0x00000001012965ba v8::internal::Snapshot::Initialize(v8::internal::Isolate*) + 170
      6   node                                0x0000000100260265 v8::Isolate::New(v8::Isolate::CreateParams const&) + 485
      7   node                                0x000000010170901f node::Start(uv_loop_s*, int, char const* const*, int, char const* const*) + 79
      8   node                                0x0000000101708bce node::Start(int, char**) + 478
      9   node                                0x000000010175f21e main + 94
      10  node                                0x0000000100000a34 start + 52
      11  ???                                 0x0000000000000002 0x0 + 2
    Process 9882 stopped


    2644   compiler_dispatcher_ =
    2645       new CompilerDispatcher(this, V8::GetCurrentPlatform(), FLAG_stack_size);

v8::GetCurrentPlatform will perform the following:

    v8::Platform* V8::GetCurrentPlatform() {
      DCHECK(platform_);
      return platform_;
   }

But since we have not set a platform, remember that would have been done if NODE_USE_V8_PLATFORM:

    #if NODE_USE_V8_PLATFORM
    void Initialize(int thread_pool_size) {
      platform_ = v8::platform::CreateDefaultPlatform(thread_pool_size);
      V8::InitializePlatform(platform_);
      tracing::TraceEventHelper::SetCurrentPlatform(platform_);
    }

My understanding is that the in this code path the snapshot blob is being deserialized and when 
this is done.


### Upgrading OpenSSL

Download and verify the download:

    $ gpg openssl-1.0.2l.tar.gz.asc
    gpg: Signature made Thu May 25 14:55:41 2017 CEST using RSA key ID 0E604491
    gpg: Can't check signature: public key not found
    $ gpg --keyserver pgpkeys.mit.edu --recv-key 0E604491
    gpg: requesting key 0E604491 from hkp server pgpkeys.mit.edu
    gpg: key 0E604491: public key "Matt Caswell <matt@openssl.org>" imported
    gpg: 3 marginal(s) needed, 1 complete(s) needed, PGP trust model
    gpg: depth: 0  valid:   1  signed:   0  trust: 0-, 0q, 0n, 0m, 0f, 1u
    gpg: Total number processed: 1
    gpg:               imported: 1  (RSA: 1)
    $ gpg openssl-1.0.2l.tar.gz.asc
    gpg: Signature made Thu May 25 14:55:41 2017 CEST using RSA key ID 0E604491
    gpg: Good signature from "Matt Caswell <matt@openssl.org>"
    gpg:                 aka "Matt Caswell <frodo@baggins.org>"
    gpg: WARNING: This key is not certified with a trusted signature!
    gpg:          There is no indication that the signature belongs to the owner.
    Primary key fingerprint: 8657 ABB2 60F0 56B1 E519  0839 D9C4 D26D 0E60 4491


Compare the changes to make see if you have to make changes to the


### Supporting different Crypto versions/libraries
I'm working on a solution for Node.js to be able to support multiple versions of OpenSSL and in 
the long run hopefully be able to also support other crypto libraries like LibreSSL, BoringSSL etc.

Currently, it is possible to specify that OpenSSL that is in the deps directory be used when building
node. One can also specify --shared-openssl and the specify where the headers are etc. The issue with
this is that the code still depends on a specific version of OpenSSL and to support multiple version
one has to have macro guards and for Linux distributions it probably means patching Node crypto as 
at least in our case (Red Hat Enterprise Linux (RHEL)) we do so. 


Let's configure node to use 

    $ ./configure --debug --shared-openssl --shared-openssl-libpath=/Users/danielbevenius/work/security/build_1_1_0f/lib --shared-openssl-includes=/Users/danielbevenius/work/security/build_1_1_0f/include

This will result in a compilation error which is good in our case as this gives us something to verify that we can have different version of OpenSSL.

Suggestion:
Keep in mind I don't think we can just start over and change what is currently there. The idea is that we provide a similar configuration that 
we have to day but make it more general and not tied to OpenSSL. We could add a crypto version that specifies the version of being used, which for
OpenSSL (non-shared) would default to the current version of OpenSSL in the deps directory. 

Specfic version could then be supported by adding concrete implementations in src/crypto. The goal is to extract types that are general enough to 
allow us to extract an abstract class which specific providers/versions must implement. 

Tactic:
* Move all OpenSSL dependent crypto source files into a separate directory (src/crypto/openssl-1.0.x/)
  - verify that the build and tests are successful
* Implement a CryptoFactory that crypto libraries can register a specifiec version with. 
  - How should these get registered?
    We won't ever be using more than one crypto implementation.


### OpenSSL with FIPS
When building the OpenSSL and specifying `--openssl-fips`, which is described as "Build OpenSSL using FIPS canister .o file in supplied folder", support for [Fipsld](https://wiki.openssl.org/index.php/Fipsld_and_C%2B%2B). The follwing can be seen on that page:
"When performing a static link against the OpenSSL library, you have to embed the expected FIPS signature in your executable after final linking. Embedding the FIPS signature in your executable is most often accomplished with fisld."
"fisld will take the place of the linker (or compiler if invoking via a compiler driver). If you use fisld to compile a source file, fisld will do nothing and simply invoke the compiler you specify through FIPSLD_CC. When it comes time to link, fisld will compile fips_premain.c, add fipscanister.o, and then perform the final link of your program. Once your program is linked, fisld will then invoke incore to embed the FIPS signature in your program."

For instructions building an OpenSSL version with FIPS support see:
https://github.com/danbev/learning-libcrypto#fips


#### OpenSSL FIPS Object Module
OpenSSL itself is not validated,and never will be. Instead a carefully defined software component
called the OpenSSL FIPS Object Module has been created. The Module was designed for
compatibility with the OpenSSL library so products using the OpenSSL library and API can be
converted to use FIPS 140-2 validated cryptography with minimal effort.


The v1.2.x Module is only compatible with OpenSSL 0.9.8 releases, while the v2.0 Module is
compatible with OpenSSL 1.0.1 and 1.0.2 releases. The v2.0 Module is the best choice for all new
software and product development.

After following the [instructions](https://github.com/danbev/learning-libcrypto#fips) to configure OpenSSL with FIPS support, building Node can be done using the following commands:

    $ ./configure --debug --shared-openssl --shared-openssl-libpath=/Users/danielbevenius/work/security/build_1_0_2k/lib --shared-openssl-includes=/Users/danielbevenius/work/security/build_1_0_2k/include --openssl-fips=/Users/danielbevenius/work/security/build_1_0_2k/
    $ make -j8 test



#### Crypto init

    void InitCrypto(Local<Object> target,
                Local<Value> unused,
                Local<Context> context,
                void* priv) {
    static uv_once_t init_once = UV_ONCE_INIT;
    uv_once(&init_once, InitCryptoOnce);

    Environment* env = Environment::GetCurrent(context);
    SecureContext::Initialize(env, target);

`SecureContext::Initialize`:

    void CipherBase::Initialize(Environment* env, Local<Object> target) {
        Local<FunctionTemplate> t = env->NewFunctionTemplate(New);

Lets take a look what `New` does:

    void SecureContext::New(const FunctionCallbackInfo<Value>& args) {
      Environment* env = Environment::GetCurrent(args);
      new SecureContext(env, args.This());
    }

Usage of tls would look like a normal require (though since this is an native module the loading will be done by `NativeModule.require(filename)`:

    const tls = require('tls');

This module exports (among other functions): 

    exports.createSecureContext = require('_tls_common').createSecureContext;
    exports.SecureContext = require('_tls_common').SecureContext;
    exports.TLSSocket = require('_tls_wrap').TLSSocket;
    exports.Server = require('_tls_wrap').Server;
    exports.createServer = require('_tls_wrap').createServer;
    exports.connect = require('_tls_wrap').connect;

So calling `tls.createSecureContext` will end up in `lib/_tls_common.js:

    exports.createSecureContext = function createSecureContext(options, context) {
    ...
      var c = new SecureContext(options.secureProtocol, secureOptions, context);

And here we find the call to `SecureContext` using `new`.

In this walk through we have been taking a look at `New` but this was not called at this time. The
next task in `SecureContext::Initialize(env, target)` is to set up functions on the 

    Local<FunctionTemplate> t = env->NewFunctionTemplate(SecureContext::New);
    t->InstanceTemplate()->SetInternalFieldCount(1);
    t->SetClassName(FIXED_ONE_BYTE_STRING(env->isolate(), "SecureContext"));

    env->SetProtoMethod(t, "init", SecureContext::Init);
    env->SetProtoMethod(t, "setKey", SecureContext::SetKey);
    env->SetProtoMethod(t, "setCert", SecureContext::SetCert);
    env->SetProtoMethod(t, "addCACert", SecureContext::AddCACert);
    ...
    target->Set(FIXED_ONE_BYTE_STRING(env->isolate(), "SecureContext"), t->GetFunction());
    
Remember that these are prototype functions that are being setup on instance created when using
`new SecureContext` which will be an instance of `CipherBase` since this is the type that the `New` function returned.

    const binding = process.binding('crypto');

Recall that binding is a function that is set on the process object when it is set up on node.cc. This 
will be a call to Binding:

    (lldb) br s -f node.cc -l 2723

    static void Binding(const FunctionCallbackInfo<Value>& args) {
      Local<String> module = args[0]->ToString(env->isolate());
      node::Utf8Value module_v(env->isolate(), module);
      ...
    }

    (lldb) jlh module
    #crypto


    Local<Array> modules = env->module_load_list_array();
    (lldb) jlh modules
    0x16da0049c641: [JSArray]
     - map = 0x34afb7a04099 [FastProperties]
     - prototype = 0xe7de5189b01
     - elements = 0x39e4730d5221 <FixedArray[82]> [FAST_HOLEY_ELEMENTS]
     - length = 69
     - properties = 0x25494902241 <FixedArray[0]> {
        #length: 0x4ddc16a6369 <AccessorInfo> (const accessor descriptor)
     }
     - elements = 0x39e4730d5221 <FixedArray[82]> {
           0: 0x246944578d59 <String[18]: Binding contextify>
           1: 0x246944578d89 <String[15]: Binding natives>
           2: 0x246944578db1 <String[14]: Binding config>
           3: 0x246944578dd9 <String[19]: NativeModule events>
           4: 0x246944578e01 <String[18]: Binding async_wrap>
           5: 0x246944578e31 <String[11]: Binding icu>
           6: 0x246944578e59 <String[17]: NativeModule util>
           7: 0x246944578e81 <String[10]: Binding uv>
           8: 0x246944578ea9 <String[19]: NativeModule buffer>
           9: 0x246944578ed1 <String[14]: Binding buffer>
          10: 0x246944578ef9 <String[12]: Binding util>
          11: 0x246944578f21 <String[26]: NativeModule internal/util>
          12: 0x246944578f49 <String[28]: NativeModule internal/errors>
          13: 0x246944578f71 <String[17]: Binding constants>
          14: 0x246944578fa1 <String[28]: NativeModule internal/buffer>
          15: 0x246944578fc9 <String[19]: NativeModule timers>
          16: 0x246944578ff1 <String[18]: Binding timer_wrap>
          17: 0x246944579021 <String[32]: NativeModule internal/linkedlist>
          18: 0x246944579049 <String[24]: NativeModule async_hooks>
          19: 0x246944579071 <String[19]: NativeModule assert>
          20: 0x246944579099 <String[29]: NativeModule internal/process>
          21: 0x2469445790c1 <String[37]: NativeModule internal/process/warning>
          22: 0x2469445790e9 <String[39]: NativeModule internal/process/next_tick>
          23: 0x246944579111 <String[38]: NativeModule internal/process/promises>
          24: 0x246944579139 <String[35]: NativeModule internal/process/stdio>
          25: 0x246944579161 <String[25]: NativeModule internal/url>
          26: 0x246944579189 <String[33]: NativeModule internal/querystring>
          27: 0x2469445791b1 <String[24]: NativeModule querystring>
          28: 0x2469445791d9 <String[11]: Binding url>
          29: 0x246944579201 <String[17]: NativeModule path>
          30: 0x246944579229 <String[19]: NativeModule module>
          31: 0x246944579251 <String[28]: NativeModule internal/module>
          32: 0x246944579279 <String[15]: NativeModule vm>
          33: 0x2469445792a1 <String[15]: NativeModule fs>
          34: 0x39e4730e0651 <String[10]: Binding fs>
          35: 0x39e4730e0679 <String[19]: NativeModule stream>
          36: 0x39e4730e06a1 <String[36]: NativeModule internal/streams/legacy>
          37: 0x39e4730e06c9 <String[29]: NativeModule _stream_readable>
          38: 0x39e4730e06f1 <String[40]: NativeModule internal/streams/BufferList>
          39: 0x39e4730e0719 <String[37]: NativeModule internal/streams/destroy>
          40: 0x39e4730e0741 <String[29]: NativeModule _stream_writable>
          41: 0x39e4730e0769 <String[27]: NativeModule _stream_duplex>
          42: 0x39e4730e0791 <String[30]: NativeModule _stream_transform>
          43: 0x39e4730e07b9 <String[32]: NativeModule _stream_passthrough>
          44: 0x39e4730e07e1 <String[21]: Binding fs_event_wrap>
          45: 0x39e4730e0811 <String[24]: NativeModule internal/fs>
          46: 0x39e4730e0839 <String[17]: Binding inspector>
          47: 0x21515bc747c9 <String[15]: NativeModule os>
          48: 0x21515bc747f1 <String[10]: Binding os>
          49: 0x21515bc74819 <String[26]: NativeModule child_process>
          50: 0x21515bc74841 <String[18]: Binding spawn_sync>
          51: 0x21515bc74871 <String[17]: Binding pipe_wrap>
          52: 0x21515bc748a1 <String[35]: NativeModule internal/child_process>
          53: 0x21515bc748c9 <String[27]: NativeModule string_decoder>
          54: 0x21515bc748f1 <String[16]: NativeModule net>
          55: 0x21515bc74919 <String[25]: NativeModule internal/net>
          56: 0x21515bc74941 <String[18]: Binding cares_wrap>
          57: 0x21515bc74971 <String[16]: Binding tty_wrap>
          58: 0x21515bc74999 <String[16]: Binding tcp_wrap>
          59: 0x21515bc749c1 <String[19]: Binding stream_wrap>
          60: 0x21515bc749f1 <String[18]: NativeModule dgram>
          61: 0x21515bc74a19 <String[16]: Binding udp_wrap>
          62: 0x21515bc74a41 <String[20]: Binding process_wrap>
          63: 0x21515bc74a71 <String[33]: NativeModule internal/socket_list>
          64: 0x21515bc74a99 <String[20]: NativeModule console>
          65: 0x21515bc74ac1 <String[16]: NativeModule tty>
          66: 0x21515bc74ae9 <String[19]: Binding signal_wrap>
          67: 0x35756b2729e1 <String[16]: NativeModule tls>
          68: 0xd6549a0f479 <String[16]: NativeModule url>
       69-81: 0x25494902351 <the hole>
    }

A `NativeModule` is a module which has access to the module property and implemented in JavaScript.
A `Binding` is something that does not have a module and only set exports. 

    modules->Set(l, OneByteString(env->isolate(), buf));
    (lldb) p buf
    (char [1024]) $16 = "Binding crypto"

    node_module* mod = get_builtin_module(*module_v);
    (lldb) p *mod
    (node::node_module) $24 = {
      nm_version = 55
      nm_flags = 1
      nm_dso_handle = 0x0000000000000000
      nm_filename = 0x0000000101bc4053 "../src/crypto_impl/node_crypto.cc"
      nm_register_func = 0x0000000000000000
      nm_context_register_func = 0x000000010180f630 (node`node::crypto::InitCrypto(v8::Local<v8::Object>, v8::Local<v8::Value>, v8::Local<v8::Context>, void*) at node_crypto.cc:6230)
      nm_modname = 0x0000000101baffde "crypto"
      nm_priv = 0x0000000000000000
      nm_link = 0x00000001027c54c0
   }

In this case I'm actually documenting and troubleshooting which is the reason for the strange path names to the source files.

     if (mod != nullptr) {
       exports = Object::New(env->isolate());
       // Internal bindings don't have a "module" object, only exports.
       CHECK_EQ(mod->nm_register_func, nullptr);
       CHECK_NE(mod->nm_context_register_func, nullptr);
       Local<Value> unused = Undefined(env->isolate());
       mod->nm_context_register_func(exports, unused, env->context(), mod->nm_priv);
       cache->Set(module, exports);

So we check that the `nm_register_func` is not set but we should have a context aware register node module function but set the `exports` instance to Undefined.
Next `mod->nm_context_register_func` is called which was configured in node_crypto.cc:

    NODE_MODULE_CONTEXT_AWARE_BUILTIN(crypto, node::crypto::InitCrypto)

So InitCrypto will be the function we end up in which has the call to `SecureContext::Initialize(env, target);` which I wanted to know how it ended up there.

#### InitCrypto
This will intialize the following:

    SecureContext::Initialize(env, target);
    Connection::Initialize(env, target); // SSLConnection
    CipherBase::Initialize(env, target);
    DiffieHellman::Initialize(env, target);
    ECDH::Initialize(env, target);
    Hmac::Initialize(env, target);
    Hash::Initialize(env, target);
    Sign::Initialize(env, target);
    Verify::Initialize(env, target); 

Should the constructors for these be checking that they are called with new?
Even if these are internal it might be possible to call them using:

    const binding = process.binding('crypto');
    //const h = new binding.Hmac();
    const h = binding.Hmac();
   
### Builtins/Constants/Natives
Using process.binding you can load builtin modules, the constant module, or native modules.
The builtin modules are those that are initialized by the loader, for example: 

    NODE_MODULE_CONTEXT_AWARE_BUILTIN(config, node::InitConfig)

The above module would then be loaded using process.binding('config').
If you look at the `Binding` function is src/node.cc you can see that there are two special cases if the module is not 
found as a builtin. One if the name passed in is `constants` and one if the name passed in is `natives`.

#### constants
Just a note here about how src/node_constant.cc is loaded as there is no `NODE_MOUDULE_CONTEXT_AWARE_BUILTIN` macro or anything like that. Instead this will be loaded when:

    process.binding('constants').

Which like mentioned earlier in this document this will invoke `Binding` (in node.cc) and there is a special clause for `constants`:

    } else if (!strcmp(*module_v, "constants")) {
      exports = Object::New(env->isolate());
      CHECK(exports->SetPrototype(env->context(), Null(env->isolate())).FromJust());
      DefineConstants(env->isolate(), exports);
      cache->Set(module, exports);

`DefineConstants`: 

    DefineErrnoConstants(err_constants);
    DefineWindowsErrorConstants(err_constants);
    DefineSignalConstants(sig_constants);
    DefineUVConstants(os_constants);
    DefineSystemConstants(fs_constants);
    DefineOpenSSLConstants(crypto_constants);
    DefineCryptoConstants(crypto_constants);
    DefineZlibConstants(zlib_constants);

    os_constants->Set(OneByteString(isolate, "errno"), err_constants);
    os_constants->Set(OneByteString(isolate, "signals"), sig_constants);
    target->Set(OneByteString(isolate, "os"), os_constants);
    target->Set(OneByteString(isolate, "fs"), fs_constants);
    target->Set(OneByteString(isolate, "crypto"), crypto_constants);
    target->Set(OneByteString(isolate, "zlib"), zlib_constants);
    

#### Natives
When you see:

    NativeModule._source = process.binding('natives');

Similar to when `process.binding('constants')` is used there is a special clause in Binding for this:

    } else if (!strcmp(*module_v, "natives")) {
      exports = Object::New(env->isolate());
      DefineJavaScript(env, exports);
      cache->Set(module, exports);

`DefineJavaScript` is declared in `src/node_javascript.h` but as you might recall there is no implementation in the source code tree for this header the source file is generated
using the JavaScript source files and config.gypi that is generated by configure:

    'action_name': 'node_js2c',
    'process_outputs_as_sources': 1,
    'inputs': [
      '<@(library_files)',
      './config.gypi',
    ],
    'outputs': [
      '<(SHARED_INTERMEDIATE_DIR)/node_javascript.cc',
    ...
So we can see that the JavaScript library files are included and config.gypi.

If you call `process.binding('config')` what will be returned will be a builtin module as there is one registered:

    NODE_MODULE_CONTEXT_AWARE_BUILTIN(config, node::InitConfig)

But this does not populate the process objects config variables which you might think. Instead that is done in node_bootstrap.js:

    const _process = NativeModule.require('internal/process');
    _process.setupConfig(NativeModule._source);


When I was working on decoupling OpenSSL from node.cc I missed out the macros that are used to conditionally set various settings. For example in `GetFeatures` we have:

    #ifdef SSL_CTRL_SET_TLSEXT_SERVERNAME_CB
      Local<Boolean> tls_sni = True(env->isolate());
    #else
      Local<Boolean> tls_sni = False(env->isolate());
    #endif
      obj->Set(FIXED_ONE_BYTE_STRING(env->isolate(), "tls_sni"), tls_sni);


Fix formatting in src/node_crypto.cc X509ToObject


### TLS OpenSSL 1.1.0 Issue
I'm tryin to make test/parallel/test-tls-ecdh-disable.js to be used with both OpenSSL 1.0.x and 1.1.x.
The issue is that the test successfully listens and the mustNotCall function is called which is the callback passed to the listener event handler registration.

The cipher in use is `ECDHE-RSA-AES128-GCM-SHA256`. We can check what ciphers are supported by using the following command:

    $ ~/work/security/build_1_1_0f/bin/openssl ciphers -v 'ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS'
    ECDHE-ECDSA-AES256-GCM-SHA384 TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AESGCM(256) Mac=AEAD
    ECDHE-RSA-AES256-GCM-SHA384 TLSv1.2 Kx=ECDH     Au=RSA  Enc=AESGCM(256) Mac=AEAD
    ECDHE-ECDSA-AES128-GCM-SHA256 TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AESGCM(128) Mac=AEAD

    ECDHE-RSA-AES128-GCM-SHA256 TLSv1.2 Kx=ECDH     Au=RSA  Enc=AESGCM(128) Mac=AEAD <----

    DHE-RSA-AES256-GCM-SHA384 TLSv1.2 Kx=DH       Au=RSA  Enc=AESGCM(256) Mac=AEAD
    DHE-RSA-AES128-GCM-SHA256 TLSv1.2 Kx=DH       Au=RSA  Enc=AESGCM(128) Mac=AEAD
    ECDHE-ECDSA-AES256-CCM8 TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AESCCM8(256) Mac=AEAD
    ECDHE-ECDSA-AES256-CCM  TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AESCCM(256) Mac=AEAD
    ECDHE-ECDSA-AES256-SHA384 TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AES(256)  Mac=SHA384
    ECDHE-RSA-AES256-SHA384 TLSv1.2 Kx=ECDH     Au=RSA  Enc=AES(256)  Mac=SHA384
    ECDHE-ECDSA-AES256-SHA  TLSv1 Kx=ECDH     Au=ECDSA Enc=AES(256)  Mac=SHA1
    ECDHE-RSA-AES256-SHA    TLSv1 Kx=ECDH     Au=RSA  Enc=AES(256)  Mac=SHA1
    DHE-RSA-AES256-CCM8     TLSv1.2 Kx=DH       Au=RSA  Enc=AESCCM8(256) Mac=AEAD
    DHE-RSA-AES256-CCM      TLSv1.2 Kx=DH       Au=RSA  Enc=AESCCM(256) Mac=AEAD
    DHE-RSA-AES256-SHA256   TLSv1.2 Kx=DH       Au=RSA  Enc=AES(256)  Mac=SHA256
    DHE-RSA-AES256-SHA      SSLv3 Kx=DH       Au=RSA  Enc=AES(256)  Mac=SHA1
    ECDHE-ECDSA-AES128-CCM8 TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AESCCM8(128) Mac=AEAD
    ECDHE-ECDSA-AES128-CCM  TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AESCCM(128) Mac=AEAD
    ECDHE-ECDSA-AES128-SHA256 TLSv1.2 Kx=ECDH     Au=ECDSA Enc=AES(128)  Mac=SHA256
    ECDHE-RSA-AES128-SHA256 TLSv1.2 Kx=ECDH     Au=RSA  Enc=AES(128)  Mac=SHA256
    ECDHE-ECDSA-AES128-SHA  TLSv1 Kx=ECDH     Au=ECDSA Enc=AES(128)  Mac=SHA1
    ECDHE-RSA-AES128-SHA    TLSv1 Kx=ECDH     Au=RSA  Enc=AES(128)  Mac=SHA1
    DHE-RSA-AES128-CCM8     TLSv1.2 Kx=DH       Au=RSA  Enc=AESCCM8(128) Mac=AEAD
    DHE-RSA-AES128-CCM      TLSv1.2 Kx=DH       Au=RSA  Enc=AESCCM(128) Mac=AEAD
    DHE-RSA-AES128-SHA256   TLSv1.2 Kx=DH       Au=RSA  Enc=AES(128)  Mac=SHA256
    DHE-RSA-AES128-SHA      SSLv3 Kx=DH       Au=RSA  Enc=AES(128)  Mac=SHA1
    AES256-GCM-SHA384       TLSv1.2 Kx=RSA      Au=RSA  Enc=AESGCM(256) Mac=AEAD
    AES128-GCM-SHA256       TLSv1.2 Kx=RSA      Au=RSA  Enc=AESGCM(128) Mac=AEAD
    AES256-CCM8             TLSv1.2 Kx=RSA      Au=RSA  Enc=AESCCM8(256) Mac=AEAD
    AES256-CCM              TLSv1.2 Kx=RSA      Au=RSA  Enc=AESCCM(256) Mac=AEAD
    AES128-CCM8             TLSv1.2 Kx=RSA      Au=RSA  Enc=AESCCM8(128) Mac=AEAD
    AES128-CCM              TLSv1.2 Kx=RSA      Au=RSA  Enc=AESCCM(128) Mac=AEAD
    AES256-SHA256           TLSv1.2 Kx=RSA      Au=RSA  Enc=AES(256)  Mac=SHA256
    AES128-SHA256           TLSv1.2 Kx=RSA      Au=RSA  Enc=AES(128)  Mac=SHA256
    AES256-SHA              SSLv3 Kx=RSA      Au=RSA  Enc=AES(256)  Mac=SHA1
    AES128-SHA              SSLv3 Kx=RSA      Au=RSA  Enc=AES(128)  Mac=SHA1


### Zlib
The version we are using on Fedora is:

     zlib: '1.2.8'

The version building locally is:

     zlib: '1.2.11',

The issue I'm seeing is that `test/parallel/test-zlib-failed-init.js` passes as expected when using version 1.2.11 but fails
when using 1.2.8. 
The change log for zlib can be found here: http://zlib.net/ChangeLog.txt

    Changes in 1.2.9 (31 Dec 2016)
    ...
    - Reject a window size of 256 bytes if not using the zlib wrapper
    ...

### ICU
We are currently building using --with-intl=system-icu which gives the following icu version:

    icu: '57.1'

When I build locally and without any icu flags the version is:

The issue I'm seeing is that test/parallel/test-icu-data-dir.js is failing:

    assert.js:60
    throw new errors.AssertionError({
    ^

    AssertionError [ERR_ASSERTION]: false == true
      at Object.<anonymous> (/root/rpmbuild/BUILD/node-v8.1.0/test/parallel/test-icu-data-dir.js:13:3)


    const child = spawnSync(process.execPath, ['--icu-data-dir=/', '-e', '0']);
    assert(child.stderr.toString().includes(expected));


### Fips
When using the bundled/deps version of OpenSSL and the just building without any configuration options, OpenSSL FIPS support is not enabled. 
The test `test/parallel/test-crypto-fips.js` performs a number of checks and assumes the above default configuration. I'm running into an issue when configuring Node using --shared-openssl and the system version of OpenSSL supports FIPS (but I'm not setting anything FIPS related when configuring only the shared includes and shared lib directory. When I do this the mentioned test fails when trying to toggle fips_mode using a OpenSSL configuration file.


    [root@1b05bc2e415c node-v8.1.0]# openssl version
    OpenSSL 1.0.2k-fips  26 Jan 2017    

    out/Release/node test/parallel/test-icu-data-dir.js:

    Spawned child [pid:9757] with cmd 'require("crypto").fips' expect 0 with args '--openssl-config=/root/rpmbuild/BUILD/node-v8.1.0/test/fixtures/openssl_fips_enabled.cnf' OPENSSL_CONF=undefined
    assert.js:60
      throw new errors.AssertionError({
      ^

    AssertionError [ERR_ASSERTION]: 0 === 1
        at responseHandler (/root/rpmbuild/BUILD/node-v8.1.0/test/parallel/test-crypto-fips.js:56:14)


You might have to manually remove `config_fips.gypi` when you want to reconfigure fips.

#### Building the bundled openssl with fips

    $ ./configure --openssl-fips=/Users/danielbevenius/work/security/build_1_0_2k/
    $ out/Release/node
    > process.versions.openssl
    '1.0.2l-fips'

### Node N-API

All JavaScript values are abstracted behind an opaque type named napi_value.


### FIXED_ONE_BYTE_STRING
This is a macro which can be found in `src/util.h`:

    #define FIXED_ONE_BYTE_STRING(isolate, string)                                \
    (node::OneByteString((isolate), (string), sizeof(string) - 1))

    inline v8::Local<v8::String> OneByteString(v8::Isolate* isolate,
                                           const char* data,
                                           int length) {
       return v8::String::NewFromOneByte(isolate,
                                     reinterpret_cast<const uint8_t*>(data),
                                     v8::NewStringType::kNormal,
                                     length).ToLocalChecked();
    }
So we are passing in the string which recieved as a const char* in the OneByteString function. This is then reinterpreted to const uint8_t*.

OneByteString: the string's bytes are not UTF-8 encoded, can only contain characters in the first 256 unicode code points
TwoByteString: Same, but uses two bytes for each character (using surrogate pairs to represent unicode characters that can't be represented in two bytes).


## Binary Compatability
Is when a program is linked dynmically to a former version and does not have to be recompiled.
If a program needs to be recompiled to run with a new version of library but doesn't require 
any further modifications, the library is source compatible.

An ABI defines the structures and methods used to access external, already compiled libraries/code at the level of machine code.

Making a namespace change in C++ will generate a different mangled name so the symbol in the object file will be different.


#### C++ Lint task
Verify that functions that return pointers have the pointer operator in the correct place (to the left).

The rules can be found in 'tools/cpplint.py' and can be run using:

    tools/cpplint.py files

The script will run through the files and for each one call ProcessFile which does some checking and then calls
ProcessFileData and later ProcessLine. Not that you can pass in extra_check_functions which might become handy.


### NDEBUG
I've seen this in couple of places in the node source code and did not know about it.
NDBUG is used to toggle/control whether the assert macro will expand into something that will perform a check or not.

From `<assert.h>`:

    #ifdef NDEBUG
    #define assert(condition) ((void)0)
    #else
    #define assert(condition) 
    #endif

### assert
This macro is disabled if, at the moment of including <assert.h>, a macro with the name NDEBUG has already been defined. 
This allows for a coder to include as many assert calls as needed in a source code while debugging the program and then disable all of them for the production version by simply including a line like:
 
    #define NDEBUG 

If the NDEBUG macro is defined when <assert.h> is included the assets are disabled. While looking into adding a addons test I noticed that at-exit undefined
NDEBUG but not the other tests that use assert. As far as I can tell there is no need to undefine this and non of the other tests do. This commit removes
the undef for consistency.

### Building a addons
Change to the directory of the addons and then you can rebuild using:

    $ out/Debug/node deps/npm/node_modules/node-gyp/bin/node-gyp.js rebuild --directory=test/addons/at-exit --nodedir=../../../

On windows you can just copy the command from the output from, for example:

    "C:\\Users\\danbev\\working\\node\\Release\\node.exe" "C:\\Users\\danbev\\working\\node\\deps\\npm\\node_modules\\node-gyp\\bin\\node-gyp" "rebuild" "--directory=test\\addons\\openssl-client-cert-engine" "--nodedir=C:\\Users\\danbev\\working\\node"


### Run an a set of JavaScript tests
You can specify the directory to run test, for example this would only run the async-hooks tests:

    $ python tools/test.py --mode=release -J async-hooks

### Event Loop
It all starts with the javascript file to be executed, which is you main program.

    ------------> javascript.js ------+-----------------------------+ 
                                     /|\                            | setTimeout/SetInterval
                                      |                             | JavaScript callbacks --------------------------------------+
                                      |                             |                                                            |
                                      |                             | network/disk/child_processes                               |
                                      |                             | JavaScript callbacks --------------------------------------+
                                      |                             |                                                            |----> callback ------> nextTick callback ------------------------------+
                                      |                             | setImmedate                                                |                             /|\                                       |
                                      +                             | JavaScript callbacks --------------------------------------|                              |                                        |
                                       \                            |                                                            |                              +---- process resolved promises ---------+ 
                                        \                           | close events                                               |                    
                                         \                          | JavaScript callbacks --------------------------------------|
                                          \                         |
                                           \                        |
    <----------- process.exit (event) <-----------------------------+


Where is the first interaction with libuv in node?
There very first call is (in node.cc):

    argv = uv_setup_args(argc, argv);

But this does not do anything with the event loop. For that we have to look at `Init`:

    prog_start_time = static_cast<double>(uv_now(uv_default_loop()));

This will land us in uv_common.c:

    uv_loop_t* uv_default_loop(void) {
     if (default_loop_ptr != NULL)
       return default_loop_ptr;
   
     if (uv_loop_init(&default_loop_struct))

    (lldb) p default_loop_ptr
    (uv_loop_t *) $4 = 0x0000000000000000

So we can see that this is the first call to `uv_default_loop` so lets take a closer look at `uv_loop_init` in src/unix/loop.c (in libuv that is):

    uv__signal_global_once_init();

Which will call:

    uv_once(&uv__signal_global_init_guard, uv__signal_global_init);

I just skimmed the code but this looks like setting up fork handlers to reset signals. uv_once uses [pthread_once](https://github.com/danbev/learning-c/blob/master/pthreads-once.c).
After this we will be back in loop.c:

    heap_init((struct heap*) &loop->timer_heap);

Where are initializing a min heap data structur for timers.

    QUEUE_INIT(&loop->wq)

`wq` is a work queue (include/uv-threadpool.h):

    void* wq[2];

What does the macro `QUEUE_INIT` do?
It is defined in `src/queue.h` as:

    QUEUE_NEXT(q) = (q);                                                      \
    QUEUE_PREV(q) = (q);

    typedef void *QUEUE[2];
    ...
    #define QUEUE_NEXT(q)       (*(QUEUE **) &((*(q))[0]))

This will set &loop->wp[0]

And the same goes for handle_queue and active_reqs which will be initialized using QUEUE_INIT as well:

    void* handle_queue[2];
    void* active_reqs[2];

    QUEUE_INIT(&loop->active_reqs);
    QUEUE_INIT(&loop->idle_handles);

    ...
    err = uv__platform_loop_init(loop);


`uv__platform_loop_init` can be found in src/unix/darwin.c:

    if (uv__kqueue_init(loop)) 

`uv__kqueue_init` can be found in src/unix/kqueue.c:

    loop->backend_fd = kqueue()

    
#### Resolve promises
After calling the callback provided by the user, a smaller loop will check if there are any resolved promises.

Where is this done?
If we take a look at lib/internal/bootstrap.js and the start function we find the following line:

    NativeModule.require('internal/process/next_tick').setup();

And lib/internal/process/next_tick.js: 

    exports.setup = setupNextTick;

`setupNextTick` then does:

    const promises = require('internal/process/promises');
    ...
    const emitPendingUnhandledRejections = promises.setup(scheduleMicrotasks);

promises.setup will call process._setupPromises:

      process._setupPromises(function(event, promise, reason) {

Notice that this call takes an anonymous function as its callback. `_setupPromises` is configured in node.cc in the SetupProcessObject function:

    env->SetMethod(process, "_setupPromises", SetupPromises);

Lets set a break point in SetupPromis and see what is going on:

    (lldb) br s -f node.cc -l 1278
    (lldb) r


    isolate->SetPromiseRejectCallback(PromiseRejectCallback);

So an isolate has a `promise_reject_callback_` which is being set here to `PromiseRejectCallback`. This is what V8 will call if a promise is rejected.

    env->set_promise_reject_function(args[0].As<Function>());

Remember `_setupPromises` was passed an anonymous function as its callback argument which is what is being set as the
set_promise_reject_function on the evnvironment instance. This will then be used by `PromiseRejectCallback`:

    Local<Function> callback = env->promise_reject_function();
    ...
    callback->Call(process, arraysize(args), args);

Next things that happens in `SetupPromises` is that `_setupPromises` is deleted from the process object:

    env->process_object()->Delete(
      env->context(),
      FIXED_ONE_BYTE_STRING(args.GetIsolate(), "_setupPromises")).FromJust();

This way it cannot be called again.

Back in JavaScript (setupNextTick) now we have:

    var _runMicrotasks = {};
    ...
    const tickInfo = process._setupNextTick(_tickCallback, _runMicrotasks);

`process._setupNextTick` is also configured in node.cc:

    env->SetMethod(process, "_setupNextTick", SetupNextTick);

The arguments to SetupNextTick will be:

    CHECK(args[0]->IsFunction());  // _tickCallback
    CHECK(args[1]->IsObject());    // _runMicrotasks which is just an empty object at this point.

    env->set_tick_callback_function(args[0].As<Function>());
    env->SetMethod(args[1].As<Object>(), "runMicrotasks", RunMicrotasks);

RunMicroTasks does:
 
    void RunMicrotasks(const FunctionCallbackInfo<Value>& args) {
      args.GetIsolate()->RunMicrotasks();
    }
    
So we are setting a method on the _runMicrotasks object named runMicrotasks.
Next `_setupNextTick` is removed from the process object. Then we have:

    uint32_t* const fields = env->tick_info()->fields();
    uint32_t const fields_count = env->tick_info()->fields_count();
    Local<ArrayBuffer> array_buffer = ArrayBuffer::New(env->isolate(), fields, sizeof(*fields) * fields_count);
    args.GetReturnValue().Set(Uint32Array::New(array_buffer, 0, fields_count));

What are these? 

    const p = new Promise((resolve, reject) => {
      resolve('ok');
    });

So how are promises created in V8?

    (lldb) br s -f isolate.cc -l 1862

This will break in isolate.cc `PushPromise`:

    void Isolate::PushPromise(Handle<JSObject> promise) {
      ThreadLocalTop* tltop = thread_local_top();
      PromiseOnStack* prev = tltop->promise_on_stack_;
      Handle<JSObject> global_promise = global_handles()->Create(*promise);
      tltop->promise_on_stack_ = new PromiseOnStack(global_promise, prev);
    }    


Lets take a closer look at `new PromiseOnStack`:

    class PromiseOnStack {
     public:
      PromiseOnStack(Handle<JSObject> promise, PromiseOnStack* prev)
        : promise_(promise), prev_(prev) {}
      Handle<JSObject> promise() { return promise_; }
      PromiseOnStack* prev() { return prev_; }

     private:
      Handle<JSObject> promise_;
      PromiseOnStack* prev_;
    }; 

So that looks simple enough, it has a promise and a pointer to the previous promise. The callback passed to Promise (which
takes a resolve, reject), when is it called?
This is part of a constructor call so it would be executed straight way I think, like any constructor.


##### PromiseRejectCallback

    void PromiseRejectCallback(PromiseRejectMessage message) {
      Local<Promise> promise = message.GetPromise();
      Isolate* isolate = promise->GetIsolate();
      Local<Value> value = message.GetValue();
      Local<Integer> event = Integer::New(isolate, message.GetEvent());

      Environment* env = Environment::GetCurrent(isolate);
      Local<Function> callback = env->promise_reject_function();

      if (value.IsEmpty())
        value = Undefined(isolate);

      Local<Value> args[] = { event, promise, value };
      Local<Object> process = env->process_object();

      callback->Call(process, arraysize(args), args);
  }


After a module has been loaded in Module.runMain, the process._tickCallback function will first process all the 
callbacks in the nextTickQueue and then call _runMicrotasks(). 

#### nextTick
After resolving all the promises and callbacks added using nextTick will be called. 

    // bootstrap main module.
    Module.runMain = function() {
      // Load the main module--the command line argument.
      Module._load(process.argv[1], null, true);
      // Handle any nextTicks added in the first tick of the program
      process._tickCallback();
    };

### Libuv Thread pool 
The following modules use the thread pool:
* fs.*
* dns.lookup
  This is because when using a hostname to lookup there are operating system specific tasks that have to be 
  performed, like on unix /etc/hosts should be used etc.
* pipes
* crypto (crypto.randomBytes(), and crypto.pbkdf2())
* http.get/request() is called with a name in which case dns.loopup() is used
* any c++ addons that uses it

The follwing modules use the Kernel:
* tcp/udp sockets, servers
* unix domain sockets, servers
* pipes
* tty input
* dns.resolveXXX

The default size of the thread pool is 4 (uv_threadpool_size).
Just to be clear, the libuv Event Loop is single threaded. The thread pool is used for file I/O operations.



### SEGV_MAPERR
Is a segmentation fault, which is an invalid memory access. This can happen when trying to access a page
that is not mapped into the address space of the running process. This can happen when dereferencing a
null pointer or a pointer that was corrupted with a small integer value.

#### core dump
Make sure that you specified enough room for a core dump:

    $ ulimit -c unlimited

If possible compile the executable with debugging options. The example I'm using for this is a case where
cctest on arm7 produces a core dump:
    
    [----------] 2 tests from EnvironmentTest
    [ RUN      ] EnvironmentTest.AtExitWithEnvironment
    [       OK ] EnvironmentTest.AtExitWithEnvironment (114 ms)
    [ RUN      ] EnvironmentTest.AtExitWithArgument
    Received signal 11 SEGV_MAPERR 000007a0547c

    ==== C stack trace ===============================

    [end of stack trace]
    Segmentation fault (core dumped)
    

    $ gdb out/Debug/cctest qemu_cctest_20170809-174708_18638.core

    Reading symbols from out/Release/cctest...done.
    [New LWP 18638]
    [New LWP 18644]
    [New LWP 18645]
    [New LWP 18646]
    [Thread debugging using libthread_db enabled]
    Using host libthread_db library "/lib/arm-linux-gnueabihf/libthread_db.so.1".
    Core was generated by `out/Release/cctest'.
    #0  0x005e4f8c in v8::Context::Exit() ()

    (gdb) bt
    #0  0x005e4f8c in v8::Context::Exit() ()
    #1  0x01033d94 in node::Environment::Start(int, char const* const*, int, char const* const*, bool) ()
    #2  0x010395f4 in node::CreateEnvironment(node::IsolateData*, v8::Local<v8::Context>, int, char const* const*, int, char const* const*) ()
    #3  0x00e6087c in EnvironmentTest_AtExitWithArgument_Test::TestBody() ()
    #4  0x00eafb12 in testing::Test::Run() ()
    #5  0x00eafcfc in testing::TestInfo::Run() [clone .part.402] ()
    #6  0x00eafde0 in testing::TestCase::Run() [clone .part.403] ()
    #7  0x00eb15b0 in testing::internal::UnitTestImpl::RunAllTests() [clone .part.407] ()
    #8  0x00eb17e6 in testing::UnitTest::Run() ()
    #9  0x004302dc in main ()

I was not able to reproduce this issue when compiling with debugging symbols (./configure --debug). Possible reasons for this?
The debugger puts more on the stack and if you overwrite an arrays capacity it migth cause a segment fault in release mode but
not in debug mode.

Trying to find out where v8::Context::Exit() is call when in node::Environment::Start. Upon entry there is the following:

    Context::Scope context_scope(context());

This is the context scope used and this is using RAII, and the descructor that will be called when this instance goes out
of scope looks like this (in v8.h):

    V8_INLINE ~Scope() { context_->Exit(); }


### Workaround issue with test/async-hooks/init-hooks.js

    $ launchctl unload -w /System/Library/LaunchAgents/com.apple.ReportCrash.plist
    $ sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.ReportCrash.Root.plist


### node-gyp
How does node-gyp work?


### LIKELY/UNLIKELY
If you take a look at the CHECK macro you will se that it is defined like this:
   
    #define CHECK(expr)                                                         \
    do {                                                                        \
      if (UNLIKELY(!(expr))) {                                                  \
        static const char* const args[] = { __FILE__, STRINGIFY(__LINE__),      \
                                            #expr, PRETTY_FUNCTION_NAME };      \
        node::Assert(&args);                                                    \
      }                                                                         \
    } while (0)

And UNLIKELY is defined as:

    #define UNLIKELY(expr) __builtin_expect(!!(expr), 0)

This is done to give the compiler a hint that we expect the value to be true so it 
can optimise for that case and not the opposite case. 

### Context
Allows separate unrelated JavaScript to run in an isolate without interfering with each other.
What does that mean for a C++ function that is called by javascript. The context should be the
one associated with the call. 


### Tracing
Tracing refers to tracing events that can be emitted by V8. V8 takes a `--enable-tracing` flag which enables
tracing and will create a v8_trace.json file. This file can be opened in chrome and inspected using
`chrome://tracing`

This can also be enabled in Node using `--trace-events-enabled` and you can specify categories to be traced 
using `--trace-event-categories`. 


### Microsoft Build Engine (MSBuild)
Is a build platform that allows for an xml configuration file to configure and run complex build systems. 
This is what is produced by gyp for windows (the project file I mean). So you can take a look at the project
file for the specific gyp target and see what shows up where in it to troubleshoot configuration issues.

A target is like a procedure. A target can contain properties in a PropertiesGroup and tasks.
A task is like a builtin function that performs an action, compiles, links, prints a message etc.
A project is what hooks tasks together. A task can have a `DefaultTargets` attribute which are the targets
that will be run if you specify the project file on the command line for msbuild.

    msbuild sample.vcxproj 

The target can also be specified on the command line:

    msbuild sample.vcxproj /t:something
    msbuild sample.vcxproj /t:Clean;Build
    
In the xml you might come across something like: %(AdditionalOptions). This an iterate directive.

You can increase the level of information provided by msbuild by specifying the /verbosity setting:
quit, minimal, normal, detailed, and diagnostic.

Options:
/MP  Compile multiple sources by using multiple processes
/link passes the specified option to LINK


### vcbuild.bat
This is the Windows batch script that is used on Windows systems.

    vcbuild.bat /help

%var%   replaced with the environment variable named 'var'.
%n      where n is a number from 0-9 and gives access to the n argument passed on the command line.
%*      all the arguments specified on the command line

You can place quotation marks around a string to avoid escaping.
You can place caret (^), an escape character, immediately before the special characters
The special characters that need quoting or escaping are usually <, >, |, &, and ^
echo "You & me"
echo You ^& me

cd %~dp0        this will to %~dp (the directory of) on %0 (the first command line argument). 
                So if this is run from a diferent directory this will switch to the directory where
                this script is.

if /i           case-insensitive, for example:

     if /i "%1"=="help" goto help


Configuring on windows:

    python configure --openssl-system-ca-path=PATH
    vcbuild noprojgen

#### Compiler
`cl.exe` is the the compiler.

    cl -help 

#### Scripting
`%~1`          removes quotes from the first command line argument

Use `NUL` to discard out put, as in comman > NUL

    IF "%var%"=="" (SET var=something)

of 

    IF NOT DEFINED var (SET var=something)


    IF /I "%ERRORLEVEL%" NEQ "0" (
      echo "failed to execute something"
    )


### Performace counters
Are used used to provide information as to how well the operating system or an application is performing.

### DTrace
is supported on linux, solaris, mac, and bsd and is a tracing framework originally developed for Solaris
by Sun.
This is enabled by configuring with the `--with-dtrace` flag. There are three object files for dtrace in 
Node. These are: 
node_dtrace.o which is used by all systems that support dtrace  
node_dtrace_ustack.o is not supported on linux or mac  
node_dtrace_provider.o is supported on all but macosx  
Note that the directory where node_dtrace_provider.o is generated differs so if you are working on a task
that effects linking take that into account.

### Event Tracing for Windows (ETW)
Is an efficient kernel level tracing mechanism allowing logging of kernel or application defined events to
a log file. It also allows dynamic enable/disable so this can be performed on a running application.

An event provider writes events to an ETW session. Additional data is added by ETW like the time the event
happened, the process that wrote it and the thread id, the processor number, the CPU usage data. This info
is then available to event consumers which are applications that read the log file or the consumer can listen
to realtime events and process them.

There is a condition in node.gypi that depends on `node_etw` which looks like this:

    [ 'node_use_etw=="true"', {
      'defines': [ 'HAVE_ETW=1' ],
      'dependencies': [ 'node_etw' ],
      'sources': [
        'src/node_win32_etw_provider.h',
        'src/node_win32_etw_provider-inl.h',
        'src/node_win32_etw_provider.cc',
        'src/node_dtrace.cc',
        'tools/msvs/genfiles/node_etw_provider.h',
        'tools/msvs/genfiles/node_etw_provider.rc',
      ]
    } ],

So remember that `node_etw` will be run first so lets take a look at it first.

    # generate ETW header and resource files
    {
      'target_name': 'node_etw',
      'type': 'none',
      'conditions': [
        [ 'node_use_etw=="true"', {
          'actions': [
            {
              'action_name': 'node_etw',
              'inputs': [ 'src/res/node_etw_provider.man' ],
              'outputs': [
                'tools/msvs/genfiles/node_etw_provider.rc',
                'tools/msvs/genfiles/node_etw_provider.h',
                'tools/msvs/genfiles/node_etw_providerTEMP.BIN',
              ],
              'action': [ 'mc <@(_inputs) -h tools/msvs/genfiles -r tools/msvs/genfiles' ]
            }
          ]
        } ]
      ]
    },

`mc` is the [Message Compiler](https://msdn.microsoft.com/en-us/library/windows/desktop/aa385638(v=vs.85).aspx).  
`-h` is where you want the generated header files to be placed.  
`-r` is where you want the generated resource compiler script (.rc file) and the generated binary resource file (.bin)  
The node_etw_providerTEMP.bin is a binary resource file that contains the provider and event metadata. This is the
template resource, which is signified by the TEMP suffix of the base name of the file.

And the input is the manifest file (.man). The manifest registers an event producer named `NodeJS-ETW-provider`:

    <provider name="NodeJS-ETW-provider"
        guid="{77754E9B-264B-4D8D-B981-E4135C1ECB0C}"
        symbol="NODE_ETW_PROVIDER"
        message="$(string.NodeJS-ETW-provider.name)"
        resourceFileName="node.exe"
        messageFileName="node.exe">

Notice the `message` attribute which is used for localization which will be matched with :

    <localization>
        <resources culture="en-US">
            <stringTable>
                <string id="NodeJS-ETW-provider.name" value="Node.js ETW Provider"/>


Tasks are typically used to identify major components of the provider, some form of grouping.
In node there is one task:

    <task name="MethodRuntime" value="1" symbol="JSCRIPT_METHOD_RUNTIME_TASK">
        <opcodes>
            <opcode name="MethodLoad" value="10" symbol="JSCRIPT_METHOD_METHODLOAD_OPCODE"/>
        </opcodes>
    </task> 

This grouping enables consumers to query only for specific tasks and opcode combinations. The opcodes
are specific to the task `MethodRuntime`. But there are also global opcodes:

    <opcodes>
        <opcode name="NODE_HTTP_SERVER_REQUEST" value="10"/>
        <opcode name="NODE_HTTP_SERVER_RESPONSE" value="11"/>
        <opcode name="NODE_HTTP_CLIENT_REQUEST" value="12"/>
        <opcode name="NODE_HTTP_CLIENT_RESPONSE" value="13"/>
        <opcode name="NODE_NET_SERVER_CONNECTION" value="14"/>
        <opcode name="NODE_NET_STREAM_END" value="15"/>
        <opcode name="NODE_GC_START" value="16"/>
        <opcode name="NODE_GC_DONE" value="17"/>
        <opcode name="NODE_V8SYMBOL_REMOVE" value="21"/>
        <opcode name="NODE_V8SYMBOL_MOVE" value="22"/>
        <opcode name="NODE_V8SYMBOL_RESET" value="23"/>
    </opcodes>

Templates are used to define event specific data that the provider includes with an event. For example in
node one template looks like this:

    <template tid="node_connection">
      <data name="fd" inType="win:UInt32" />
      <data name="port" inType="win:UInt32" />
      <data name="remote" inType="win:AnsiString" />
      <data name="buffered" inType="win:UInt32" />
   </template>

Events have to be defined and can refer to template like the following:

    <event value="2" 
      opcode="NODE_HTTP_SERVER_RESPONSE"
      template="node_connection"
      symbol="NODE_HTTP_SERVER_RESPONSE_EVENT"
      message="$(string.NodeJS-ETW-provider.event.2.message)"
      level="win:Informational"/>

Ok, so we can see how the provider and events are configured. This information is used by the `mc` tool
to generate headers and a binary file.

The provider headers is in src/node_win32_etw_provider.h. For each of the opcodes there are function declarations
and init_etw() and shutdown_etw(). There is an internal header `src/node_win32_etw_provider-inl.h` which includes
the generated `node_etw_provider.h` which is located in 'tools/msvs/genfiles/node_etw_provider.h'.

### Performace counters 
Are used to provide information how node is performing.
There is condition in node.gypi that depends on `node_perfctr` which looks like this:

    [ 'node_use_perfctr=="true"', {
      'defines': [ 'HAVE_PERFCTR=1' ],
      'dependencies': [ 'node_perfctr' ],
      'sources': [
        'src/node_win32_perfctr_provider.h',
        'src/node_win32_perfctr_provider.cc',
        'src/node_counters.cc',
        'src/node_counters.h',
        'tools/msvs/genfiles/node_perfctr_provider.rc',
      ]
    } ],

This file is used in the `node_perfctr` (node performance counter) target and it is an action target that invokes `ctrpp`
The input to ctrpp is src/res/node_perfctr_provider.man

    {
      'action_name': 'node_perfctr_man',
      'inputs': [ 'src/res/node_perfctr_provider.man' ],
      'outputs': [
         'tools/msvs/genfiles/node_perfctr_provider.h',
         'tools/msvs/genfiles/node_perfctr_provider.rc',
         'tools/msvs/genfiles/MSG00001.BIN',
      ],
      'action': [ 'ctrpp <@(_inputs) '
        '-o tools/msvs/genfiles/node_perfctr_provider.h '
        '-rc tools/msvs/genfiles/node_perfctr_provider.rc'
      ]
    },

`-o`  specifies the header that will be generated.
`-rc` specifies the file that will be generated.

'src/node_win32_perfctr_provider.cc' includes `node_perfctr_provider.h`
Notice this this is much like the ETW and manifest based. Lets look at the manifest. Instead of containing events this
file contains counters.
The MSG00001.BIN file is a binary resource file for each language you specify (only one in our case).

But when is the actual .res file created?  
I can see these are part of the statically linked library:

    dumpbin /archivemembers Release/lib/node.lib

I can see that path is Release\obj\node\node_etw_provider.res and Release\obj\node\node_perfctr_provider.res. 
Do these files somehow refer to node.lib causing /WHOLEARCHIVE to fail?
Is there some way to exclude object from the lib specified by /WHOLEARCHIVE?
A .res file is a compiled resource file generated by rc.exe. By default this is created in the same directory as the .rc file.

### CTRPP
The CTRPP tool is a pre-processor that parses and validates your counters manifest. The tool also generates code that you use to provide your counter data. 

### Tracker.exe
Scans .tlog files to figure out what a projects output files are. This is used to know if something should be updated/recompiled I guess. Adding this as
you might come across an issue on windows where the last things that is logged is output from the tracker but infact if there is a link error this would 
not be something that the tracker would report, so you'll need to look further back in the console output. 

### Inspecting a .lib on windows

    DUMPBIN /ARCHIVEMEMBERS Release\lib\node.lib

### Linux Trace Toolkit: next generation (lttng)
LTTng is an open source tracing framework for Linux.


Does it make sense to have the node.res file when node is linked as a static library? Would'nt the case be that the icon and other resource info
be that of the embedders.

But out about the ETW and performance counters resources?
Resources (as far as I can tell) are intended to be linked to the exe or a dynamic library. It does not seem like it is possible to add 


### Node executable linking
By default, just building node using ./configure && make -j8 the node executable will be statically linked:

    $ otool -L out/Debug/node
    out/Debug/node:
      /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 1259.11.0)
      /usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1226.10.1)
      /usr/lib/libc++.1.dylib (compatibility version 1.0.0, current version 120.1.0)

### GYP
For addon tests in node there can be the need to link against a library in the root directory. The problem is that you cannot use <(PRODUCT_DIR) as
that is the product dir for the addon itself. There is also the issue that the output directory is different on windows, it is not `out` but instead
the `Release` and `Debug` directories are in the root of the project. But there are variables available by the respective node-gyp evironments, 
for example on Window you can use:

    ['OS=="win"', {
      'libraries': ['../../../../$(Configuration)/lib/zlib.lib'],
    }, {
      'libraries': ['../../../../out/$(BUILDTYPE)/libzlib.a'],
    }],


### serdes
This is a built in module for serialization/deserialization which is currently marked as experimental.
It allows for serializing JavaScript values in a way compatiable with https://developer.mozilla.org/en-US/docs/Web/API/Web_Workers_API/Structured_clone_algorithm, 
which an algorithm for copying complex JavaScript objects and used internally for transferring data to and from Web Workers view postMessage().


### Failing test without network connection
```
make[1]: Leaving directory `/root/rpmbuild/BUILD/node-v8.7.0'
/usr/bin/python2.7 tools/test.py --mode=release -J \
async-hooks \
abort doctool es-module inspector known_issues message parallel pseudo-tty sequential \
addons addons-napi
=== release test-dgram-membership ===
Path: parallel/test-dgram-membership
assert.js:41
  throw new errors.AssertionError({
  ^

AssertionError [ERR_ASSERTION]: Got unwanted exception.
    at innerThrows (assert.js:653:7)
    at Function.doesNotThrow (assert.js:665:3)
    at Object.<anonymous> (/root/rpmbuild/BUILD/node-v8.7.0/test/parallel/test-dgram-membership.js:83:10)
    at Module._compile (module.js:624:30)
    at Object.Module._extensions..js (module.js:635:10)
    at Module.load (module.js:545:32)
    at tryModuleLoad (module.js:508:12)
    at Function.Module._load (module.js:500:3)
    at Function.Module.runMain (module.js:665:10)
    at startup (bootstrap_node.js:187:16)
Command: out/Release/node /root/rpmbuild/BUILD/node-v8.7.0/test/parallel/test-dgram-membership.js
=== release test-dgram-multicast-set-interface-lo ===
Path: parallel/test-dgram-multicast-set-interface-lo
assert.js:41
  throw new errors.AssertionError({
  ^

AssertionError [ERR_ASSERTION]: undefined == true
    at Object.<anonymous> (/root/rpmbuild/BUILD/node-v8.7.0/test/parallel/test-dgram-multicast-set-interface-lo.js:64:8)
    at Module._compile (module.js:624:30)
    at Object.Module._extensions..js (module.js:635:10)
    at Module.load (module.js:545:32)
    at tryModuleLoad (module.js:508:12)
    at Function.Module._load (module.js:500:3)
    at Function.Module.runMain (module.js:665:10)
    at startup (bootstrap_node.js:187:16)
    at bootstrap_node.js:608:3
Command: out/Release/node /root/rpmbuild/BUILD/node-v8.7.0/test/parallel/test-dgram-multicast-set-interface-lo.js
[03:09|% 100|+ 1893|-   2]: Done
```

### Trouble shooting DNS issue on RHEL
BIND (the NameServer) consists of a set of dns related programs. The nameserver itself is called named. There is
an admin tool named rdnc and dig or debugging.
named reads it's configuration from /etc/named.conf.

#### /etc/nsswitch.conf
Before this configuration file existed name service lookups were hardcoded into the c library, as well as the search order. 
Name Service Switch was introduced by Sun Microsystems in there C library implementation in Solaris 2. This uses modules
which allowes for adding new services without adding them to the GNU C library.


‘unavail’
The service is permanently unavailable. This can either mean the needed file is not available, or, for DNS, the server 
is not available or does not allow queries. The default action is continue.

For the hosts and networks databases the default value is dns [!UNAVAIL=return] files. I.e., the system is prepared for 
the DNS service not to be available but if it is available the answer it returns is definitive.


Regarding test/parallel/test-net-connect-immediate-finish.js and test/parallel/test-net-better-error-messages-port-hostname.js the and the error:
Path: parallel/test-net-connect-immediate-finish
assert.js:41
  throw new errors.AssertionError({
  ^
AssertionError [ERR_ASSERTION]: 'EAI_AGAIN' === 'ENOTFOUND'
    at Socket.client.once.common.mustCall (/builddir/build/BUILD/node-v8.6.0/test/parallel/test-net-connect-immediate-finish.js:35:10)
    at Socket.<anonymous> (/builddir/build/BUILD/node-v8.6.0/test/common/index.js:514:15)
    at Object.onceWrapper (events.js:316:30)
    at emitOne (events.js:115:13)
    at Socket.emit (events.js:210:7)
    at emitErrorNT (internal/streams/destroy.js:64:8)
    at _combinedTickCallback (internal/process/next_tick.js:138:11)
    at process._tickCallback (internal/process/next_tick.js:180:9)
Command: out/Release/node /builddir/build/BUILD/node-v8.6.0/test/parallel/test-net-connect-immediate-finish.js

This only occurs when there is no available dns (you might need to comment it out in /etc/resolve.conf to reproduce this), I manually update /etc/nsswitch.conf and the update the hosts entry:

    hosts:      files dns

Notice that the last entry is dns which so it will return the result which will be 
Using the default (at least this is the default for the RHEL version that we are using in our image: registry.access.redhat.com/rhel7) this error does not occur as the default is:

hosts:      files dns myhostname

Since this is an external configuration that could be different for different installations I think the best option is to update the test to be able to handle this situation. 
I'll create a pull request and see what people think.



$ networksetup -listallnetworkservices
$ networksetup -getinfo "Thunderbolt Ethernet"
DHCP Configuration
IP address: 10.0.0.2
Subnet mask: 255.255.255.0
Router: 10.0.0.1
Client ID:
IPv6: Automatic
IPv6 IP address: none
IPv6 Router: none
Ethernet Address: 68:5b:35:84:c8:9c

What is this test about?:
test/parallel/test-regress-GH-819.js

### Modules


### Inspector console
In the start function of lib/internal/bootstrap_node.js we have a function that sets up the inspector console.
After the global console object is set up, it is passed to setupInspector(originalConsole, wrappedConsole, Module);
It does so with the help of a builtin module 'inspector' which can be found in src/inspector_js_api.cc.

    const { addCommandLineAPI, consoleCall } = process.binding('inspector');


    wrappedConsole[key] = consoleCall.bind(wrappedConsole,
                                           originalConsole[key],
                                           wrappedConsole[key],
                                           config);

The above will create a new function which has its `this` set to wrappedConsole

    $ out/Debug/node
    [Function: log] [Function: bound log] {}
    [Function: info] [Function: bound log] {}
    [Function: warn] [Function: bound warn] {}
    [Function: error] [Function: bound warn] {}
    [Function: dir] [Function: bound dir] {}
    [Function: time] [Function: bound time] {}
    [Function: timeEnd] [Function: bound timeEnd] {}
    [Function: trace] [Function: bound trace] {}
    [Function: assert] [Function: bound assert] {}
    [Function: clear] [Function: bound clear] {}
    [Function: count] [Function: bound count] {}
    [Function: group] [Function: bound group] {}
    [Function: groupCollapsed] [Function: bound group] {}
    [Function: groupEnd] [Function: bound groupEnd] {}

So for all of the above functions they will now got through the ConsoleCall function in inspector_agent.cc which will check if the inspector is enabled, which is done by passing --inspect,  for this process:

    if (env->inspector_agent()->enabled()) {
      ...
    }

In this case the writing to stdout will be performed twice, once to the inspector using:

    inspector_method.As<Function>()->Call(context,
                                          info.Holder(),
                                          call_args.size(),
                                          call_args.data()).IsEmpty());

For example you'll seen the output in both stdout and in chrome's console.



The test that I'm currently looking at uses fork so there will be two processes. This means that you might
not hit a break point if you just use lldb on the command line. Instead you have to:

    (lldb)

### ccache

    $ git clone https://github.com/ccache/ccache.git
    $ cd ccache
    $ ./autogen.sh
    $ ./configure && make 

Add ccache to your PATH. 

    export CC="ccache clang -Qunused-arguments"
    export CXX="ccache clang++ -Qunused-arguments"

Now you can configure and build as normal.

To see what is in the cache:

   $ ccache -s

To clear the cache:

   $ ccache -C 


### GetPeerCertificate

    STACK_OF(X509)* ssl_certs = SSL_get_peer_cert_chain(w->ssl_);

STACK_OF is a macro defined in deps/openssl/openssl/crypto/stack/safestack.h and will expand to:

    struct stack_st_X509* ssl_certs = SSL_get_peer_cert_chain(w->ssl_);


A Local<Object> instance holds a pointer to an Object. If you pass this instance to a function a copy of the 
object will be created. But both instance will point to the same object. But what ever we do to the copy there
caller instance will still point to the same location, but if we update the value that it point to it should work ?

For example:

    static void AddIssuer(X509** cert,
                          const STACK_OF(X509)* const peer_certs,
                          Local<Object> info,
                          Environment* const env) {

    ...
    Local<Object> ca_info = X509ToObject(env, ca);
    // Now we want to update what info points to so that is points to the value of ca_info instead.


           Local<Object>

    (lldb) expr info
    (v8::Local<v8::Object>) $4 = (val_ = 0x0000000106014b08)
    (lldb) expr *info
    (v8::Object *) $6 = 0x0000000106014b08


The copy constructor for Local<> will copy the value, which includes the pointer so these are separate
objects:

    (lldb) p &result
    (v8::Local<v8::Object> *) $86 = 0x00007fff5fbf04b0
    (lldb) p &info
    (v8::Local<v8::Object> *) $87 = 0x00007fff5fbf04a8

But what is info supposed to represent?
Well they both initially point to the same thing as we can see but as mentioned they are separate objects. So the following will update what they both (result and info) point to:

    Local<Object> ca_info = X509ToObject(env, ca);
    info->Set(env->issuercert_string(), ca_info);

But the following will cause info to copy constructed (I think) to ca_info so the connection with result is lost here. That is incorrect!
What is happening is that the first time info == result so the issuer is set on it, and it contains the ca_info instance. So result can get to it. Next when info is set to ca_info:

    info = ca_info;

This is for the next iteration and if there are more they will be chained to ca_info using the info->Set(env->issuercert_string(), ca_info), which remember can be accessed from result via its issuercert_string property. 

result -> #issuercertificate -> ca_info -> #issuercerficate -> ca_info

If this is not done result will not be linked to them all and the chain broken.
