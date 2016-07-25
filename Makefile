NODE_HOME ?= /Users/danielbevenius/work/nodejs/node
node_build_dir = $(NODE_HOME)/out/Debug
node_include_dir = $(NODE_HOME)/src
v8_build_dir = $(node_build_dir)
v8_include_dir = $(NODE_HOME)/deps/v8/include
cares_include_dir = $(NODE_HOME)/deps/cares/include

v8_libs = $(v8_build_dir)/libv8_base.a $(v8_build_dir)/libv8_libbase.a $(v8_build_dir)/libv8_snapshot.a $(v8_build_dir)/libv8_libplatform.a $(v8_build_dir)/libicuucx.a $(v8_build_dir)/libicui18n.a 

check: test/base-object_test 
	./test/base-object_test

test/base-object_test: test/base-object_test.cc
	$ clang++ -std=c++0x -stdlib=libstdc++ -O0 -g -I`pwd`/deps/googletest/googletest/include -I$(node_include_dir) -I$(cares_include_dir) -I$(v8_include_dir) $(v8_libs) -pthread test/main.cc lib/libgtest.a -o test/base-object_test

.PHONY: clean

clean: 
	rm -rf test/base-object_test
