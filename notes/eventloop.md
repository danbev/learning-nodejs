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


```console
$ NODE_DEBUG=timer node lib/async.js
```




Notice that `_idlePrev` and `_idleNext` are properties which are index by a





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


Instead of this:
```c++
  if (maybe_fn.IsEmpty()) {
    return MaybeLocal<Value>();
  }
 
  Local<Function> fn = maybe_fn.ToLocalChecked();
```
Notice that we are first checking that the MaybeLocal is empty, and then we
are also calling ToLocalChecked() below. Instead, perhaps we can call ToLocal
which would save a call to ToLocalChecked with the motivation that if we get
there we know that the MaybeLocal is not empty.

```c++
  Local<Function> fn;                                                           
  if (maybe_fn.ToLocal(&fn)) {                                                  
    return MaybeLocal<Value>();                                                 
  }      

```
```c++
template <class T>                                                              
Local<T> MaybeLocal<T>::ToLocalChecked() {                                      
  if (V8_UNLIKELY(val_ == nullptr)) V8::ToLocalEmpty();                         
  return Local<T>(val_);                                                        
} 
```

```c++
template <class S>                                                            
  V8_WARN_UNUSED_RESULT V8_INLINE bool ToLocal(Local<S>* out) const {           
    out->val_ = IsEmpty() ? nullptr : this->val_;                               
    return !IsEmpty();                                                          
  }       
```

### process.nextTick

