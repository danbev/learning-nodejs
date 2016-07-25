#include <iostream>
#include "gtest/gtest.h"
#include "v8.h"
#include "libplatform/libplatform.h"
#include "env.h"

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

TEST(Environment, env) {
  v8::Platform* platform = v8::platform::CreateDefaultPlatform();
  v8::V8::InitializePlatform(platform);
  v8::V8::Initialize();
  v8::Isolate::CreateParams params;
  ArrayBufferAllocator allocator;
  params.array_buffer_allocator = &allocator;
  v8::Isolate* isolate = v8::Isolate::New(params);
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
  EXPECT_EQ(true, ctx.IsEmpty()) << "Context should be empty";
}
