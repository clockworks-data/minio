#!/bin/bash

if [ -n "$DEBUG" ]; then
    set -x
fi

pkill minio
rm -rf /tmp/xl

wget --quiet -O mc https://dl.minio.io/client/mc/release/linux-amd64/mc && \
    chmod +x mc

export CI=true
(minio server /tmp/xl/{1...10}/disk{0...1} 2>&1 >/dev/null)&
pid=$!

sleep 2

export MC_HOST_myminio="http://minioadmin:minioadmin@localhost:9000/"

./mc admin user add myminio/ minio123 minio123
./mc admin user add myminio/ minio12345 minio12345

./mc admin policy add myminio/ rw ./docs/distributed/rw.json
./mc admin policy add myminio/ lake ./docs/distributed/rw.json

./mc admin policy set myminio/ rw user=minio123
./mc admin policy set myminio/ lake,rw user=minio12345

./mc mb -l myminio/versioned
./mc mirror internal myminio/versioned/ --quiet >/dev/null

user_count=$(./mc admin user list myminio/ | wc -l)
policy_count=$(./mc admin policy list myminio/ | wc -l)

kill $pid
(minio server /tmp/xl/{1...10}/disk{0...1} /tmp/xl/{11...30}/disk{0...3} 2>&1 >/dev/null) &
pid=$!

sleep 2

expanded_user_count=$(./mc admin user list myminio/ | wc -l)
expanded_policy_count=$(./mc admin policy list myminio/ | wc -l)

if [ $user_count -ne $expanded_user_count ]; then
    echo "BUG: original user count differs from expanded setup"
    exit 1
fi

if [ $policy_count -ne $expanded_policy_count ]; then
    echo "BUG: original policy count  differs from expanded setup"
    exit 1
fi

./mc version info myminio/versioned | grep -q "versioning is enabled"
ret=$?
if [ $ret -ne 0 ]; then
    echo "expected versioning enabled after expansion"
    exit 1
fi

./mc mirror cmd myminio/versioned/ --quiet >/dev/null
./mc ls -r myminio/versioned/ > expanded_ns.txt

./mc admin decom start myminio/ /tmp/xl/{1...10}/disk{0...1}

until $(./mc admin decom status myminio/ | grep -q Complete)
do
    echo "waiting for decom to finish..."
    sleep 1
done

kill $pid

(minio server /tmp/xl/{11...30}/disk{0...3} 2>&1 >/dev/null)&
pid=$!

sleep 2

decom_user_count=$(./mc admin user list myminio/ | wc -l)
decom_policy_count=$(./mc admin policy list myminio/ | wc -l)

if [ $user_count -ne $decom_user_count ]; then
    echo "BUG: original user count differs after decommission"
    exit 1
fi

if [ $policy_count -ne $decom_policy_count ]; then
    echo "BUG: original policy count differs after decommission"
    exit 1
fi

./mc version info myminio/versioned | grep -q "versioning is enabled"
ret=$?
if [ $ret -ne 0 ]; then
    echo "BUG: expected versioning enabled after decommission"
    exit 1
fi

./mc ls -r myminio/versioned > decommissioned_ns.txt

out=$(diff -qpruN expanded_ns.txt decommissioned_ns.txt)
ret=$?
if [ $ret -ne 0 ]; then
    echo "BUG: expected no missing entries after decommission: $out"
fi

kill $pid
