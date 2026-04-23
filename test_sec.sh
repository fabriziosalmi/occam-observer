#!/bin/bash
sec_count="0
0"
echo "Before: '$sec_count'"
sec_count="$(echo "$sec_count" | tail -1)"
echo "After tail -1: '$sec_count'"
