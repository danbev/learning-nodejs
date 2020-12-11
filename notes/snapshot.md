### Node snapshot
This document contains notes about Node's usage of V8 snapshots features.

### node_snapshot executable
This is an executable that is run as part of Node's build. The result of running
this is a generated C++ source file that by default can be found in
`out/Release/obj/gen/node_snapshot.cc`. This will then be compiled with the
rest of Node at a later stage in the build process.

### node_mkshapshot walkthrough
```console
$ lldb -- ./out/Debug/node_mksnapshot out/Debug/obj/gen/node_snapshot.cc
(lldb) settings set target.env-vars NODE_DEBUG_NATIVE=mksnapshot
(lldb) br s -n main
```
For a snapshot to be created `SnapshotBuilder::Generate` will create a new
V8 runtime (Isolate, Platform etc). After the Isolate has been registered with
the v8 platform a vector of external
references will be collected by the following call:
```c++
const std::vector<intptr_t>& external_references =                             
        NodeMainInstance::CollectExternalReferences(); 
```
That call will land in node_main_instance.cc:
```c++
const std::vector<intptr_t>& NodeMainInstance::CollectExternalReferences() {       
  registry_.reset(new ExternalReferenceRegistry());                                
  return registry_->external_references();
```
When we have functions that are not defined in V8 itself these functions will
have addresses that V8 does not know about. The function will be a symbol that
needs to be resolved when V8 deserialzes a blob.

ExternalReferenceRegistry constructor will call all the registered external
references (see ExternalReferenceRegistry for details about this). These are
functions that exist in Node that need to be registered as external so that
the object being serialized does not store the address to the function but
instead an index into this array of external references. After the snapshot has
been created it will be stored on disk and the snapshot blob cannot contains the
function addresses as they will most probably change when loaded into another
processs.

```console
(lldb) expr external_references
(const std::vector<long, std::allocator<long int> >) $1 = size=209 {
  [0] = 25494212
```
And we can verify that this matches node::SetupHooks:
```console
(lldb) expr SetupHooks
(void (*)(const v8::FunctionCallbackInfo<v8::Value> &)) $0 = 0x00000000018502c4 (node_mksnapshot`node::SetupHooks(const v8::FunctionCallbackInfo<v8::Value> &) at async_wrap.cc:413:65)
(lldb) expr reinterpret_cast<intptr_t>(SetupHooks)
(intptr_t) $1 = 25494212
```
Next, we create a new SnapshotCreator:
```c++
SnapshotCreator creator(isolate, external_references.data());
```
`SnapshotCreator` is a class in V8 which takes a pointer to external references
and is declared in v8.h.
After this a `NodeMainInstance` will be created:
```c++
  const std::vector<intptr_t>& external_references =
        NodeMainInstance::CollectExternalReferences();
    SnapshotCreator creator(isolate, external_references.data());
    Environment* env;
    {
      main_instance =
          NodeMainInstance::Create(isolate,
                                   uv_default_loop(),
                                   per_process::v8_platform.Platform(),
                                   args,
                                   exec_args);

      HandleScope scope(isolate);
      creator.SetDefaultContext(Context::New(isolate));
      isolate_data_indexes = main_instance->isolate_data()->Serialize(&creator);
```
Notice the call to `IsolateData::Serialize` (src/env.cc). This function uses
macros which can be expanded using:
```console
$ g++ -DNODE_WANT_INTERNALS=true -E -Ideps/uv/include -Ideps/v8/include -Isrc src/env.cc
```

```c++
v8::Eternal<v8::Private> alpn_buffer_private_symbol_;
v8::Eternal<v8::Private> arrow_message_private_symbol_;
...

std::vector<size_t> IsolateData::Serialize(SnapshotCreator* creator) {
  Isolate* isolate = creator->GetIsolate();
  std::vector<size_t> indexes;
  HandleScope handle_scope(isolate);
  indexes.push_back(creator->AddData(alpn_buffer_private_symbol_.Get(isolate)));
  indexes.push_back(creator->AddData(arrow_message_private_symbol_.Get(isolate)));
  indexes.push_back(creator->AddData(contextify_context_private_symbol_.Get(isolate)));
  indexes.push_back(creator->AddData(contextify_global_private_symbol_.Get(isolate)));
  indexes.push_back(creator->AddData(decorated_private_symbol_.Get(isolate)));
  ...

  for (size_t i = 0; i < AsyncWrap::PROVIDERS_LENGTH; i++)
    indexes.push_back(creator->AddData(async_wrap_provider(i)));

  return indexes;
}
```
Notice that we are calling `AddData` on the SnapshotCreator which allows for
attaching arbitary to the `isolate` snapshot. This data can later be retrieved
using `Isolate::GetDataFromSnapshotOnce` and passing in the index (size_t)
returned from `AddData`.

After this we are back `SnapshotBuilder::Generate` and will create a new Context
and enter a ContextScope. A new Environent instance will be created:
```c++
      env = new Environment(main_instance->isolate_data(),
                            context,
                            args,
                            exec_args,
                            nullptr,
                            node::EnvironmentFlags::kDefaultFlags,
                            {});
      env->RunBootstrapping().ToLocalChecked();
      if (per_process::enabled_debug_list.enabled(DebugCategory::MKSNAPSHOT)) {
        env->PrintAllBaseObjects();
        printf("Environment = %p\n", env);
      }
      env_info = env->Serialize(&creator);
      size_t index = creator.AddContext(context, {SerializeNodeContextInternalFields, env});
```
Environment's constructor calls Environment::InitializeMainContext and at this
stage we are passing in `nullptr` for the forth argument which is the
EnvSerializeInfo pointer: 
```c++
void Environment::InitializeMainContext(Local<Context> context,
                                        const EnvSerializeInfo* env_info) {
  ...
  if (env_info != nullptr) {
    DeserializeProperties(env_info);
  } else {
    CreateProperties();
  }
  ...
```
The properies here are the properties that are available to all scripts, like
the `primordials`, and the `process` object. We will take a look at 
`DeserializeProperties` when we startup node with the snapshot blob created by
the current process (remember that we are currently executing node_mksnapshot
to produce that blob).

After the bootstrapping has run, notice the call to `env->Serialize` which can
be found in env.cc.
```c++
EnvSerializeInfo Environment::Serialize(SnapshotCreator* creator) {
  EnvSerializeInfo info;
  Local<Context> ctx = context();

  info.native_modules = std::vector<std::string>(
      native_modules_without_cache.begin(), native_modules_without_cache.end());

  info.async_hooks = async_hooks_.Serialize(ctx, creator);
  info.immediate_info = immediate_info_.Serialize(ctx, creator);
  info.tick_info = tick_info_.Serialize(ctx, creator);
  info.performance_state = performance_state_->Serialize(ctx, creator);
  info.stream_base_state = stream_base_state_.Serialize(ctx, creator);
  info.should_abort_on_uncaught_toggle =
      should_abort_on_uncaught_toggle_.Serialize(ctx, creator);
}
```
First the non-cachable native modules are gathered and then Serialize is called
on different object. Notice that they all take a context and the SnapshotCreator.
The functions will be adding data to the context, for example:
```c++
return creator->AddData(context, GetJSArray());
```
After that there is a macro that will 
```c++
 size_t id = 0;
#define V(PropertyName, TypeName)
  do {
    Local<TypeName> field = PropertyName();
    if (!field.IsEmpty()) {
      size_t index = creator->AddData(field);
      info.persistent_templates.push_back({#PropertyName, id, index});
    }
    id++;
  } while (0);
  ENVIRONMENT_STRONG_PERSISTENT_TEMPLATES(V)
#undef V
```
This expands to (just showing one example below and not all):
```c++
do {
  Local<v8::FunctionTemplate> field = async_wrap_ctor_template();
  if (!field.IsEmpty()) {
    size_t index = creator->AddData(field);
    info.persistent_templates.push_back({"async_wrap_ctor_template", id, index});
  }
  id++;
} while (0);
```
Notice that `info.persistent_templates. is declared as:
```c++
std::vector<PropInfo> persistent_templates;
```
And the PropInfo struct look like this:
```c++
struct PropInfo {
  std::string name;     // name for debugging
  size_t id;            // In the list - in case there are any empty entires
  SnapshotIndex index;  // In the snapshot
}; 
typedef size_t SnapshotIndex;
```
So we are adding new PropInfo instances with the name given by the PropertyName,
the `id` is just a counter that starts from 0, `index` is the value returned from
`AddData` which is the index used to retrieve the value from the snapshot data
later when calling isolate->GetDataFromSnapshotOnce<Type>(index). Note that
there is no context passed to `AddData` which means we are adding this to the
isolate. This explains the values that can be found in
out/Debug/obj/gen/node_snapshot.cc:
```c++
// -- persistent_templates begins --                                            
{                                                                               
  { "async_wrap_ctor_template", 0, 337 },                                       
  { "base_object_ctor_template", 2, 338 },                                      
  { "binding_data_ctor_template", 3, 339 },                                     
  { "handle_wrap_ctor_template", 11, 340 },                                     
  { "i18n_converter_template", 16, 341 },                                       
  { "message_port_constructor_template", 18, 342 },                             
  { "promise_wrap_template", 21, 343 },                                         
  { "worker_heap_snapshot_taker_template", 31, 344 },                           
},                                                                              
// persistent_templates ends -- 
```

After all of the templates have been added, there is another macro that adds
properties:
```c++
id = 0;
#define V(PropertyName, TypeName)
  do {
    Local<TypeName> field = PropertyName();
    if (!field.IsEmpty()) {
      size_t index = creator->AddData(ctx, field);
      info.persistent_values.push_back({#PropertyName, id, index});
    }
    id++;
  } while (0);
  ENVIRONMENT_STRONG_PERSISTENT_VALUES(V)
#undef V
```
And expanded this will become (again only showing one):
```c++
id = 0;
do {
  Local<v8::Function> field = async_hooks_after_function();
  if (!field.IsEmpty()) {
    size_t index = creator->AddData(ctx, field);
    info.persistent_values.push_back({"async_hooks_after_function", id, index});
  }
  id++;
} while (0);
```
Notice that this time the Context is passed to `AddData` so we are adding these
to the context.

Finally the context is added before the `EnvSerializeInfo` is returned:
```c++
info.context = creator->AddData(ctx, context());
```
After this we will be back in `SnapshotBuilder::Generate`:
```c++
size_t index = creator.AddContext(
          context, {SerializeNodeContextInternalFields, env});
```
This is adding the context created and passing in a new
`SerializeInternalFieldsCallback` with the callback being
SerializeNodeContextInternalFields and the arguments to be passed to that
callback the pointer to the Environment:
```c++
  struct SerializeInternalFieldsCallback {
    typedef StartupData (*CallbackFunction)(Local<Object> holder, int index,
                                            void* data);
    SerializeInternalFieldsCallback(CallbackFunction function = nullptr,
                                    void* data_arg = nullptr)
        : callback(function), data(data_arg) {}
    CallbackFunction callback;
    void* data;
  };
```
In Node there are non-V8 objects attached to V8 objects by using embedder/internal
fields. V8 does not know how to handle this, so this callback is a way to enable
Node to extract the object from the `holder`, serialize the object into the an
instance of the returned `StartupData` which will then be added as part of the
blob.  Later when deserializeing there will be a callback to recreate and
instance of this type and then populate it with the data from the StartupData
that was stored..

A standalone example can be found
[here](https://github.com/danbev/learning-v8/blob/cb07dfd3aac4d76bbd3a14bdb1b268fdc4fd6587/test/snapshot_test.cc#L289-L306) which may help to clarify this.

So far we have collected addresses to functions that are external to V8 and
added them all to a vector. These will then be passed to the SnapshotCreator
constructor making them available when it serialized the Isolate/Context.
 
### ExternalReferenceRegistry
To see what the preprocessor generates for node_external_reference.cc the
following command can be used:
```console
$ g++ -DNODE_WANT_INTERNALS=true -I./src -I./deps/v8/include -I./deps/uv/include -E src/node_external_reference.cc
```
```c++
ExternalReferenceRegistry::ExternalReferenceRegistry() {
  _register_external_reference_async_wrap(this);
  _register_external_reference_binding(this);
  _register_external_reference_buffer(this);
  _register_external_reference_credentials(this);
  _register_external_reference_env_var(this);
  _register_external_reference_errors(this);
  _register_external_reference_handle_wrap(this);
  _register_external_reference_messaging(this);x
  _register_external_reference_native_module(this);
  _register_external_reference_process_methods(this);
  _register_external_reference_process_object(this);
  _register_external_reference_task_queue(this);
  _register_external_reference_url(this);
  _register_external_reference_util(this);
  _register_external_reference_string_decoder(this);
  _register_external_reference_trace_events(this);
  _register_external_reference_timers(this);
  _register_external_reference_types(this);
  _register_external_reference_worker(this);
}
```
And to see these functions use the following command:
```console
$ g++ -DNODE_WANT_INTERNALS=true -I./src -I./deps/v8/include -I./deps/uv/include -E src/node_external_reference.h
```
Lets take a look at one of these, `_register_external_reference_async_wrap`:
```c++
void _register_external_reference_async_wrap(node::ExternalReferenceRegistry* registry);
```
So that is the declaration, and to see the implementation we have to look in
src/async_wrap.cc:
```c++
NODE_MODULE_EXTERNAL_REFERENCE(async_wrap,                                      
                               node::AsyncWrap::RegisterExternalReferences)
```
And to expand that macro:
```console
$ g++ -DNODE_WANT_INTERNALS=true -I./src -I./deps/v8/include -I./deps/uv/include -E src/async_wrap.cc 
```
Which produces:
```C++
void _register_external_reference_async_wrap(node::ExternalReferenceRegistry* registry) {
  node::AsyncWrap::RegisterExternalReferences(registry); 
}

void AsyncWrap::RegisterExternalReferences(ExternalReferenceRegistry* registry) {
  registry->Register(SetupHooks);                                               
  registry->Register(SetCallbackTrampoline);                                    
  registry->Register(PushAsyncContext);                                         
  registry->Register(PopAsyncContext);                                          
  registry->Register(ExecutionAsyncResource);                                   
  registry->Register(ClearAsyncIdStack);                                        
  registry->Register(QueueDestroyAsyncId);                                      
  registry->Register(EnablePromiseHook);                                        
  registry->Register(DisablePromiseHook);                                       
  registry->Register(RegisterDestroyHook);                                      
  registry->Register(AsyncWrap::GetAsyncId);                                    
  registry->Register(AsyncWrap::AsyncReset);                                    
  registry->Register(AsyncWrap::GetProviderType);                               
  registry->Register(PromiseWrap::GetAsyncId);                                  
  registry->Register(PromiseWrap::GetTriggerAsyncId);                           
}
```
Now, in `node_external_reference.h` we have a number of types that can be
registered, for example `SetupHooks` is of type v8::FunctionCallback (it's a
function pointer) so this is what will be called:
```c++
void Register(v8::FunctionCallback addr) {
  RegisterT(addr);
}
```
And `RegisterT` is a private function in ExternalReferenceRegistry:
```c++
void RegisterT(T* address) {                                                     
    external_references_.push_back(reinterpret_cast<intptr_t>(address));           
} 
std::vector<intptr_t> external_references_;
```
And as we can see `external_references_` is a vector of addresses. So this how
the addresses to these functions are collected.

### EnvSerializeInfo
This is a struct declared in env.h and looks like this:
```c++
struct EnvSerializeInfo {                                                           
  std::vector<std::string> native_modules;                                          
  AsyncHooks::SerializeInfo async_hooks;                                            
  TickInfo::SerializeInfo tick_info;                                                
  ImmediateInfo::SerializeInfo immediate_info;                                      
  performance::PerformanceState::SerializeInfo performance_state;                   
  AliasedBufferInfo stream_base_state;                                              
  AliasedBufferInfo should_abort_on_uncaught_toggle;                                
                                                                                    
  std::vector<PropInfo> persistent_templates;                                       
  std::vector<PropInfo> persistent_values;                                          
                                                                                    
  SnapshotIndex context;                                                            
  friend std::ostream& operator<<(std::ostream& o, const EnvSerializeInfo& i);  
};
```
So first we have the native modules (which are the javascript modules under
lib.
Next, we have `AsyncHooks::SerializeInfo` which is a struct in AsyncHooks:
```c++
  struct SerializeInfo {                                                        
    AliasedBufferInfo async_ids_stack;                                          
    AliasedBufferInfo fields;                                                   
    AliasedBufferInfo async_id_fields;                                          
    SnapshotIndex js_execution_async_resources;                                 
    std::vector<SnapshotIndex> native_execution_async_resources;                
  };
```
`src/aliased_buffer.h` has a typedef `AliasedBufferInfo`:
```c++
typedef size_t AliasedBufferInfo; 
```
So async_ids_stack, fields, and async_id_fields are just unsigned integers.
Likewise `SnapshotIndex` is also a typedef:
```c++
typedef size_t SnapshotIndex;
```

### Snapshot usage during startup
When Node.js starts it will check if the is a startup blob (StartupData)
available when calling `NodeMainInstance::GetEmbeddedSnapshotBlob`
(in src/node.cc):
```c++
int Start(int argc, char** argv) {
  ...
  v8::StartupData* blob = NodeMainInstance::GetEmbeddedSnapshotBlob();          
  if (blob != nullptr) {                                                    
    params.snapshot_blob = blob;                                            
    indexes = NodeMainInstance::GetIsolateDataIndexes();                    
    env_info = NodeMainInstance::GetEnvSerializeInfo();                     
  }     
```
These functions are the ones that were generated by node_mksnapshot and
can be found in out/{BUILD_TYPE}/obj/gen/node_snapshot.cc:
```c++
static const int blob_size = 539943;                                            
static v8::StartupData blob = { blob_data, blob_size };                         
v8::StartupData* NodeMainInstance::GetEmbeddedSnapshotBlob() {                  
  return &blob;                                                                 
}

const EnvSerializeInfo* NodeMainInstance::GetEnvSerializeInfo() {               
  return &env_info;                                                             
}
```
Notice that the `Isolate::CreateParams` field `snapshot_blob` is set, and
after this we retrieve the indexes from NodeMainInstance. Now, this will be
from the generated node_snapshot.cc (in out/Debug/obj/gen/node_snapshot.cc)
which was generated by node_mksnapshot. The same goes for env_info.

After this a new NodeMainInstance will be created:
```c++
  NodeMainInstance main_instance(&params,                                         
                                 uv_default_loop(),                               
                                 per_process::v8_platform.Platform(),             
                                 result.args,                                     
                                 result.exec_args,                                
                                 indexes);
```
This brings us into `src/node_main_instance.cc` and the constructor that takes
indexes:
```c++
 if (deserialize_mode_) {                                                         
    const std::vector<intptr_t>& external_references = CollectExternalReferences();
    params->external_references = external_references.data();
  }                                                            
```
See [ExternalReferenceRegistry](#externalreferenceregistry) for details about
ExternalReferenceRegistry. Notice that we are setting the pointer on
`params` which will be passed to V8 later.

After this is done, a new Isolate will be allocated, registered with the
platform, and initialized.

Next we have the following call:
```c++
  SetIsolateCreateParamsForNode(params);
  Isolate::Initialize(isolate_, *params);
```
The last call will set the blob on the isolate (in src/api/api.cc):
```c++
  if (params.snapshot_blob != nullptr) {
    i_isolate->set_snapshot_blob(params.snapshot_blob);
  } else {
    i_isolate->set_snapshot_blob(i::Snapshot::DefaultSnapshotBlob());
  }
```
And a little further down we have:
```c++
  i_isolate->set_api_external_references(params.external_references);
```
And this is where we set the list of external references/addresses on the
isolate.
Next, `Isolate::Initialize` will call `StartupDeserializer::DeserializeInto`:
```c++
void StartupDeserializer::DeserializeInto(Isolate* isolate) {
  ...
  {
    isolate->heap()->IterateRoots(
        this,
        base::EnumSet<SkipRoot>{SkipRoot::kUnserializable, SkipRoot::kWeak});
}
```
```c++
void Heap::IterateRoots(RootVisitor* v, base::EnumSet<SkipRoot> options) {
  v->VisitRootPointers(Root::kStrongRootList, nullptr,
                       roots_table().strong_roots_begin(),
                       roots_table().strong_roots_end());
```
Now, `v` is of type `v8::internal::StartupDeserializer` which extends
`Deserializer` which implements `VisitRootPointers`:
```c++
void Deserializer::VisitRootPointers(Root root, const char* description,
                                     FullObjectSlot start, FullObjectSlot end) {
  ReadData(FullMaybeObjectSlot(start), FullMaybeObjectSlot(end), kNullAddress);
}
```
And  `ReadData` looks like this (also in deserializer.cc):
```c++
template <typename TSlot>
void Deserializer::ReadData(TSlot current, TSlot limit,
                            Address current_object_address) {
  while (current < limit) {
    byte data = source_.Get();
    current = ReadSingleBytecodeData(data, current, current_object_address);
  }
  CHECK_EQ(limit, current);
}
```
`source_` is what reads the snapshot (src/snapshot/snapshot-source-sink.h):
```c++
class SnapshotByteSource final {
 public:
  byte Get() {
    DCHECK(position_ < length_);
    return data_[position_++];
  }
 private:
  const byte* data_;
  int length_;
  int position_;
};
```
So we will get the next byte from the snapshot and then call
`ReadSingleBytecodeData`:
```c++
template <typename TSlot>
TSlot Deserializer::ReadSingleBytecodeData(byte data, TSlot current,
                                           Address current_object_address) {
  switch (data) {
    ...
    case kSandboxedApiReference:
    case kApiReference: {
      uint32_t reference_id = static_cast<uint32_t>(source_.GetInt());
      Address address;
      if (isolate()->api_external_references()) {
        DCHECK_WITH_MSG(reference_id < num_api_references_,
                        "too few external references provided through the API");
        address = static_cast<Address>(
            isolate()->api_external_references()[reference_id]);
      } else {
        address = reinterpret_cast<Address>(NoExternalReferencesCallback);
      }
      if (V8_HEAP_SANDBOX_BOOL && data == kSandboxedApiReference) {
        return WriteExternalPointer(current, address);
      } else {
        DCHECK(!V8_HEAP_SANDBOX_BOOL);
        return WriteAddress(current, address);
      }
    }
    ...
  }
```
`kApiReference` is an element of an enum defined in
src/snapshot/serializer-deserializer.h:
```c++
enum Bytecode : byte {                                                        
    // 0x00..0x03  Allocate new object, in specified space.                     
    kNewObject = 0x00,                                                          
    // Reference to previously allocated object.                                
    kBackref = 0x04,                                                            
    ...
    // Used to encode external references provided through the API.             
    kApiReference,                        
    ...

```
Just note that this case also allows kSandboxedApiReference to fall through so
you might expect `data` to match `kApiReference` but that might not always be
the case:
```console
(lldb) expr -f oct  -- this->Bytecode::kApiReference
(v8::internal::SerializerDeserializer::Bytecode) $12 = 037
(lldb) expr --format bin -- data
(v8::internal::byte) $26 = 0b01010000
(lldb) expr --format bin -- this->Bytecode::kSandboxedApiReference
(v8::internal::SerializerDeserializer::Bytecode) $27 = 0b00100001
```
Lets look at the content of this case and remove the debug checks:
```c++
    case kApiReference: {
      uint32_t reference_id = static_cast<uint32_t>(source_.GetInt());
      Address address;
      if (isolate()->api_external_references()) {
        address = static_cast<Address>(isolate()->api_external_references()[reference_id]);
      } else {
        address = reinterpret_cast<Address>(NoExternalReferencesCallback);
      }
      if (V8_HEAP_SANDBOX_BOOL && data == kSandboxedApiReference) {
        return WriteExternalPointer(current, address);
      } else {
        return WriteAddress(current, address);
      }
    }
```
Notice the first thing that happens is that an int is read from the `source_`
which is the reference id that should be used to lookup the reference in the
list of external references. This address will then be written to the `current`
position. So that is how external references are handled.

Next, a new IsolateData instance will be created:
```c++
  isolate_data_ = std::make_unique<IsolateData>(isolate_,                          
                                                event_loop,                        
                                                platform,                          
                                                array_buffer_allocator_.get(),  
                                                per_isolate_data_indexes);
```
IsolateData is of type `node::IsolateData` declared in src/env.h (not to be
confused with v8::internal::IsolateData). The members that are of interest to
us are the following:
```c++
class IsolateData : public MemoryRetainer {
 public:
    IsolateData(v8::Isolate* isolate,                                             
              uv_loop_t* event_loop,                                            
              MultiIsolatePlatform* platform = nullptr,                         
              ArrayBufferAllocator* node_allocator = nullptr,                   
              const std::vector<size_t>* indexes = nullptr);

 std::vector<size_t> Serialize(v8::SnapshotCreator* creator);
```
Notice that there is no field that stores `indexes`. If we look the definition
of the constructor above we see how this is used (in src/env.cc):
```c++
IsolateData::IsolateData(Isolate* isolate,
                         uv_loop_t* event_loop,
                         MultiIsolatePlatform* platform,
                         ArrayBufferAllocator* node_allocator,
                         const std::vector<size_t>* indexes)
    : isolate_(isolate), event_loop_(event_loop),
      node_allocator_(node_allocator == nullptr ? nullptr : node_allocator->GetImpl()),   
      platform_(platform) {                                                         
  options_.reset(new PerIsolateOptions(*(per_process::cli_options->per_isolate)));             
                                                                                    
  if (indexes == nullptr) {                                                         
    CreateProperties();                                                             
  } else {                                                                          
    DeserializeProperties(indexes);                                                 
  }                                                                                 
```
In our case `indexes` will not be null so we will be calling
`DeserializeProperties` which can be found in src/env.cc. This function uses
a macro and below is just showing a few of them expanded:
```c++
void IsolateData::DeserializeProperties(const std::vector<size_t>* indexes) {
  size_t i = 0;
  HandleScope handle_scope(isolate_);
  do {
    MaybeLocal<Private> field = isolate_->GetDataFromSnapshotOnce<Private>((*indexes)[i++]);
    if (field.IsEmpty()) {
      fprintf(stderr, "Failed to deserialize " "alpn_buffer_private_symbol" "\n");
    }
    alpn_buffer_private_symbol_.Set(isolate_, field.ToLocalChecked());
  } while (0);
  do {
    MaybeLocal<Private> field = isolate_->GetDataFromSnapshotOnce<Private>((*indexes)[i++]);
    if (field.IsEmpty()) {
      fprintf(stderr, "Failed to deserialize " "arrow_message_private_symbol" "\n");
    }
    arrow_message_private_symbol_.Set(isolate_, field.ToLocalChecked());
  } while (0);
   ...
}
```
What is happening here is that we are extracting data from the snapshot,
specifying the indexes that were returned when `AddData` was called, and
then populating External's. These are defined using macros in IsolateData:
```c++
#define VP(PropertyName, StringValue) V(v8::Private, PropertyName)
#define V(TypeName, PropertyName)                                              \
  inline v8::Local<TypeName> PropertyName() const;
  PER_ISOLATE_PRIVATE_SYMBOL_PROPERTIES(VP)
```
So for example arrow_message_private_symbol_ would be defined as:
```c++
v8::Eternal<v8::Private> arrow_message_private_symbol_;
```
Back in node.cc and `node::Start` after returning from NodeMainInstance constructor
we have:
```c++
  result.exit_code = main_instance.Run(env_info);
```
NodeMainInstance::Run will create a new Environment:
```c++
int NodeMainInstance::Run(const EnvSerializeInfo* env_info) {
  ...
  DeleteFnPtr<Environment, FreeEnvironment> env = CreateMainEnvironment(&exit_code, env_info);
}
```
And in CreateMainEnvironment we have the following:
```c++
  if (deserialize_mode_) {
    env.reset(new Environment(isolate_data_.get(),
                              isolate_,
                              args_,
                              exec_args_,
                              env_info,
                              EnvironmentFlags::kDefaultFlags,
                              {}));
    context = Context::FromSnapshot(isolate_,
                                    kNodeContextIndex,
                                    {DeserializeNodeInternalFields, env.get()})
                  .ToLocalChecked();

    InitializeContextRuntime(context);
    SetIsolateErrorHandlers(isolate_, {});
   }
   ...
   env->InitializeMainContext(context, env_info);
```
This time we are passing in a non-null `env_info` which was not the case when
we looked at node_mksnapshot. 
Next the context will be created from the snapshot and then `InitializeMainContext`
will be called.
```c++
void Environment::InitializeMainContext(Local<Context> context,
                                        const EnvSerializeInfo* env_info) {
  ...
  if (env_info != nullptr) {
    DeserializeProperties(env_info);
  } else {
    CreateProperties();
  }
  ...
```
In this case `env_info` will be non-null so `DeserializeProperties` will be called
which will read data from the isolate snapshot and the context snapshot to
populate the persistent tempalates and values.
```c++
void Environment::DeserializeProperties(const EnvSerializeInfo* info) {
  Local<Context> ctx = context();

  async_hooks_.Deserialize(ctx);
  immediate_info_.Deserialize(ctx);
  tick_info_.Deserialize(ctx);
  performance_state_->Deserialize(ctx);
  stream_base_state_.Deserialize(ctx);
  should_abort_on_uncaught_toggle_.Deserialize(ctx);

  ...
  MaybeLocal<Context> maybe_ctx_from_snapshot =
      ctx->GetDataFromSnapshotOnce<Context>(info->context);
  Local<Context> ctx_from_snapshot;
  if (!maybe_ctx_from_snapshot.ToLocal(&ctx_from_snapshot)) {
    fprintf(stderr,
            "Failed to deserialize context back reference from the snapshot\n");
  }
  CHECK_EQ(ctx_from_snapshot, ctx);
```
Lets take a look at one of these, `async_hooks_.Deserialize` and focus on 
`async_hooks_.async_ids_stack. Prior to calling the Derialize call this field
contains the following data:
```console
(node::AliasedBufferBase<double, v8::Float64Array>) $5 = {
  isolate_ = 0x0000000005db88e0
  count_ = 32
  byte_offset_ = 0
  buffer_ = 0x0000000000000000
  js_array_ = {
    v8::PersistentBase<v8::Float64Array> = (val_ = 0x0000000000000000)
  }
  index_ = 0x0000000005d415b8
}
```
Notice that the `buffer_` and `js_array_` fields are null. If we step-into
async_hooks_Deserialize we have:
```c++
void AsyncHooks::Deserialize(Local<Context> context) {
  async_ids_stack_.Deserialize(context);
  ...
```
And stepping into again will land us in aliased_buffer.h:
```c++
inline void Deserialize(v8::Local<v8::Context> context) {
  v8::Local<V8T> arr = context->GetDataFromSnapshotOnce<V8T>(*info_).ToLocalChecked();
  uint8_t* raw = static_cast<uint8_t*>(arr->Buffer()->GetBackingStore()->Data());
  buffer_ = reinterpret_cast<NativeT*>(raw + byte_offset_);
  js_array_.Reset(isolate_, arr);
  info_ = nullptr;
}
```
The way I've used GetDataFromSnapshotOnce was with a size_t type index to that
was retured when calling SnapshotCreator::AddData.
Notice that `info_` is of type `AliasedBufferInfo` which is a typedef:
```c++
  typedef size_t AliasedBufferInfo;
  const AliasedBufferInfo* info_ = nullptr;
```
This was a little surprising as I was expecting something like index. I've
created a PR with a suggestion to change this to AliasedBufferIndex and see if
other agree or not. 

So, we are using the "index" to retreive the data from the context snapshot,
then getting the BackingStore for the array and setting the `buffer_` field to
that value. Finally the js_array is reset to the array read from the snapshot:
```console
(node::AliasedBufferBase<double, v8::Float64Array>) $6 = {
  isolate_ = 0x0000000005db88e0
  count_ = 32
  byte_offset_ = 0
  buffer_ = 0x0000000005e414f0
  js_array_ = {
    v8::PersistentBase<v8::Float64Array> = (val_ = 0x0000000005e44060)
  }
  index_ = 0x0000000005d415b8
}
```

### BaseObject data
This section is going to look at the a work in progress which is about being
able to snapshot BaseObject data.

Notice that the following has been added to lib/internal/bootstrap/node.js:
```javascript
internalBinding('fs');
```
This will casue the native module fs to be initialized using GetInternalBindings
in node_binding.cc. This function calls InitModule  which will call the
initalizlier functions specified in node_file.cc.
```c++
void Initialize(Local<Object> target,
                Local<Value> unused,
                Local<Context> context,
                void* priv) {
  ...
  Environment* env = Environment::GetCurrent(context);
  Isolate* isolate = env->isolate();
  BindingData* const binding_data = env->AddBindingData<BindingData>(context, target);
```
What is `BindingData`?  
This is a class the extends BaseObject and is declared in node_file.h:
```c++
class BindingData : public BaseObject {
 public:
  AliasedFloat64Array stats_field_array;
  AliasedBigUint64Array stats_field_bigint_array;
```
So it looks like the two arrays that are members of BindingData hold file 
status stats (as in data like uv_stat_t).

And `AddBindingData` can be found in env-inl.h:
```c++
template <typename T>
inline T* Environment::AddBindingData(
    v8::Local<v8::Context> context,
    v8::Local<v8::Object> target) {
  DCHECK_EQ(GetCurrent(context), this);
  BaseObjectPtr<T> item = MakeDetachedBaseObject<T>(this, target);
  BindingDataStore* map = static_cast<BindingDataStore*>(
      context->GetAlignedPointerFromEmbedderData(
          ContextEmbedderIndex::kBindingListIndex));
  auto result = map->emplace(T::binding_data_name, item);
  return item.get();
```
AddBindingData will create a new BindingData instance and in the proceses call
BaseObject's constructor which will add an entry in the `cleanup_hooks_` map.
This is how/why we have an entry when we call Environment::Serialize later
(which we did not previously).

Next we get an object from the context using the
ContextEmbedderIndex::kBindingListIndex and note that `BindingDataStore` is
just an unordered_map:
```c++
  typedef std::unordered_map<
      FastStringKey,
      BaseObjectPtr<BaseObject>,
      FastStringKey::Hash> BindingDataStore;
```

If we take a look at tools/snapshot/snapshot_builder.cc we see that 
SerializeNodeContextInternalFields has been updated to contain the following
macro:
```c++
  switch (obj->type()) {
#define V(TypeName, NativeType)                                                \
  case InternalFieldType::k##TypeName: {                                       \
    NativeType* ptr = static_cast<NativeType*>(obj);                           \
    InternalFieldInfo* info = ptr->Serialize();                                \
    per_process::Debug(DebugCategory::MKSNAPSHOT,                              \
                       "Serializing " #NativeType "at %p, length=%d\n",        \
                       ptr,                                                    \
                       static_cast<int>(info->length));                        \
    return StartupData{reinterpret_cast<const char*>(info),                    \
                       static_cast<int>(info->length)};                        \
  }

    INTERNAL_FIELD_TYPES(V)
#undef V
    default: { UNREACHABLE(); }
```
The first thing to note is that every BaseObject has a InternalFieldType
associated with it. And we can find the types in INTERNAL_FIELD_TYPES:
```c++
#define INTERNAL_FIELD_TYPES(V)              \
  V(FSBindingData, fs::BindingData)
#undef V
```

We can expand the macro using:
```console
$ g++ -DNODE_WANT_INTERNALS=true -E -Ideps/uv/include -Ideps/v8/include -Isrc src/env.cc
```
```c++
switch (obj->type()) {                                                        
    case InternalFieldType::kFSBindingData: {
      fs::BindingData* ptr = static_cast<fs::BindingData*>(obj);
      InternalFieldInfo* info = ptr->Serialize();
      return StartupData{reinterpret_cast<const char*>(info), static_cast<int>(info->length)};
}
```
So this is casting to the concrete type of the BaseObject and then calling it's
`Serialize` function which is then added as StartupData to be stored in the
snapshot (details about this can be found ealier in this document).

`Environment::Serialize` has be updated with the following code:
```c++
  size_t i = 0;
  ForEachBaseObject([&](BaseObject* obj) {
    switch (obj->type()) {
      case InternalFieldType::kFSBindingData: {
        size_t index = creator->AddData(ctx, obj->object());
        info.bindings.push_back({"FSBindingData", i++, index});
        fs::BindingData* ptr = static_cast<fs::BindingData*>(obj);
        ptr->Serialize(ctx, creator);
        break;
      }
      default: { UNREACHABLE(); }
    }
  });
```
Notice that the closure is passed to `ForEachBaseObject` which will call it
for each BaseObject in cleanup_hooks_. Recall that we arrived here from
Environment::Serialialze and we are in the process of serializing this
BaseObject:
```console
(lldb) expr *obj
(node::BaseObject) $16 = {
  type_ = kFSBindingData
  persistent_handle_ = {
    v8::PersistentBase<v8::Object> = (val_ = 0x0000000005a89b00)
  }
  env_ = 0x0000000005a7f930
  pointer_data_ = 0x0000000005b34540
}
```
First this is we are going to add the v8::Global<v8::Object> persistent_handle_
to the snapshot context using `AddData`:
```console
(lldb) jlh obj->object()
0x218677edf831: [JS_API_OBJECT_TYPE]
 - map: 0x296d42c9aa51 <Map(HOLEY_ELEMENTS)> [DictionaryProperties]
 - prototype: 0x24367d204821 <Object map = 0x296d42c91b71>
 - elements: 0x1fd3c5ec1309 <FixedArray[0]> [HOLEY_ELEMENTS]
 - embedder fields: 2
 - properties: 0x218677ee0929 <NameDictionary[197]> {
   StatWatcher: 0x12df1ab22811 <JSFunction StatWatcher (sfi = 0x12df1ab227d1)> (data, dict_index: 40, attrs: [WEC])
   bigintStatValues: 0x218677edf941 <BigUint64Array map = 0x296d42c86b61> (data, dict_index: 39, attrs: [WEC])
   openFileHandle: 0x12df1ab20099 <JSFunction openFileHandle (sfi = 0x12df1ab20059)> (data, dict_index: 4, attrs: [WEC])
   statValues: 0x218677edf8a1 <Float64Array map = 0x296d42c868d9> (data, dict_index: 38, attrs: [WEC])
   fdatasync: 0x12df1ab203f1 <JSFunction fdatasync (sfi = 0x12df1ab203b1)> (data, dict_index: 7, attrs: [WEC])
   internalModuleReadJSON: 0x12df1ab20bc9 <JSFunction internalModuleReadJSON (sfi = 0x12df1ab20b89)> (data, dict_index: 14, attrs: [WEC])
   writeString: 0x12df1ab21841 <JSFunction writeString (sfi = 0x12df1ab21801)> (data, dict_index: 25, attrs: [WEC])
   fsync: 0x12df1ab20519 <JSFunction fsync (sfi = 0x12df1ab204d9)> (data, dict_index: 8, attrs: [WEC])
   close: 0x12df1ab1fe89 <JSFunction close (sfi = 0x12df1ab1fe49)> (data, dict_index: 2, attrs: [WEC])
   ...
```
Next, we have :
```c++
        info.bindings.push_back({"FSBindingData", i++, index});
        fs::BindingData* ptr = static_cast<fs::BindingData*>(obj);
        ptr->Serialize(ctx, creator);
```
`info` is of type EnvSerializeInfo which has a bindings field:
```c++
struct EnvSerializeInfo {
  std::vector<PropInfo> bindings;
```
So we are adding an entry to this vector. After that we cast `obj` from BaseObject
to `fs::BindingData` and call it's `Serialize` function which will land in
node_file.cc `BindingData::Serialize`:
```c++
void BindingData::Serialize(Local<Context> context, v8::SnapshotCreator* creator) {
  HandleScope scope(context->GetIsolate());
  object()->SetPrivate(context, env()->fs_stats_field_array_symbol(), stats_field_array.GetJSArray()).FromJust();
  stats_field_array.Release();

  object()->SetPrivate(context, env()->fs_stats_field_bigint_array_symbol(), stats_field_bigint_array.GetJSArray()).FromJust();
  stats_field_bigint_array.Release();
}
```
So this is setting Private properties on the peristent_handle, not that the
SnapshotCreator is not used. Also the arrays are released.
After that we are done and will break out of the iteration of all the baseobject.

In `Snapshot::NewContextFromSnapshot` we have the following call:
```c++
MaybeHandle<Context> Snapshot::NewContextFromSnapshot(
    Isolate* isolate, Handle<JSGlobalProxy> global_proxy, size_t context_index,
    v8::DeserializeEmbedderFieldsCallback embedder_fields_deserializer) {
  const v8::StartupData* blob = isolate->snapshot_blob();
  bool can_rehash = ExtractRehashability(blob);
  Vector<const byte> context_data = SnapshotImpl::ExtractContextData(
      blob, static_cast<uint32_t>(context_index));
  SnapshotData snapshot_data(MaybeDecompress(context_data));

  MaybeHandle<Context> maybe_result = ContextDeserializer::DeserializeContext(
      isolate, &snapshot_data, can_rehash, global_proxy,
      embedder_fields_deserializer);
  ...
}
```
`ContextDeserializer::DeserializeContext` will call:
```c++
MaybeHandle<Context> ContextDeserializer::DeserializeContext(
    Isolate* isolate, const SnapshotData* data, bool can_rehash,
    Handle<JSGlobalProxy> global_proxy,
    v8::DeserializeEmbedderFieldsCallback embedder_fields_deserializer) {
  ContextDeserializer d(data);
  d.SetRehashability(can_rehash);

  MaybeHandle<Object> maybe_result =
      d.Deserialize(isolate, global_proxy, embedder_fields_deserializer);
```
Which will call
```c++
MaybeHandle<Object> ContextDeserializer::Deserialize(
    Isolate* isolate, Handle<JSGlobalProxy> global_proxy,
    v8::DeserializeEmbedderFieldsCallback embedder_fields_deserializer) {
  Handle<Object> result;
  {
    ...
    DeserializeEmbedderFields(embedder_fields_deserializer);
    ...
}

void ContextDeserializer::DeserializeEmbedderFields(
    v8::DeserializeEmbedderFieldsCallback embedder_fields_deserializer) {
  ...
  for (int code = source()->Get(); code != kSynchronize; code = source()->Get()) {
    HandleScope scope(isolate());
    SnapshotSpace space = NewObject::Decode(code);
    Handle<JSObject> obj(JSObject::cast(GetBackReferencedObject(space)), isolate());
    int index = source()->GetInt();
    int size = source()->GetInt();
    byte* data = new byte[size];
    source()->CopyRaw(data, size);
    embedder_fields_deserializer.callback(v8::Utils::ToLocal(obj), index,
                                          {reinterpret_cast<char*>(data), size},
                                          embedder_fields_deserializer.data);
    delete[] data;
}
```
This will land in node_main_instance.cc in DeserializeNodeInternalFields.
```c++
void DeserializeNodeInternalFields(Local<Object> holder,
                                   int index,
                                   v8::StartupData payload,
                                   void* env) {
  ... 
  Environment* env_ptr = static_cast<Environment*>(env);
  const InternalFieldInfo* info =
      reinterpret_cast<const InternalFieldInfo*>(payload.data);

  switch (info->type) {
    case InternalFieldType::kFSBindingData: {
      env_ptr->EnqueueDeserializeRequest({fs::BindingData::Deserialize,
                                          {env_ptr->isolate(), holder},
                                          info->Copy()});
      break;
    }
    default: { UNREACHABLE(); }
  }
```
`EnqueueDeserializeRequest` does the following:
```c++
void Environment::EnqueueDeserializeRequest(DeserializeRequest request) {
  deserialize_requests_.push_back(std::move(request));
}
```
And this is a std::list 
```c++
  std::list<DeserializeRequest> deserialize_requests_;
```
```c++
struct DeserializeRequest {
  DeserializeRequestCallback cb;
  v8::Global<v8::Object> holder;
  InternalFieldInfo* info;  // Owned by the request
}

typedef void (*DeserializeRequestCallback)(v8::Local<v8::Context>,
                                           v8::Local<v8::Object> holder,
                                           InternalFieldInfo* info);
```
Later when Environment::InitializeMainContext is called, DeserializeProperties
will be called:
```c++
void Environment::DeserializeProperties(const EnvSerializeInfo* info) {
  Local<Context> ctx = context();

  RunDeserializeRequests();
```
```c++
void Environment::RunDeserializeRequests() {
  HandleScope scope(isolate());
  Local<Context> ctx = context();
  Isolate* is = isolate();
  while (!deserialize_requests_.empty()) {
    DeserializeRequest request(std::move(deserialize_requests_.front()));
    deserialize_requests_.pop_front();
    Local<Object> holder = request.holder.Get(is);
    request.cb(ctx, holder, request.info);
    request.holder.Reset();  // unnecessary?
    request.info->Delete();
  }
}
```
`request.cb` will land in node_file.cc BindingData::BindingData:
```c++
void BindingData::Deserialize(Local<Context> context,
                              Local<Object> holder,
                              InternalFieldInfo* info) {
  HandleScope scope(context->GetIsolate());
  Environment* env = Environment::GetCurrent(context);
  BindingData* binding = env->AddBindingData<BindingData>(context, holder);

  Local<Value> stats_arr = holder->GetPrivate(context, env->fs_stats_field_array_symbol())
                           .ToLocalChecked();
  binding->stats_field_array.Deserialize(stats_arr.As<Float64Array>());
```
Notice that we are now extracting the Private value that was added when
serializing, and the passing that to AliasedBufferBase::Deserialize in
aliased_buffer.h which will populate the binding...TODO:
