#include <iostream>
#include "gtest/gtest.h"
#include "v8.h"
#include "libplatform/libplatform.h"
#include "base-object.h"
#include "base-object-inl.h"

#ifndef ARRAY_BUFFER_ALLOCATOR_
#define ARRAY_BUFFER_ALLOCATOR_
class ArrayBufferAllocator : public v8::ArrayBuffer::Allocator {
  public:
    virtual void* Allocate(size_t length) {
      void* data = AllocateUninitialized(length);
      return data == NULL ? data : memset(data, 0, length);
    }
    virtual void* AllocateUninitialized(size_t length) {
      return malloc(length);
    }
    virtual void Free(void* data, size_t) {
      free(data);
    }
};
#endif

/**
 * The goal of this test is simply to learn about 
 * the BaseObject type.
 */
TEST(BaseObject, baseObject) {
  v8::Platform* platform = v8::platform::CreateDefaultPlatform();
  v8::V8::InitializePlatform(platform);
  v8::V8::Initialize();
  v8::Isolate::CreateParams params;
  ArrayBufferAllocator allocator;
  params.array_buffer_allocator = &allocator;
  v8::Isolate* isolate = v8::Isolate::New(params);
  v8::Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handle_scope(isolate);
  v8::Local<v8::Context> context = v8::Context::New(isolate);
  v8::Context::Scope context_scope(context);
  uv_loop_t* event_loop = uv_default_loop();
  node::IsolateData* isolateData = new node::IsolateData(isolate, event_loop);
  node::Environment* env = new node::Environment(isolateData, context);
  v8::Local<v8::String> handle = v8::String::NewFromUtf8(isolate, "testing", v8::NewStringType::kNormal).ToLocalChecked();
  v8::Local<v8::Object> obj = v8::Local<v8::Object>::Cast(handle);
  node::BaseObject bo {env, obj};
  EXPECT_EQ(false, bo.persistent().IsEmpty());
  bo.persistent().Reset();
}
