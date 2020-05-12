### Event Loop
It all starts with the javascript file to be executed, which is you main program.
```
                                  (while there are things to process)
------------> javascript.js --+------------------↓ 
			      ↑                  | setTimeout/SetInterval
			      |                  | JavaScript callbacks
			      |                  ↓
			      |                  | network/disk/child_processes
			      |                  | JavaScript callbacks
			      |                  ↓ 
			      |                  | setImmedate
			      ↑                  | JavaScript callbacks
			       \                 ↓ 
				\                | close events
				 \               | JavaScript callbacks
				  \              ↓
				   \             |
<----------- process.exit (event) <--------------<
```

-JavaScript callbacks
```
--------> callback ----+------------------------------------↓
                       ↑                                    |
                       |                              nextTick callback
                       |                                    ↓
                       |                              Resolve Promies
                       |                                    ↓                                   
                       |                                    |
                       ↑------------------------------------<
```

### setTimeout/setInternval/setImmediate
When node starts `internal/bootstrap/node` will be run which has the following
lines of code:
```js
  const timers = require('timers');
  defineOperation(global, 'clearInterval', timers.clearInterval);
  defineOperation(global, 'clearTimeout', timers.clearTimeout);
  defineOperation(global, 'setInterval', timers.setInterval);
  defineOperation(global, 'setTimeout', timers.setTimeout);

  defineOperation(global, 'queueMicrotask', queueMicrotask);
  defineOperation(global, 'setImmediate', timers.setImmediate);
```

For example, using `setTimeout` could look like this:
```js
const timeout = setTimeout(function timeout_cb(something) {
    console.log('timeout. arg1', something);
  }, 0, "argument1");
```
If we look in `lib/timers.js` we can find the definitions for setTimeout:
```js
const {                                                                         
  Timeout,                                                                      
  ...
  insert
} = require('internal/timers');

function setTimeout(callback, after, arg1, arg2, arg3) {
  ...
  const timeout = new Timeout(callback, after, args, false, true);                 
  insert(timeout, timeout._idleTimeout);                                           
                                                                                   
  return timeout;
}
```
Timeout can be found in `lib/internal/timers.js`:
```js
function Timeout(callback, after, args, isRepeat, isRefed) {
  ...
  this._idleTimeout = after;                                                       
  this._idlePrev = this;                                                           
  this._idleNext = this;                                                           
  this._idleStart = null;                                                          
  this._onTimeout = callback;                                                      
  this._timerArgs = args;                                                          
  this._repeat = isRepeat ? after : null;                                          
  this._destroyed = false; 
}
```
We can log the instance to the console to see some real values:
```console
Timeout {
  _idleTimeout: 1,
  _idlePrev: [TimersList],
  _idleNext: [TimersList],
  _idleStart: 41,
  _onTimeout: [Function: timeout_cb],
  _timerArgs: undefined,
  _repeat: null,
  _destroyed: false,
  [Symbol(refed)]: true,
  [Symbol(asyncId)]: 2,
  [Symbol(triggerId)]: 1
}
```
If we look back at where the Timeout constructor is called we see that the the
instance created is passed into the `insert` function:
```js
  insert(timeout, timeout._idleTimeout);
```
And insert can be found in `lib/internal/timers.js`.
```js
const {                                                                            
  scheduleTimer,                                                                   
  toggleTimerRef,                                                                  
  getLibuvNow,                                                                     
  immediateInfo                                                                    
} = internalBinding('timers');

const timerListQueue = new PriorityQueue(compareTimersLists, setPosition);

function insert(item, msecs, start = getLibuvNow()) {
  item._idleStart = start;                                                      
  let list = timerListMap[msecs];
  if (list === undefined) {
    debug('no %d list was found in insert, creating a new one', msecs);
    const expiry = start + msecs;
    timerListMap[msecs] = list = new TimersList(expiry, msecs);
    timerListQueue.insert(list);
    if (nextExpiry > expiry) {
      scheduleTimer(msecs);
      nextExpiry = expiry;
    }
  }
  L.append(list, item);  
}
```
So we have a map which is keyed with the expiry, and the value is a TimerList.
TimerList:
```js
function TimersList(expiry, msecs) {                                            
  this._idleNext = this;
  this._idlePrev = this;
  this.expiry = expiry;                                                         
  this.id = timerListId++;                                                        
  this.msecs = msecs;                                                           
  this.priorityQueuePosition = null;                                            
}
```
So we create a new TimersList instance which is then inserted into the
`timerListQueue` which is of type PriorityQueue and can be found in
`internal/priority_queue`. AFter this `scheduleTimer` is called which can be
found in `src/timers.cc`
```c++
void ScheduleTimer(const FunctionCallbackInfo<Value>& args) {                      
  auto env = Environment::GetCurrent(args);                                        
  env->ScheduleTimer(args[0]->IntegerValue(env->context()).FromJust());            
}
```
And in src/env.cc we can find:
```c++
void Environment::ScheduleTimer(int64_t duration_ms) {                          
  if (started_cleanup_) return;                                                 
  uv_timer_start(timer_handle(), RunTimers, duration_ms, 0);                    
}
```
So we are starting a timer and the callback is `RunTimers` which will be called
when the timer fires/expires.
```c++
  Local<Object> process = env->process_object();                                    
  InternalCallbackScope scope(env, process, {0, 0});

  Local<Function> cb = env->timers_callback_function();                         
  MaybeLocal<Value> ret;                                                        
  Local<Value> arg = env->GetNow();                                             
  // This code will loop until all currently due timers will process. It is     
  // impossible for us to end up in an infinite loop due to how the JS-side     
  // is structured.                                                             
  do {                                                                          
    TryCatchScope try_catch(env);                                               
    try_catch.SetVerbose(true);                                                 
    ret = cb->Call(env->context(), process, 1, &arg);                           
  } while (ret.IsEmpty() && env->can_call_into_js());
```
Notice the [InternalCallbackScope](#internalcallbackscope) that is here.


We can inspect `cb` which is the function that will be called.
```console
(lldb) jlh cb
0x367b934c2e69: [Function]
 - map: 0x07dddd580679 <Map(HOLEY_ELEMENTS)> [FastProperties]
 - prototype: 0x0700ffe40a39 <JSFunction (sfi = 0x1e915df49f09)>
 - elements: 0x0f5694ac0b29 <FixedArray[0]> [HOLEY_ELEMENTS]
 - function prototype: 
 - initial_map: 
 - shared_info: 0x3d84c4812259 <SharedFunctionInfo processTimers>
 - name: 0x0700ffe6c269 <String[#13]: processTimers>
 - builtin: CompileLazy
 - formal_parameter_count: 1
 - kind: NormalFunction
 - context: 0x1d88087b5e69 <FunctionContext[5]>
 - code: 0x1fad42dc33a1 <Code BUILTIN CompileLazy>
 - source code: (now) {
    debug('process timer lists %d', now);
    nextExpiry = Infinity;

    let list;
    let ranAtLeastOneList = false;
    while (list = timerListQueue.peek()) {
      if (list.expiry > now) {
        nextExpiry = list.expiry;
        return refCount > 0 ? nextExpiry : -nextExpiry;
      }
      if (ranAtLeastOneList)
        runNextTicks();
      else
        ranAtLeastOneList = true;
      listOnTimeout(list, now);
    }
    return 0;
  }
 - properties: 0x0f5694ac0b29 <FixedArray[0]> {
    #length: 0x1e915df404a1 <AccessorInfo> (const accessor descriptor)
    #name: 0x1e915df40431 <AccessorInfo> (const accessor descriptor)
    #prototype: 0x1e915df40511 <AccessorInfo> (const accessor descriptor)
 }
 - feedback vector: feedback metadata is not available in SFI
```
We can see above that the `name` is `processTimers` and this is a function that
is defined in `lib/internal/timers.js`.

Lets try debugging this:
```console
$ env NODE_DEBUG=timer lldb -- ./node_g --inspect-brk-node  lib/task.js 
(lldb) br s -n Environment::RunTimers
(lldb) r
```
We can let the continue to the entry of our script and then set a breakpoint
in `processTimers`. This will stop in the breakpoint in RunTimers.
When I'm trying to understand is why there is a while loop there. I was thinking
that it would be enough to just run the processTimers function once.


### InternalCallbackScope
The declaration for this class can be found in `src/node_internals.h` and the
implementation in `node/api/callback.cc`.
```c++
InternalCallbackScope::InternalCallbackScope(Environment* env,
                                             Local<Object> object,
                                             const async_context& asyncContext,
                                             int flags)
```
`async_context` is a struct defined in `src/node.h`:
```c++
typedef double async_id;                                                           
struct async_context {                                                             
  ::node::async_id async_id;                                                       
  ::node::async_id trigger_async_id;                                               
};
```
Now, lets take a closer look at the InternalCallbackScope constructor, and the
the destructor as it is an implemention of RAII.

```c++
InternalCallbackScope::~InternalCallbackScope() {                                  
  Close();                                                                         
  env_->PopAsyncCallbackScope();                                                   
}
```
Now, `Close` is interesting.
```c++
  TickInfo* tick_info = env_->tick_info();                                         

  if (!tick_info->has_tick_scheduled()) {
    MicrotasksScope::PerformCheckpoint(env_->isolate());
  }

  HandleScope handle_scope(env_->isolate());
  Local<Object> process = env_->process_object();
  Local<Function> tick_callback = env_->tick_callback_function();

  if (tick_callback->Call(env_->context(), process, 0, nullptr).IsEmpty()) {
    failed_ = true;
  }
```c++
And we can inspect `tick_callback` to see what will be run:
```console
(lldb) jlh tick_callback
0x32e4e57c2dc1: [Function]
 - map: 0x19edc0cc0679 <Map(HOLEY_ELEMENTS)> [FastProperties]
 - prototype: 0x3b0e0cd40a39 <JSFunction (sfi = 0x1c1042c09f09)>
 - elements: 0x3eab4f380b29 <FixedArray[0]> [HOLEY_ELEMENTS]
 - function prototype: 
 - initial_map: 
 - shared_info: 0x325f36fad639 <SharedFunctionInfo processTicksAndRejections>
 - name: 0x325f36fad2b9 <String[#25]: processTicksAndRejections>
 - formal_parameter_count: 0
 - safe_to_skip_arguments_adaptor
 - kind: NormalFunction
 - context: 0x32e4e57e3149 <FunctionContext[38]>
 - code: 0x23b2d5c43341 <Code BUILTIN InterpreterEntryTrampoline>
 - interpreted
 - bytecode: 0x28b4edb53d91 <BytecodeArray[362]>
 - source code: () {
  let tock;
  do {
    while (tock = queue.shift()) {
      const asyncId = tock[async_id_symbol];
      emitBefore(asyncId, tock[trigger_async_id_symbol], tock);

      try {
        const callback = tock.callback;
        if (tock.args === undefined) {
          callback();
        } else {
          const args = tock.args;
          switch (args.length) {
            case 1: callback(args[0]); break;
            case 2: callback(args[0], args[1]); break;
            case 3: callback(args[0], args[1], args[2]); break;
            case 4: callback(args[0], args[1], args[2], args[3]); break;
            default: callback(...args);
          }
        }
      } finally {
        if (destroyHooksExist())
          emitDestroy(asyncId);
      }

      emitAfter(asyncId);
    }
    runMicrotasks();
  } while (!queue.isEmpty() || processPromiseRejections());
  setHasTickScheduled(false);
  setHasRejectionToWarn(false);
}
 - properties: 0x3eab4f380b29 <FixedArray[0]> {
    #length: 0x1c1042c004a1 <AccessorInfo> (const accessor descriptor)
    #name: 0x1c1042c00431 <AccessorInfo> (const accessor descriptor)
    #prototype: 0x1c1042c00511 <AccessorInfo> (const accessor descriptor)
 }
 - feedback vector: not available
```
TODO: trace the above js function
 

### nextTick
In `lib/internal/bootstrap/node.js` we have the function `setupTaskQueue` which
can be found in `lib/internal/process/task_queues.js`:
```js
module.exports = {                                                                 
  setupTaskQueue() {                                                               
    listenForRejections();                                                         
    setTickCallback(processTicksAndRejections);                                    
    return {                                                                       
      nextTick,                                                                    
      runNextTicks                                                                 
    };                                                                             
  },                                                                               
  queueMicrotask                                                                   
};
```
And `setTickCallback` is an internal builtin name task_queue which can be
found in `src/node_task_queue.cc`

```js
const {                                                                            
  // For easy access to the nextTick state in the C++ land,                        
  // and to avoid unnecessary calls into JS land.                                  
  tickInfo,                                                                        
  // Used to run V8's micro task queue.                                            
  runMicrotasks,                                                                   
  setTickCallback,                                                                 
  enqueueMicrotask                                                                 
} = internalBinding('task_queue');
```
And the implementation:
```c++
static void SetTickCallback(const FunctionCallbackInfo<Value>& args) {             
  Environment* env = Environment::GetCurrent(args);                                
  CHECK(args[0]->IsFunction());                                                    
  env->set_tick_callback_function(args[0].As<Function>());                      
}  
```
So we can see that we are just setting the function on the environment which
is what is then used in `src/api/callback.cc`:
```c++
Local<Function> tick_callback = env_->tick_callback_function();
```

### Task queues in node
Upon startup of node `Environment::BootstrapNode` will be called which will
call:
```c++
  MaybeLocal<Value> result = ExecuteBootstrapper(                               
      this, "internal/bootstrap/node", &node_params, &node_args);  
```
This will invoke `internal/bootstrap/node.js`.

```js
const {                                                                         
  setupTaskQueue,                                                               
  queueMicrotask                                                                   
} = require('internal/process/task_queues');
...

const { nextTick, runNextTicks } = setupTaskQueue();
```

And in `task_queues.js` we have:
```js
module.exports = {                                                                 
  setupTaskQueue() {                                                               
    // Sets the per-isolate promise rejection callback                             
    listenForRejections();                                                         
    // Sets the callback to be run in every tick.                                  
    setTickCallback(processTicksAndRejections);                                    
    return {                                                                       
      nextTick,                                                                    
      runNextTicks                                                                 
    };                                                                             
  },                                                                               
  queueMicrotask                                                                   
}; 
```
Notice that `processTicksAndRejections` passed to the `setTickCallback`
function, which is defined in `src/node_task_queue.cc`.
```js
const {                                                                         
  // For easy access to the nextTick state in the C++ land,                     
  // and to avoid unnecessary calls into JS land.                                  
  tickInfo,                                                                        
  // Used to run V8's micro task queue.                                            
  runMicrotasks,                                                                   
  setTickCallback,                                                                 
  enqueueMicrotask                                                              
} = internalBinding('task_queue');  
```
And the implementation looks like this:
```c++
static void SetTickCallback(const FunctionCallbackInfo<Value>& args) {             
  Environment* env = Environment::GetCurrent(args);                                
  CHECK(args[0]->IsFunction());                                                    
  env->set_tick_callback_function(args[0].As<Function>());                         
```


### process.nextTick

