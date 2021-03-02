```
git clone https://github.com/c4pt000/libguestfs
cd libguestfs
git submodule update --init
sudo dnf builddep libguestfs -y
sudo dnf install autoconf automake libtool gettext-devel -y
CFLAGS=-fPIC ./autogen.sh
make -j24
cp /usr/bin/virt-sparsify /usr/bin/virt-sparsify.orig
cp virt-sparsify /usr/bin/virt-sparsify
```
