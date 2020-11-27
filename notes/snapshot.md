### Node snapshot
This document contains notes about Node's usage of V8 snapshots

### node_snapshot executable
This is an executable that is run as part of Node's build. The result of running
this is a generated C++ source file that by default can be found in
`out/Release/obj/gen/node_snapshot.cc`. This will then be compiled with the
rest of Node at a later stage in the build process.

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
ExternalReferenceRegistry constructor will call all the registered external
references (see ExternalReferenceRegistry for details about this). These are
functions that exist in Node that need to be registered as external so that
when the object being serialized does not store the address to the function
but instead an index into this array. After the snapshot has been created it
will be stored on disk and the snapshot blob cannot contains the function
addresses as they will most probably change when loaded into another processs.

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
SnapshotCreator is a class in V8 which takes a pointer to external references
and is declared in v8.h.
After this a NodeMainInstance will be created:
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
Notice the call to IsolateData::Serialize (src/env.cc). This fuction has uses
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
using Isolate::GetDataFromSnapshotOnce.


So far we have collected addresses to functions that are external to V8 and
added them all to a vector. These will then be passed to the SnapshotCreator
constructor making them available when it serialized the Isolate/Context.
 
Some more details and some exploration code can be found here:
https://github.com/danbev/learning-v8/blob/master/notes/snapshots.md#snapshot-usage

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
So that is the declaration, and to see the the implementation we have to look
in src/async_wrap.cc:
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
registered, for example `SetupHooks` is of type v8::FunctionCallback (its a
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
`src/aliased_buffer.h` has a typedef AliasedBufferInfo:
```c++
typedef size_t AliasedBufferInfo; 
```
So async_ids_stack, fields, and async_id_fields are just unsigned integers.
Likewise `SnapshotIndex` is also a typedef:
```c++
typedef size_t SnapshotIndex;
```

### Snapshot usage during startup
When node starts it will check if the is a startup blob (StartupData) available
when calling `NodeMainInstance::GetEmbeddedSnapshotBlob` (in src/node.cc):
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
This function is the one that was generated by node_mksnapshot:
```c++
static const int blob_size = 539943;                                            
static v8::StartupData blob = { blob_data, blob_size };                         
v8::StartupData* NodeMainInstance::GetEmbeddedSnapshotBlob() {                  
  return &blob;                                                                 
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
This brings us into `src/node_main_instance.cc`and the constructor that takes
indexes:
```c++
 if (deserialize_mode_) {                                                         
    const std::vector<intptr_t>& external_references =                             
        CollectExternalReferences();                                               
    params->external_references = external_references.data();                      
  }                                                            
```
See [ExternalReferenceRegistry](#externalreferenceregistry) for details about
ExternalReferenceRegistry.

After this is done, a new Isolate will be allocated, registered with the
platform, and initialized.
Next, a new IsolateData instance will be created:
```c++
  isolate_data_ = std::make_unique<IsolateData>(isolate_,                          
                                                event_loop,                        
                                                platform,                          
                                                array_buffer_allocator_.get(),  
                                                per_isolate_data_indexes);
```
IsolateData is of type node::IsolateData declared in src/evn.h (not to be
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
In our case we will be calling `DeserializeProperties` which can be found in
src/env.cc:
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
What is happening here is that we are extracting data from the snapshot and
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

