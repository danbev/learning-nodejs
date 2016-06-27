### Learning Node.js
The sole purpose of this project is to aid in learning Node.js internals.

## Prerequisites
You'll need to have checked out the node.js source.

### Compiling node with debug enbled:

    $ ./configure --debug
    $ make -C out BUILDTYPE=Debug

After compiling (with debugging enabled) start node using lldb:

    $ cd node/out/Debug
    $ lldb ./node

Node used Generate Your Projects (gyp) for which I was not familare with so there is a 
example project in [gyp](./gyp) to look into it.

#### Compiling with a different version of libuv
What I'd like to do is use my local fork of libuv instead of the one in the deps
directory. I think the way to do this is to `make install` and then run configure with the following options:

    $ ./configure --debug --shared-libuv --shared-libuv-includes=/usr/local/include

The location of the library is `/usr/local/lib`, and `/usr/local/include` for the headers on my machine.

### Starting Node
To start and stop at first line in a js program use:

    $ lldb -- node --debug-brk test.js

Set a break point in node_main.cc:

    (lldb) breakpoint set --file node_main.cc --line 52
    (lldb) run

### Walkthrough
'node_main.cc will bascially call node::Start which we can find in src/node.cc.

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

Now I've not used `uv_async_init` but looking a the docs this is done to allow a different thread to wake up the event loop and have the
callback invoked. uv_async_init looks like this:

    int uv_async_init(uv_loop_t* loop, uv_async_t* async, uv_async_cb async_cb)

To understand this better this standalone [example](https://github.com/danbev/learning-libuv/blob/master/thread.cc) helped my clarify things a bit.

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

    p *(char(*)[1]) new_v8_argv

This is something that I've not seen before either:

    if (v8_is_profiling) {
        uv_loop_configure(uv_default_loop(), UV_LOOP_BLOCK_SIGNAL, SIGPROF);
    }

What does uv_loop_configure do?
It sets additional loop options. This [example](https://github.com/danbev/learning-libuv/blob/master/configure.cc) was used to look a little closer 
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

The last nullprt is the oldset which can be stored (if it was not null that is)

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
This is where we signal the semaphore which will increment the counter, and any threads in the wait queue will no run. So our thread that is
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
and in the hello_world the nog arguments method was called. I only skimmed this part when I was working through that 
example so it might be good to figure out what is going on here.
An instance of DefaultPlatform is created and then its SetThreadPoolSize method is called with v8_thread_pool_size. When
the size is not given it will default to `p SysInfo::NumberOfProcessors()`. 
Next, EnsureInitialized is called which does a check to see if the instance has already been initilized and if not:

     for (int i = 0; i < thread_pool_size_; ++i)
       thread_pool_.push_back(new WorkerThread(&queue_));

This will create new workers and threads for them. This call finds its was down into deps/v8/src/base/platform/platform-posix.c
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

After setting up all the object (SetupProcessObject) this methods returns. There is still no sign of the loading of the 'node.js' script. 
This is done in LoadEnvironment.

#### LoadEnvironment

    Local<String> script_name = FIXED_ONE_BYTE_STRING(env->isolate(), "bootstrap_node.js");

#### lib/internal/bootstrap_node.js
This is the file that is loaded by LoadEnvironment as "bootstrap_node.js". 
I read that this file is actually precompiled, where/how?

This file is referenced in node.gyp and is used with the target node_js2c. This target calls tools/js2c.py which is a tool for converting 
JavaScript source code into C-Style char arrays. This target will process all the library_files specified in the variables section which 
lib/internal/bootstrap_node.js is one of. The output of this out/Debug/obj/gen/node_natives.h, depending on the type of build being performed. 
So lib/internal/bootstrap_node.js will beccome internal_bootstrap_node_native in node_natives.h. 
This is then later included in src/node_javascript.cc 

We can see the contents of this in lldb using:

    (lldb) p internal_bootstrap_node_native

Notes:
When Node.js starts up it does many things similar to what we did in our hello-world
example. After intializing the Platform it need to inject objects, for example the
'process' object. V8 brings the complete JavaScript engine and environement with all
the builtin objects, but Node.js is more than that. All the additional functionality 
that Node.js brings (https://nodejs.org/docs/latest/api/index.html) are also available.


### Running jslint

    $ make jslint

### Running tests
To run the test use the following command:

    $ make -j4 test

The -j is the number of processes to use.

#### Mac firewall exceptions
On mac you might find it popping up dialogs about the firwall blocking access to the `node` and `cctest` applications when running
the tests. You can add exceptions by pointing to the `node/node` executable and `node/out/Release/cctest`. Just adding this 
comment as it was not obvious at the time which node executable to exclude.


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



