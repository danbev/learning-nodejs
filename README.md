### Learning Node.js
The sole purpose of this project is to aid in learning Node.js internals.

## Prerequisites
You'll need to have checked out the node.js source.

### Compiling node with debug enbled:

    $ ./configure --debug
    $ make -C out BUILDTYPE=Debug
   
After compiling (with debugging enabled) start node using lldb:

    $ cd node/out/Debug
    $ lldb node

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


#### PlatformInit()
From what I understand this mainly sets up things like signals and file descriptor limits.

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
...
Local<FunctionTemplate> process_template = FunctionTemplate::New(isolate);
process_template->SetClassName(FIXED_ONE_BYTE_STRING(isolate, "process"));
...
SetupProcessObject(env, argc, argv, exec_argc, exec_argv);

This looks like the node process object is being created here. 
All the JavaScript built-in objects are provided by the V8 runtime but the process object is not one of them. So here we are doing the same as in the hello-world example above but naming the object 'process'

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



2943   READONLY_PROPERTY(process,
2944                     "moduleLoadList",
2945                     env->module_load_list_array());
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

After setting up all the object (SetupProcessObject) this methods returns. There is still no sign of the loading of the 'node.js' script. This is done in LoadEnvironment.

#### LoadEnvironment(

Local<String> script_name = FIXED_ONE_BYTE_STRING(env->isolate(), "node.js");

#### lib/internal/bootstrap_node.js
This is the file that is loaded by LoadEnvironment as "node.js". The name node.js is also what you can see in the debugger. This is executed aswell.
I read that this file is actually precompiled, where/how?
This file is referenced in node.gyp and is used with the target node_js2c. This target calls tools/js2c.py which is a tool for converting JavaScript source code into C-Style char arrays. This target will process all the library_files specified in the variables section which lib/internal/bootstrap_node.js is one of. The output of this out/Debug/obj/gen/node_natives.h, depending on the type of build being performed. So lib/internal/bootstrap_node.js will beccome internal_bootstrap_node_native in node_natives.h. 
This is then later included in src/node_javascript.cc 
We can see the contents of this in lldb using:

    (lldb) p internal_bootstrap_node_native

#### Generate Your Project (gyp)
https://gyp.gsrc.io/


Notes:
When Node.js starts up it does many things similar to what we did in our hello-world
example. After intializing the Platform it need to inject objects, for example the
'process' object. V8 brings the complete JavaScript engine and environement with all
the builtin objects, but Node.js is more than that. All the additional functionality 
that Node.js brings (https://nodejs.org/docs/latest/api/index.html) are also available.


