#!/bin/sh
# Test fixture program of linuxpkg (https://github.com/pxgt/linuxpkg), Apache-2.0.
# It only prints its arguments. It exists so that the official abuild and makepkg
# have a program of ours to package: the packages they write are linuxpkg's test fixtures.
printf 'linuxpkg fixture: %s\n' "$*"
