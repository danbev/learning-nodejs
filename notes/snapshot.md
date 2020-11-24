### Node snapshot
This document contains notes about Node's usage of V8 snapshots

### node_snapshot
```console
$ lldb -- ./out/Debug/node_mksnapshot out/Debug/obj/gen/node_snapshot.cc
(lldb) settings set target.env-vars NODE_DEBUG_NATIVE=mksnapshot
(lldb) br s -n main
```
For a snapshot to be created `SnapshotBuilder::Generate` will create a new
V8 runtime (Isolate, Platform etc). After the Isolate has been registered
with the v8 platform a vector of external references will be colleted by 
the following call:
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
references (see ExternalReferenceRegistry for details about this).

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

