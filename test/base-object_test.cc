#include "gtest/gtest.h"
#include "v8.h"

#define NODE_WANT_INTERNALS 1

#include "base-object.h"
#include "base-object-inl.h"

TEST(BaseObject, baseObject) {
  v8::Local<v8::Object> o;
  node::BaseObject bo {nullptr, o};
}
