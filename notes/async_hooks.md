### AsyncHooks
AsyncHooks provide an API for tracking async resources and this page contains
notes about this works.

### AsyncHook class
The class AsyncHook is declared in `src/env.h` and has the following private
fields:
```c++
  // Stores the ids of the current execution context stack.
  AliasedFloat64Array async_ids_stack_;
  // Attached to a Uint32Array that tracks the number of active hooks for each type.
  AliasedUint32Array fields_;
  // Attached to a Float64Array that tracks the state of async resources.
  AliasedFloat64Array async_id_fields_;
  v8::Global<v8::Array> execution_async_resources_;
```
What is AliasedFloat64Array?  
```c++
typedef AliasedBufferBase<double, v8::Float64Array> AliasedFloat64Array;
```
And if we look at AliasedBufferBase:
```c++
template <class NativeT,
          class V8T,
          // SFINAE NativeT to be scalar
          typename = std::enable_if_t<std::is_scalar<NativeT>::value>>
class AliasedBufferBase {
 public:                                                                           
  AliasedBufferBase(v8::Isolate* isolate, const size_t count)                      
      : isolate_(isolate), count_(count), byte_offset_(0) {                        
    const v8::HandleScope handle_scope(isolate_);                                  
    const size_t size_in_bytes =                                                   
        MultiplyWithOverflowCheck(sizeof(NativeT), count);
    v8::Local<v8::ArrayBuffer> ab = v8::ArrayBuffer::New(isolate_, size_in_bytes);                                                  
    buffer_ = static_cast<NativeT*>(ab->GetBackingStore()->Data());                
                                                                                   
    // allocate v8 TypedArray                                                      
    v8::Local<V8T> js_array = V8T::New(ab, byte_offset_, count);                   
    js_array_ = v8::Global<V8T>(isolate, js_array);
  }
};
```
In this case `NativeT`(native type) will be set to `double`, and the V8 Type will
be Float64Array. 

`async_ids_stack_` is create in the constructor of AsyncHooks:
```c++
inline AsyncHooks::AsyncHooks()                                                     
    : async_ids_stack_(env()->isolate(), 16 * 2),                                   
      fields_(env()->isolate(), kFieldsCount),                                      
      async_id_fields_(env()->isolate(), kUidFieldsCount) {
```
So we can see that we are creating a AliasedBuffer with a count of 32 and this
is a TypedArray.
```c++
AliasedBufferBase(v8::Isolate* isolate, const size_t count)                   
        : isolate_(isolate), count_(count), byte_offset_(0) { 
```
The entries in this "stack" will be two double values, the async_id and the
trigger_async_id:
`async_context` is a struct defined in `src/node.h`:
```c++
typedef double async_id;                                                           
struct async_context {                                                             
  ::node::async_id async_id;                                                       
  ::node::async_id trigger_async_id;                                               
};
```
These values are pushed into the async_ids_stack_ (which is an TypedArray which
it just a area of memory (ArrayBuffer) that we treat as we wish. In this case
it is used as a stack:
```c++
inline void AsyncHooks::push_async_context(double async_id,                         
                                           double trigger_async_id,                 
                                           v8::Local<v8::Value> resource) {

  uint32_t offset = fields_[kStackLength];
  if (offset * 2 >= async_ids_stack_.Length())
    grow_async_ids_stack();
  async_ids_stack_[2 * offset] = async_id_fields_[kExecutionAsyncId];
  async_ids_stack_[2 * offset + 1] = async_id_fields_[kTriggerAsyncId];
  fields_[kStackLength] += 1;
  async_id_fields_[kExecutionAsyncId] = async_id;
  async_id_fields_[kTriggerAsyncId] = trigger_async_id;
```
The AsyncHooks class has an enum named Fields and one named UidFields
```c++
enum Fields {                                                                     
    kInit,
    kBefore,
    kAfter,
    kDestroy,
    kPromiseResolve,
    kTotals,
    kCheck,
    kStackLength,                                                                   
    kFieldsCount,                                                                   
  };

  enum UidFields {
    kExecutionAsyncId,
    kTriggerAsyncId,
    kAsyncIdCounter,
    kDefaultTriggerAsyncId,
    kUidFieldsCount,
  };
```
So we first get the current size or the stack which is stored in a
`AliasedUint32Array`. And we check if the stack need to grow. 
Next we have:
```c++
  async_ids_stack_[2 * offset] = async_id_fields_[kExecutionAsyncId];
  async_ids_stack_[2 * offset + 1] = async_id_fields_[kTriggerAsyncId];
```
Notice the multipying by 2 which is to take into account that the two values
that make up an entry in this "stack". 
The first line will set the new stack entry to be the current executions resources
id. Then the current async trigger id will be set (in the same stack entry).

`fields_` is used a count of how many active hooks there are for the different
types of hooks. The types are in the Fields enum and I believe they are only
kInit, kBefore, kAfter, kDestroy, kPromiseResolve, and the others are for house
keeping track of the total number of hooks (kTotals), kCheck is used to toggle
if checks should be performed or not on the async_ids for example, kStackLength
is the holds size of the stack, and kFieldsCount just contains the number of
elements in the Fields enum.

`async_id_fields_` is create in the constructor of AsyncHooks and is given a 
kUidFieldsCount and these contain 

`async_ids_stack_` is the stack of async ids.

Lets take a look at executionAsyncId():
```js
async_hooks.executionAsyncId()
```
This is exported by lib/async_hooks.js but implemented in lib/internal/async_hooks.js.
```js
function executionAsyncId() {                                                   
  return async_id_fields[kExecutionAsyncId];                                    
}
```
When we require('async_hooks') this will in turn require('lib/internal/async_hooks').
Where we have:
```js
const async_wrap = internalBinding('async_wrap');
```
And is we take a look at `src/async_wrap.cc` and its Intialize method:
```c++
  FORCE_SET_TARGET_FIELD(target,                                                
                         "async_hook_fields",                                   
                         env->async_hooks()->fields().GetJSArray()); 
```
We can see that we are setting up the export object which `async_wrap` will 
be a reference to:
```console
(lldb) jlh target
0x222d1f46acf1: [JS_API_OBJECT_TYPE]
 - map: 0x1e72ee4a45e9 <Map(HOLEY_ELEMENTS)> [FastProperties]
 - prototype: 0x184584387929 <Object map = 0x1e72ee486f19>
 - elements: 0x062e98140b29 <FixedArray[0]> [HOLEY_ELEMENTS]
 - embedder fields: 1
 - properties: 0x222d1f46b451 <PropertyArray[12]> {
    #setupHooks: 0x13eae07aaf01 <JSFunction setupHooks (sfi = 0x13eae07aaec1)> (const data field 0) properties[0]
    #pushAsyncContext: 0x13eae07ab009 <JSFunction pushAsyncContext (sfi = 0x13eae07aafc9)> (const data field 1) properties[1]
    #popAsyncContext: 0x13eae07ab111 <JSFunction popAsyncContext (sfi = 0x13eae07ab0d1)> (const data field 2) properties[2]
    #queueDestroyAsyncId: 0x13eae07ab219 <JSFunction queueDestroyAsyncId (sfi = 0x13eae07ab1d9)> (const data field 3) properties[3]
    #enablePromiseHook: 0x13eae07ab349 <JSFunction enablePromiseHook (sfi = 0x13eae07ab309)> (const data field 4) properties[4]
    #disablePromiseHook: 0x13eae07ab451 <JSFunction disablePromiseHook (sfi = 0x13eae07ab411)> (const data field 5) properties[5]
    #registerDestroyHook: 0x13eae07ab559 <JSFunction registerDestroyHook (sfi = 0x13eae07ab519)> (const data field 6) properties[6]
    #async_hook_fields: 0x184584382d99 <Uint32Array map = 0x1e72ee482329> (const data field 7) properties[7]
    #async_id_fields: 0x184584382e31 <Float64Array map = 0x1e72ee481b01> (const data field 8) properties[8]
    #execution_async_resources: 0x184584382e89 <JSArray[0]> (const data field 9) properties[9]
    #async_ids_stack: 0x184584382d01 <Float64Array map = 0x1e72ee481b01> (const data field 10) properties[10]
 }
 - embedder fields = {
    0x062e98140471 <undefined>
 }
```
There are more properties like `constants` but I'm not showing the all to save
some space. Looking closer as async_id_fields can see that it has 8 fields:
```
#async_id_fields: 0x184584382e31 <Float64Array map = 0x1e72ee481b01> (const data field 8) properties[8]
```
```console
(lldb) jlh env->async_hooks()->async_id_fields().GetJSArray()
0x184584382e31: [JSTypedArray]
 - map: 0x1e72ee481b01 <Map(FLOAT64ELEMENTS)> [FastProperties]
 - prototype: 0x3a5af5dcb8d9 <Object map = 0x1e72ee481b49>
 - elements: 0x062e98141dd9 <ByteArray[0]> [FLOAT64ELEMENTS]
 - embedder fields: 2
 - buffer: 0x184584382df1 <ArrayBuffer map = 0x1e72ee480799>
 - byte_offset: 0
 - byte_length: 32
 - length: 4
 - data_ptr: 0x56d6b20
   - base_pointer: 0
   - external_pointer: 0x56d6b20
 - properties: 0x062e98140b29 <FixedArray[0]> {}
 - elements: 0x062e98141dd9 <ByteArray[0]> {
         0-1: 0
           2: 1
           3: -1
 }
 - embedder fields = {
    0, aligned pointer: 0
    0, aligned pointer: 0
 }
```
Where is async_id_fields[kExecutionAsyncId] set to 1?
This is done in `src/node.cc`:
```c++
MaybeLocal<Value> StartExecution(Environment* env, StartExecutionCallback cb) { 
  InternalCallbackScope callback_scope(
      env,
      Object::New(env->isolate()),
      { 1, 0 }, // async_id, async_trigger_id
      InternalCallbackScope::kSkipAsyncHooks);
```
And if we set a break point in InternalCallbackScope's constructor we can
inspect the values:
```console
lldb) expr asyncContext
(const node::async_context) $8 = (async_id = 1, trigger_async_id = 0)
```
Next we have the following line:
```
async_ids_stack_[2 * offset] = async_id_fields_[kExecutionAsyncId];
async_ids_stack_[2 * offset + 1] = async_id_fields_[kTriggerAsyncId];
```
So, we are setting two values which is the execution async id, and the trigger
async id.
``console
(lldb) expr async_id_fields_[node::AsyncHooks::UidFields::kExecutionAsyncId]
(node::AliasedBufferBase<double, v8::Float64Array>::Reference) $21 = {}
(double) $23 = 0
```
The first line will set the new stack entry to be the current executions resources
id. Then the current async trigger id will be set (in the same stack entry).
Next we increment the stack size:
```c++
  fields_[kStackLength] += 1;
```
And after that we set the current async execution id to the passed-in async_id
and the async trigger id in async_id_fields:
```c++
  async_id_fields_[kExecutionAsyncId] = async_id;                                   
  async_id_fields_[kTriggerAsyncId] = trigger_async_id;
```
And finally we add the current async resource to an Array of async resources:
```c++
  auto resources = execution_async_resources();
  USE(resources->Set(env()->context(), offset, resource));
```
We can find the declaration of it in `src/env.h`:
```c++
  v8::Global<v8::Array> execution_async_resources_;
```
When the InternalCallbackScope's destructor is run Close will be called which
in turn will calls pop_async_context passing in the async_id. It will do the
revers of push which makes sense.
So to recap, we have `async_ids_stack` which contains the execution async ids and
the async trigger ids. And `async_id_fields` is a storage area for various things
and two of them store the current execution async id and current async trigger id.


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
 

