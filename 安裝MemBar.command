#!/bin/bash
cd "$(dirname "$0")"
bash ./build.sh 2>&1 | tee install.log
echo
echo "可以關閉這個視窗了。"
