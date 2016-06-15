## Generate your project (gyp)
Just an example to understand how gyp works.


### Install gyp

    git clone https://chromium.googlesource.com/external/gyp.git
    cd gyp
    sudo python setup.py install

### Building
Generate the make file

    $ gyp example.gyp --depth=. -f make --generator-output=./build/makefiles

Make:

    $ make -C ./build/makefiles

### Running

    $ $ ./build/makefiles/out/Default/example

