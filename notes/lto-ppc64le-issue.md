## Node.js PPC64LE LTO issue
This issue happens on RHEL 8.5 ppc64le using gcc:
```console
$ . /opt/rh/gcc-toolset-11/enable
$ export CC=ccache gcc
$ export CXX=ccache g++
```
And only when Node's build is configured for Link Time Optimizations:
```console
$ configure --enable-lto
$ make -j $JOBS test
```

Logs from a CI [run](https://ci.nodejs.org/job/node-test-commit-linux-lto/23/nodes=rhel8-ppc64le/console):
```console
21:52:27 [ RUN      ] DebugSymbolsTest.ReqWrapList
21:52:27 ../test/cctest/test_node_postmortem_metadata.cc:203: Failure
21:52:27 Expected equality of these values:
21:52:27   expected
21:52:27     Which is: 140736537072320
21:52:27   calculated
21:52:27     Which is: 1099680328560
21:52:27 [  FAILED  ] DebugSymbolsTest.ReqWrapList (43 ms)
```

### Running the test
```console
$ ./out/Debug/cctest --gtest_filter=DebugSymbolsTest.ReqWrapList
```

### Debugging the test
lldb:
```console
$ lldb -- ./out/Debug/cctest --gtest_filter=DebugSymbolsTest.ReqWrapList
(lldb) br s -f test_node_postmortem_metadata.cc -l 171
(lldb) r
```

gdb:
```console
$ gdb --args ./out/Release/cctest --gtest_filter=DebugSymbolsTest.ReqWrapList
(gdb) br test_node_postmortem_metadata.cc:203
(gdb) r
```

### Troubleshooting

```console
(lldb) target variable  nodedbg_offset_ListNode_ReqWrap__next___uintptr_t
(uintptr_t) nodedbg_offset_ListNode_ReqWrap__next___uintptr_t = 8

(lldb) image lookup -s nodedbg_offset_ListNode_ReqWrap__next___uintptr_t
1 symbols match 'nodedbg_offset_ListNode_ReqWrap__next___uintptr_t' in /home/danielbevenius/work/nodejs/node-debug/out/Debug/cctest:
        Address: cctest[0x000000000606ea58] (cctest.PT_LOAD[4]..bss + 29912)
        Summary: cctest`nodedbg_offset_ListNode_ReqWrap__next___uintptr_t
```

```c++
  v8::Local<v8::Object> object = obj_template->GetFunction(env.context())          
                                     .ToLocalChecked()                             
                                     ->NewInstance(env.context())                  
                                     .ToLocalChecked();                            
  TestReqWrap obj(*env, object);                                                   
                                                                                   
  // NOTE (mmarchini): Workaround to fix failing tests on ARM64 machines with   
  // older GCC. Should be removed once we upgrade the GCC version used on our   
  // ARM64 CI machinies.                                                           
  for (auto it : *(*env)->req_wrap_queue()) (void) &it;                            
                                                                                   
  auto last = tail + nodedbg_offset_ListNode_ReqWrap__next___uintptr_t;         
  last = *reinterpret_cast<uintptr_t*>(last);                                   
                                                                                
  auto expected = reinterpret_cast<uintptr_t>(&obj);                            
  auto calculated =                                                             
      last - nodedbg_offset_ReqWrap__req_wrap_queue___ListNode_ReqWrapQueue;       
  EXPECT_EQ(expected, calculated);
```

In `src/node_postmortem_metadata.cc` we have:
```c++
extern "C" {                                                                    
  ...
  uintptr_t nodedbg_offset_ReqWrap__req_wrap_queue___ListNode_ReqWrapQueue;       
  ...
}
```
So the type of this is bacially a void pointer which is initialized by the
function GenDebugSymbols:
```c++
int GenDebugSymbols() {                                                         
 ...
  nodedbg_offset_ReqWrap__req_wrap_queue___ListNode_ReqWrapQueue =              
      OffsetOf<ListNode<ReqWrapBase>, ReqWrap<uv_req_t>>(                         
          &ReqWrap<uv_req_t>::req_wrap_queue_);                                 
  ...
  return 1;                                                                        
}                                                                                  
                                                                                   
const int debug_symbols_generated = GenDebugSymbols();                             
```
This is getting the offset of the pointer-to-member 
`&ReqWrap<uv_req_t>::req_wrap_queue_` which is a private field in ReqWrapBase:
```c++
class ReqWrapBase {                                                             
 public:                                                                        
  explicit inline ReqWrapBase(Environment* env);                                
                                                                                
  virtual ~ReqWrapBase() = default;                                             
                                                                                
  virtual void Cancel() = 0;                                                    
  virtual AsyncWrap* GetAsyncWrap() = 0;                                        
                                                                                
 private:                                                                       
  friend int GenDebugSymbols();                                                 
  friend class Environment;                                                     
                                                                                
  ListNode<ReqWrapBase> req_wrap_queue_;                                        
};

template <typename T>                                                           
class ReqWrap : public AsyncWrap, public ReqWrapBase {                          
 public:
  ...
 private:
  friend int GenDebugSymbols();

 public:
  typedef void (*callback_t)();
  callback_t original_callback_ = nullptr;

 protected:                                                                     
  // req_wrap_queue_ needs to be at a fixed offset from the start of the class  
  // because it is used by ContainerOf to calculate the address of the embedding
  // ReqWrap. ContainerOf compiles down to simple, fixed pointer arithmetic. It 
  // is also used by src/node_postmortem_metadata.cc to calculate offsets and   
  // generate debug symbols for ReqWrap, which assumes that the position of     
  // members in memory are predictable. sizeof(req_) depends on the type of T,  
  // so req_wrap_queue_ would no longer be at a fixed offset if it came after   
  // req_. For more information please refer to                                 
  // `doc/contributing/node-postmortem-support.md`                              
  T req_;                                                                       
};                       
```
Lets take a look at the value of
`nodedbg_offset_ListNode_ReqWrap__next___uintptr_t` on my local machine:
```console
(lldb) expr nodedbg_offset_ListNode_ReqWrap__next___uintptr_t
(uintptr_t) $11 = 8
```
So this is saying that the req_wrap_queue_ is a offset 8 from the start of the
ReqWrap, which I think makes sense as the only other field is a function
pointer, `callback_t` which would by 8 bytes just like any pointer:
```console
(lldb) expr sizeof(void*)
(unsigned long) $12 = 8
```
So we have this pointer to a member which can be used to point an actual
implementation.

Stepping back up a little in the testcase we have:
```c++
auto queue = reinterpret_cast<uintptr_t>((*env)->req_wrap_queue());
```
```console
(lldb) expr  env
(EnvironmentTestFixture::Env) $14 = {
  context_ = (val_ = 0x0000000006131e00)
  isolate_data_ = 0x00000000060f9d30
  environment_ = 0x00007ffff50598f0
}

(lldb) expr reinterpret_cast<uintptr_t>((*env)->req_wrap_queue())
(uintptr_t) $17 = 140737304175080
```
So that is the address of the ReqWrapQueue which is a typedef:
```c++
  typedef ListHead<ReqWrapBase, &ReqWrapBase::req_wrap_queue_> ReqWrapQueue;
  inline ReqWrapQueue* req_wrap_queue() { return &req_wrap_queue_; }
```
So `queue` will be a pointer to the env req_wrap_queue, so we have a pointer
to this List.

Next, a variable named `head` is created:
```c++
  auto head =                                                                   
      queue +                                                                   
      nodedbg_offset_Environment_ReqWrapQueue__head___ListNode_ReqWrapQueue;
```
So here we take the pointer queue which is 140737304175080 and add to it:
```console
(lldb) expr nodedbg_offset_Environment_ReqWrapQueue__head___ListNode_ReqWrapQueue
(uintptr_t) $20 = 0
```
So head in this case will be 140737304175080 (unchanged and still pointing to
the List, so pointing to the start/head of the list):
```console
(lldb) expr head
(unsigned long) $25 = 140737304175080
```

Next, we have the variable `tail`:
```c++
  auto tail = head + nodedbg_offset_ListNode_ReqWrap__prev___uintptr_t;         
```
```console
(gdb) p nodedbg_offset_ListNode_ReqWrap__prev___uintptr_t
$12 = 0

(lldb) expr tail
(unsigned long) $32 = 140737304175080
```
So at this stage both head and tail are pointing to the same value.

```c++
  tail = *reinterpret_cast<uintptr_t*>(tail);                          
```
And after the reinterpret_cast:
```console
lldb) expr tail
(unsigned long) $33 = 140737304175080
```

Next we are taking the value of tail
```c++
  auto last = tail + nodedbg_offset_ListNode_ReqWrap__next___uintptr_t;         
```
```console
lldb) expr tail
(unsigned long) $33 = 140737304175080
(lldb) expr nodedbg_offset_ListNode_ReqWrap__next___uintptr_t
(uintptr_t) $38 = 8

(lldb) expr tail + nodedbg_offset_ListNode_ReqWrap__next___uintptr_t
(unsigned long) $39 = 140737304175088

lldb) expr tail
(unsigned long) $40 = 140737304175088
```

This `last` is then reassigned to point to the dereferenced 
```c++
  last = *reinterpret_cast<uintptr_t*>(last); 
```
```console
(lldb) memory read -fx -s 8 -c 1 last
0x7ffff505a1f0: 0x00007fffffffd0a0
```
And after the reinterpret_cast last will point to:
```console
(lldb) memory read -fx -s 8 -c 1 last
0x7fffffffd0a0: 0x00007ffff505a1e8
```

```c++
   auto expected = reinterpret_cast<uintptr_t>(&obj);                            
   auto calculated =                                                             
       last - nodedbg_offset_ReqWrap__req_wrap_queue___ListNode_ReqWrapQueue;
```
`expected` is a pointer to the TestReqWrap instance created earlier, and
'calculated` is taking the pointer to `last` and then recasting that, then
dereferencing it which is now a pointer to the member `req_` and which we know
from above is at offset 8. This value is then subtracted to get the pointer to
the instance holding `req_` which is expected to be the same, that is the
TestReqWrap instance we created ealier.

But this is what happends ppc64le:
```console
../test/cctest/test_node_postmortem_metadata.cc:203: Failure
Expected equality of these values:
  expected
    Which is: 140737488346192
  calculated
    Which is: 353276184
```
The calculated value look way off in this case. Locally this would be pointing
to the same value since we are trying to peek at the last entry in the queue.
The values for `queue`, `head`, `tail`, and `last` are optimized out for a 
Release build which also happens locally, but the test does not fail. It only
seems to fail on PPC64LE.

Hmm, I've added print statements:
```console
queue: 0x1002fd1d8a8
head: 0x1002fd1d8a8
tail: 0x1002fd1d8a8
tast before cast:: 0x1002fd1d8a8
tast: 0x1002fd1d8a8

expected:: 0x7fffce7d9d50
calculated:: 0x7fffce7d9d50
```
And noticed that this allows the test to pass. So there is something that is
causing these values to be incorrect when compiling with LTO. How about if we
try to prevent the compiler from tampering with these values. For example by
making the variables volatile:
```console
diff --git a/test/cctest/test_node_postmortem_metadata.cc b/test/cctest/test_node_postmortem_metadata.cc
index 4cee7db4c8..d35e71f7f8 100644
--- a/test/cctest/test_node_postmortem_metadata.cc
+++ b/test/cctest/test_node_postmortem_metadata.cc
@@ -172,11 +172,11 @@ TEST_F(DebugSymbolsTest, ReqWrapList) {
   const Argv argv;
   Env env{handle_scope, argv};
 
-  auto queue = reinterpret_cast<uintptr_t>((*env)->req_wrap_queue());
-  auto head =
+  volatile uintptr_t queue = reinterpret_cast<uintptr_t>((*env)->req_wrap_queue());
+  volatile uintptr_t head =
       queue +
       nodedbg_offset_Environment_ReqWrapQueue__head___ListNode_ReqWrapQueue;
-  auto tail = head + nodedbg_offset_ListNode_ReqWrap__prev___uintptr_t;
+  volatile uintptr_t tail = head + nodedbg_offset_ListNode_ReqWrap__prev___uintptr_t;
   tail = *reinterpret_cast<uintptr_t*>(tail);
 
   auto obj_template = v8::FunctionTemplate::New(isolate_);
@@ -194,11 +194,11 @@ TEST_F(DebugSymbolsTest, ReqWrapList) {
   // ARM64 CI machinies.
   for (auto it : *(*env)->req_wrap_queue()) (void) &it;
 
-  auto last = tail + nodedbg_offset_ListNode_ReqWrap__next___uintptr_t;
+  volatile uintptr_t last = tail + nodedbg_offset_ListNode_ReqWrap__next___uintptr_t;
   last = *reinterpret_cast<uintptr_t*>(last);
 
-  auto expected = reinterpret_cast<uintptr_t>(&obj);
-  auto calculated =
+  volatile uintptr_t expected = reinterpret_cast<uintptr_t>(&obj);
+  volatile uintptr_t calculated =
       last - nodedbg_offset_ReqWrap__req_wrap_queue___ListNode_ReqWrapQueue;
   EXPECT_EQ(expected, calculated);

``
Using this patch I was able to get the test to pass.
