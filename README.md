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

#### Compiling with a different version of libuv
What I'd like to do is use my local fork of libuv instead of the one in the deps
directory. I think the way to do this is to `make install` and then run configure with the following options:

    $ ./configure --debug --shared-libuv --shared-libuv-includes=/usr/local/include

The location of the library is `/usr/local/lib`, and `/usr/local/include` for the headers on my machine.


### Running the Node.js tests

    $ make -j4 test

### Updating addons test
Some of the addons tests are not version controlled but instead generate using:

   $ ./node tools/doc/addon-verify.js doc/api/addons.md

The source for these tests can be found in `doc/api/addons.md` and these might need to be updated if a 
change to all tests is required, for a concrete example we wanted to update the build/Release/addon directory
to be different depending on the build type (Debug/Release) and I forgot to update these tests.

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


### Environment

    (node::Environment) $30 = {
	  isolate_ = 0x0000000104803c00
	  isolate_data_ = 0x00007fff5fbfdd98
	  immediate_check_handle_ = {
	    data = 0x00000001020ecc2f
	    loop = 0x00000001020bc0d0
	    type = UV_CHECK
	    close_cb = 0x0000000000000002
	    handle_queue = ([0] = 0x00007fff5fbfe1b0, [1] = 0x0000000103d01090)
	    u = {
	      fd = 1606526224
	      reserved = ([0] = 0x00007fff5fc1a510, [1] = 0x00000001020ecc2f, [2] = 0x5800000000000000, [3] = 0x00007fff5fc2c28d)
	    }
	    next_closing = 0x0000000000000000
	    flags = 0
	    check_cb = 0x0000000000000000
	    queue = ([0] = 0x00000001020ecc2f, [1] = 0x00007fff5fc395c8)
	  }
	  immediate_idle_handle_ = {
	    data = 0x00007fff9171c119
	    loop = 0x00000001020bc0d0
	    type = UV_IDLE
	    close_cb = 0x0000000000000000
	    handle_queue = ([0] = 0x00007fff5fbfe228, [1] = 0x00007fff5fbfe138)
	    u = {
	      fd = 225
	      reserved = ([0] = 0x00000000000000e1, [1] = 0x0000000000000000, [2] = 0x0000003000000018, [3] = 0x00007fff5fbfe8e0)
	    }
	    next_closing = 0x0000000000000000
	    flags = 8192
	    idle_cb = 0x0000000000000000
	    queue = ([0] = 0x00007fff9171c262, [1] = 0x000000000000037f)
	  }
	  idle_prepare_handle_ = {
	    data = 0x0000000000000000
	    loop = 0x00000001020bc0d0
	    type = UV_PREPARE
	    close_cb = 0x0000000000000000
	    handle_queue = ([0] = 0x00007fff5fbfe2a0, [1] = 0x00007fff5fbfe1b0)
	    u = {
	      fd = 65535
	      reserved = ([0] = 0x000000000000ffff, [1] = 0x0000000000000000, [2] = 0x0000000000000000, [3] = 0x0000000000000000)
	    }
	    next_closing = 0x0000000000000000
	    flags = 0
	    prepare_cb = 0x0000000000000000
	    queue = ([0] = 0x0000000000000000, [1] = 0x000000000000ffff)
	  }
	  idle_check_handle_ = {
	    data = 0x000000000163d327 91091
	    loop = 0x00000001020bc0d0
	    type = UV_CHECK
	    close_cb = 0x000000000000ffff
	    handle_queue = ([0] = 0x00007fff5fbfe330, [1] = 0x00007fff5fbfe228)
	    u = {
	      fd = 0
	      reserved = ([0] = 0x41f0000000000000, [1] = 0x0000000000000000, [2] = 0xfff0000000000000, [3] = 0x0000000000000000)
	    }
	    next_closing = 0x0000000000000000
	    flags = 0
	    check_cb = 0x0000000000000000
	    queue = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
	  }
	  async_hooks_ = {
	    fields_ = ([0] = 0)
	  }
	  domain_flag_ = {
	    fields_ = ([0] = 0)
	  }
	  tick_info_ = {
	    fields_ = ([0] = 1, [1] = 1)
	  }
	  timer_base_ = 35071002
	  cares_timer_handle_ = {
	    data = 0x0000000000000000
	    loop = 0x00000001020bc0d0
	    type = UV_TIMER
	    close_cb = 0x00007fff5fbfe460
	    handle_queue = ([0] = 0x0000000103a08d70, [1] = 0x00007fff5fbfe2a0)
	    u = {
	      fd = -1
	      reserved = ([0] = 0xffffffffffffffff, [1] = 0x0000000000000000, [2] = 0x00007fff5fbfe440, [3] = 0x00007fff9dd486c1)
	    }
	    next_closing = 0x0000000000000000
	    flags = 8192
	    timer_cb = 0x0000000000000000
	    heap_node = ([0] = 0x0000000000000000, [1] = 0x0000000000000000, [2] = 0x0000000000000000)
	    timeout = 0
	    repeat = 0
	    start_id = 0
	  }
	  cares_channel_ = 0x0000000104862a00
	  cares_task_list_ = {
	    rbh_root = 0x0000000000000000
	  }
	  using_domains_ = false
	  printed_error_ = false
	  trace_sync_io_ = false
	  makecallback_cntr_ = 1
	  async_wrap_uid_ = 5
	  debugger_agent_ = {
	    state_ = kNone
	    host_ = ""
	    port_ = 5858
	    wait_ = false
	    start_sem_ = 6915
	    message_mutex_ = {
	      mutex_ = (__sig = 1297437784, __opaque = char [56] @ 0x00007fbdf8fd2300)
	    }
	    child_signal_ = {
	      data = 0x00007fff5fbfe640
	      loop = 0x00007fff9dd2c90d
	      type = UV_UNKNOWN_HANDLE
	      close_cb = 0x00000001016cf371 ("native function %s();")
	      handle_queue = ([0] = 0x0000000103a05416, [1] = 0x0000001c00000000)
	      u = {
		fd = -65016
		reserved = ([0] = 0x00000000ffff0208, [1] = 0x0000000103a05401, [2] = 0x0000000000000031, [3] = 0x0000000000000000)
	      }
	      next_closing = 0x0000000000000000
	      flags = 0
	      async_cb = 0x0000000000000000
	      queue = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
	      pending = 0
	    }
	    thread_ = 0x0000000000000000
	    parent_env_ = 0x00007fff5fbfe108
	    child_env_ = 0x0000000000000000
	    child_loop_ = {
	      data = 0x0000000000000000
	      active_handles = 0
	      handle_queue = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
	      active_reqs = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
	      stop_flag = 0
	      flags = 0
	      backend_fd = 0
	      pending_queue = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
	      watcher_queue = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
	      watchers = 0x0000000000000000
	      nwatchers = 850045858
	      nfds = 0
	      wq = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
	      wq_mutex = (__sig = 0, __opaque = char [56] @ 0x00007fbdf8fd2460)
	      wq_async = {
		data = 0x0000000000000000
		loop = 0x0000000000000000
		type = UV_UNKNOWN_HANDLE
		close_cb = 0x0000000000000000
		handle_queue = ([0] = 0x0000000000000000, [1] = 0x0000000000000000)
		u = {
		  fd = 0
		  reserved = ([0] = 0x0000000000000000, [1] = 0x0000000000000000, [2] = 0x0000000000000000, [3] = 0x0000000000000000)
		}
		next_closing = 0x0000000000000000
		flags = 0
		async_cb = 0x0000000000000000
		queue = ([0] = 0x0000000000000000, [1] = 0x25005f840b8bedf7)
		pending = 1606412464
	      }
	      cloexec_lock = (__sig = 4355806209, __opaque = char [192] @ 0x00007fbdf8fd2520)
	      closing_handles = 0x00000001016cf371
	      process_handles = ([0] = 0x0000000103a05401, [1] = 0x0000000000000032)
	      prepare_handles = ([0] = 0x00007fff5fbfe8d0, [1] = 0x0000000100fca44c)
	      check_handles = ([0] = 0x0000000000000000, [1] = 0x00007fff5fbfe8b0)
	      idle_handles = ([0] = 0x0000003200000015, [1] = 0x00000001016cf371)
	      async_handles = ([0] = 0x00000001016cf36e, [1] = 0x00000001016cf36e)
	      async_watcher = {
		cb = 0x00000000fffffff0
		io_watcher = {
		  cb = 0x0000000103a05401
		  pending_queue = ([0] = 0x0000000000000000, [1] = 0x0000ff0000000000)
		  watcher_queue = ([0] = 0x41f0000000000000, [1] = 0x0000000000000000)
		  pevents = 0
		  events = 4293918720
		  fd = 0
		  rcount = 0
		  wcount = 0
		}
		wfd = 0
	      }
	      timer_heap = (min = 0x0000000000000000, nelts = 0)
	      timer_counter = 4354165248
	      time = 3
	      signal_pipefd = ([0] = 59183104, [1] = 1)
	      signal_io_watcher = {
		cb = 0x0000000103878600
		pending_queue = ([0] = 0x0000000000000001, [1] = 0x0000000103a045a3)
		watcher_queue = ([0] = 0x00007fff5fbfe8c0, [1] = 0x00007fff90f14a26)
		pevents = 59183104
		events = 1
		fd = 59213312
		rcount = 1
		wcount = 5
	      }
	      child_watcher = {
		data = 0x0000000103a045a3
		loop = 0x00007fff5fbfe8f0
		type = -1863235034
		close_cb = 0x0000000000001006
		handle_queue = ([0] = 0x0000000000000010, [1] = 0x0000000000003c00)
		u = {
		  fd = 59197952
		  reserved = ([0] = 0x0000000103874a00, [1] = 0x00007fff5fbfe850, [2] = 0x0000000103a05588, [3] = 0x00007fff5fbfe860)
		}
		next_closing = 0x0000000103878600
		flags = 4102
		signal_cb = 0x0000000000000010
		signum = 1606412432
		tree_entry = {
		  rbe_left = 0x0000000000271ea7
		  rbe_right = 0x0000000000000001
		  rbe_parent = 0x000000000000002e
		  rbe_color = 4102
		}
		caught_signals = 60882943
		dispatched_signals = 1
	      }
	      emfile_fd = 1606412480
	      cf_thread = 0x0000000000000000
	      _cf_reserved = 0x0000000000000000
	      cf_state = 0x0000000000000000
	      cf_mutex = (__sig = 4354150400, __opaque = char [56] @ 0x00007fbdf8fd27b0)
	      cf_sem = 1606412560
	      cf_signals = ([0] = 0x00007fff90f130cc, [1] = 0x0000000103a05570)
	    }
	    api_ = {
	      v8::PersistentBase<v8::Object> = (val_ = 0x0000000000000000)
	    }
	    messages_ = {
	      head_ = {
		prev_ = 0x00007fff5fbfe910
		next_ = 0x00007fff5fbfe910
	      }
	    }
	    dispatch_handler_ = 0x0000000000000000
	  }
	  inspector_agent_ = {
	    impl = 0x0000000105003e00
	  }
	  handle_wrap_queue_ = {
	    head_ = {
	      prev_ = 0x00000001060015a8
	      next_ = 0x0000000103a08cd8
	    }
	  }
	  req_wrap_queue_ = {
	    head_ = {
	      prev_ = 0x00007fff5fbfe940
	      next_ = 0x00007fff5fbfe940
	    }
	  }
	  handle_cleanup_queue_ = {
	    head_ = {
	      prev_ = 0x0000000103a08388
	      next_ = 0x0000000103d01128
	    }
	  }
	  handle_cleanup_waiting_ = 0
	  heap_statistics_buffer_ = 0x0000000000000000
	  heap_space_statistics_buffer_ = 0x0000000000000000
	  http_parser_buffer_ = 0x0000000000000000 <no value available>
	  as_external_ = {
	    v8::PersistentBase<v8::External> = (val_ = 0x0000000105010820)
	  }
	  async_hooks_destroy_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000000000000)
	  }
	  async_hooks_init_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000000000000)
	  }
	  async_hooks_post_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000000000000)
	  }
	  async_hooks_pre_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000000000000)
	  }
	  binding_cache_object_ = {
	    v8::PersistentBase<v8::Object> = (val_ = 0x0000000105010840)
	  }
	  buffer_constructor_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000000000000)
	  }
	  buffer_prototype_object_ = {
	    v8::PersistentBase<v8::Object> = (val_ = 0x0000000105010a20)
	  }
	  context_ = {
	    v8::PersistentBase<v8::Context> = (val_ = 0x0000000105010800)
	  }
	  domain_array_ = {
	    v8::PersistentBase<v8::Array> = (val_ = 0x0000000000000000)
	  }
	  domains_stack_array_ = {
	    v8::PersistentBase<v8::Array> = (val_ = 0x0000000000000000)
	  }
	  fs_stats_constructor_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000105010fc0)
	  }
	  generic_internal_field_template_ = {
	    v8::PersistentBase<v8::ObjectTemplate> = (val_ = 0x0000000105010880)
	  }
	  jsstream_constructor_template_ = {
	    v8::PersistentBase<v8::FunctionTemplate> = (val_ = 0x0000000000000000)
	  }
	  module_load_list_array_ = {
	    v8::PersistentBase<v8::Array> = (val_ = 0x0000000105010860)
	  }
	  pipe_constructor_template_ = {
	    v8::PersistentBase<v8::FunctionTemplate> = (val_ = 0x0000000105011040)
	  }
	  process_object_ = {
	    v8::PersistentBase<v8::Object> = (val_ = 0x00000001050108a0)
	  }
	  promise_reject_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000105010c00)
	  }
	  push_values_to_array_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000105010940)
	  }
	  script_context_constructor_template_ = {
	    v8::PersistentBase<v8::FunctionTemplate> = (val_ = 0x00000001050108e0)
	  }
	  script_data_constructor_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x00000001050108c0)
	  }
	  secure_context_constructor_template_ = {
	    v8::PersistentBase<v8::FunctionTemplate> = (val_ = 0x0000000000000000)
	  }
	  tcp_constructor_template_ = {
	    v8::PersistentBase<v8::FunctionTemplate> = (val_ = 0x0000000105010ee0)
	  }
	  tick_callback_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000105010c20)
	  }
	  tls_wrap_constructor_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000000000000)
	  }
	  tls_wrap_constructor_template_ = {
	    v8::PersistentBase<v8::FunctionTemplate> = (val_ = 0x0000000000000000)
	  }
	  tty_constructor_template_ = {
	    v8::PersistentBase<v8::FunctionTemplate> = (val_ = 0x0000000105010f00)
	  }
	  udp_constructor_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000105010e60)
	  }
	  write_wrap_constructor_function_ = {
	    v8::PersistentBase<v8::Function> = (val_ = 0x0000000105010ec0)
	  }
	}

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
The constructor attribute causes the function to be called automatically before execution enters main (). You can verify this by checking the backtrace above.

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

The above nested classes calls the `DISALLOW_COPY_AND_ASSIGN` macro, for example:

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
We have to look at the EnvironmentConstructor to see where this is set:

    inline Environment::Environment(IsolateData* isolate_data, v8::Local<v8::Context> context) 
    ...
    AssignToContext(context);

So, we can see that `AssignToContext` is setting the environment on the passed-in context:

    static const int kContextEmbedderDataIndex = 5;

    inline void Environment::AssignToContext(v8::Local<v8::Context> context) {
      context->SetAlignedPointerInEmbedderData(kContextEmbedderDataIndex, this);
    }

So this how the Environment is associated with the context, and this enable us to get the environment for a context above. The argument to `SetAlignedPointerInEmbedderData` is a void pointer so it can be anything you want. 
The data is stored in a V8 FixedArray, the `kContextEmbedderDataIndex` is the index into this array (I think, still learning here).
TODO: read up on how this FixedArray and alignment works.

There are also static methods to get the Environment using a context.

#### ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES

    #define V(PropertyName, TypeName)                                             \
      inline v8::Local<TypeName> PropertyName() const;                            \
      inline void set_ ## PropertyName(v8::Local<TypeName> value);
      ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES(V)
    #undef V

The above is defining getters and setter for all the properties in `ENVIRONMENT_STRONG_PERSISTENT_PROPERTIES`. Lets take a look at one:

    V(tcp_constructor_template, v8::FunctionTemplate)

Like before these are only the defintions, the declarations can be found in src/env-inl.h:

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
New is set as the callback for when `new TCP()` is used, for example:

    var TCP = process.binding('tcp_wrap').TCP;
    var handle = new TCP();

When the second line is executed the callback `New` will be invoked. This is set up by this line later in TCPWrap::Initialize:

    target->Set(FIXED_ONE_BYTE_STRING(env->isolate(), "TCP"), t->GetFunction());

New takes a single argument of type v8::FunctionCallbackInfo which holds information about the function call make. This is things like the number of arguments used, the arguments can be retreived using with the operator[]. `New` looks like this:

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

Using the example above we can see that `Length` should be 0 as we did not pass any arguments to the TCP function. Just wondering, what could be passed as a parameter?  What ever it might look like it should be a pointer to an AsyncWrap.

So this is where the instance of TCPWrap is created. Notice `a.This()` which is passed all the wway up to BaseObject's constructor and made into a persistent handle.

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
I'm not exactly sure what `SetInternalFieldCount(1)` is doing, looks like has something to do with making sure there is a constructor.

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

I've been wondering about the class names that end with Wrap and what they are wrapping. My thinking now is that they are wrapping libuv things. For instance, take StreamWrap, 
in libuv src/unix/stream.c which is what SetBlocking calls:

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


### AsyncWrap
AsyncWrap extends BaseObject.
Going with my assumption that this wraps an libuv async handle. From the libuv documentation: 
"Async handles allow the user to “wakeup” the event loop and get a callback called from another thread."

AsyncWrap has a enum of provider types:

    enum ProviderType {
    #define V(PROVIDER)                                                           \
      PROVIDER_ ## PROVIDER,
      NODE_ASYNC_PROVIDER_TYPES(V)
    #undef V
   };

The provider type is passed when constructing an instance of AsyncWrap:

    inline AsyncWrap(Environment* env,
                   v8::Local<v8::Object> object,
                   ProviderType provider,
                   AsyncWrap* parent = nullptr);
    ...


    v8::Local<v8::Function> init_fn = env->async_hooks_init_function();

You may remember seeing this `async_hooks_init_function` in env.h:

    V(async_hooks_init_function, v8::Function)                                  \

Lets back up a little, AsyncWrap is a builtin so the first function to be called will be its Async::Initialize function.

    env->SetMethod(target, "setupHooks", SetupHooks);
    env->SetMethod(target, "disable", DisableHooksJS);
    env->SetMethod(target, "enable", EnableHooksJS);

### SetupHooks


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

An IsolateData (and also an Environement as it proxies these members)  actually has a lot of members, too many to list here it is easy to do a search for them.


### Running lint

    $ make lint
    $ make jslint

### Running tests
To run the test use the following command:

    $ make -j4 test

The -j is the number of processes to use.

#### Mac firewall exceptions
On mac you might find it popping up dialogs about the firwall blocking access to the `node` and `cctest` applications when running
the tests. You can add exceptions by pointing to the `node` executable and `node/out/Release/cctest`. When doing this it seems you have to located the `node/out/Release` directory
and then select the `node` executable.
Note that you'll have to read-add these after running './configure'


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

We know are extension is `.js` so lets look closer at it:

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

vm.runInThisContext

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


So this is also how `exports`, `require`, `module`, `__filename`, and `__dirname` are made available
to all scripts.

After all this processing is done we will be back in node.cc and continue processing there. As everything is event driven the event loop start running
and trigger callback for anything that has been set up by the script.

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

`ESC`           toggle drawer
`CTRL+~`        jump to console
`CMD+[`         next panel
`CMD+]`         previous panel
`CMD+ALT+[`     next panel in history
`CMD+ALT+]`     previous panel history
`CMD+SHIFT+D`   toggle location of panels (separate screen/docked)
`?`             show settings dialog
                You can see all the shortcuts from here.
`ESC`           close settings/dialog


### Node Package Manager (NPM) 
I was curious about what type of program it is. Looking at the shell script on my machine it is a simple wrapper that calls node with the javascript file being the shell script itself. Kinda like doing:

    #!/bin/sh
    // 2>/dev/null; exec "`dirname "~/.nvm/versions/node/v4.4.3/bin/npm"`/node" "$0" "$@"

    console.log("bajja");
