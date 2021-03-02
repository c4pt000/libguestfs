```
git clone https://github.com/c4pt000/libguestfs
git submodule update --init
sudo dnf builddep libguestfs
sudo dnf install autoconf automake libtool gettext-devel
CFLAGS=-fPIC ./autogen.sh
make -j24
cp /usr/bin/virt-sparsify /usr/bin/virt-sparsify.orig
cp virt-sparsify /usr/bin/virt-sparsify
```
