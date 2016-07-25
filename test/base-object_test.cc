//#define NODE_WANT_INTERNALS 1
#include <iostream>
#include "gtest/gtest.h"
#include "v8.h"
#include "base-object.h"
#include "base-object-inl.h"

TEST(BaseObject, baseObject) {
  v8::Local<v8::Object> o;
  std::cout << "object: " << *o << std::endl;
  // TODO: Add some tests
  //node::BaseObject bo {nullptr, o};
}
