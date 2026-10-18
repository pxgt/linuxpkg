#!/bin/sh
# Leave a marker so that tests can see that the script ran.
mkdir -p /var/lib/hello
echo installed > /var/lib/hello/state
exit 0
