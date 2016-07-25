NODE_HOME ?= /Users/danielbevenius/work/nodejs/node
node_build_dir = $(NODE_HOME)/out/Debug
node_include_dir = $(NODE_HOME)/src
v8_build_dir = $(node_build_dir)
v8_include_dir = $(NODE_HOME)/deps/v8/include
cares_include_dir = $(NODE_HOME)/deps/cares/include
gtest_dont_defines = -D GTEST_DONT_DEFINE_ASSERT_EQ -D GTEST_DONT_DEFINE_ASSERT_NE -D GTEST_DONT_DEFINE_ASSERT_LE -D GTEST_DONT_DEFINE_ASSERT_LT -D GTEST_DONT_DEFINE_ASSERT_GE -D GTEST_DONT_DEFINE_ASSERT_GT

v8_libs = $(v8_build_dir)/libv8_base.a $(v8_build_dir)/libv8_libbase.a $(v8_build_dir)/libv8_snapshot.a $(v8_build_dir)/libv8_libplatform.a $(v8_build_dir)/libicuucx.a $(v8_build_dir)/libicui18n.a $(v8_build_dir)/libicudata.a $(v8_build_dir)/libicustubdata.a

node_cc = c++ -std=gnu++0x -stdlib=libstdc++ -D_DARWIN_USE_64_BIT_INODE=1 -DNODE_PLATFORM="darwin" -DNODE_WANT_INTERNALS=1 -DV8_DEPRECATION_WARNINGS=1 -DNODE_USE_V8_PLATFORM=1 -DNODE_HAVE_I18N_SUPPORT=1 -DNODE_HAVE_SMALL_ICU=1 -DHAVE_INSPECTOR=1 -DV8_INSPECTOR_USE_STL=1 -DHAVE_OPENSSL=1 -DHAVE_DTRACE=1 -D__POSIX__ -DNODE_PLATFORM="darwin" -DUCONFIG_NO_TRANSLITERATION=1 -DUCONFIG_NO_SERVICE=1 -DUCONFIG_NO_REGULAR_EXPRESSIONS=1 -DU_ENABLE_DYLOAD=0 -DU_STATIC_IMPLEMENTATION=1 -DU_HAVE_STD_STRING=0 -DUCONFIG_NO_BREAK_ITERATION=0 -DUCONFIG_NO_LEGACY_CONVERSION=1 -DUCONFIG_NO_CONVERSION=1 -DHTTP_PARSER_STRICT=0 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -DDEBUG -D_DEBUG -O0 -gdwarf-2 -mmacosx-version-min=10.7 -arch x86_64 -Wall -Wendif-labels -W -Wno-unused-parameter -fno-rtti -fno-exceptions -fno-threadsafe-statics -fno-strict-aliasing -I`pwd`/deps/googletest/googletest/include -I$(node_include_dir) -I$(cares_include_dir) -I$(v8_include_dir) $(v8_libs) -pthread test/main.cc lib/libgtest.a $(gtest_dont_defines) 

check: test/base-object_test test/environment_test
	./test/base-object_test

test/base-object_test: test/base-object_test.cc
	$ $(node_cc) -o test/base-object_test

test/environment_test: test/environment_test.cc
	$ $(node_cc) -o test/environment_test

.PHONY: clean

clean: 
	rm -rf test/base-object_test
	rm -rf test/environment_test
