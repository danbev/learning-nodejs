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

### gyp configuration notes

Within a variables section, keys named with percent sign (%) suffixes mean that the variable should be set 
only if it is undefined at the time it is processed.

