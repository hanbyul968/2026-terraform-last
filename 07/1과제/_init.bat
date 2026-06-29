@echo off
cd /d "C:\Users\competitor\2026-terraform\07\1과제\main"
terraform init -backend=false -input=false -no-color > init.log 2>&1
terraform validate -no-color > validate.log 2>&1
cd /d "C:\Users\competitor\2026-terraform\07\1과제\bootstrap"
terraform init -backend=false -input=false -no-color > init.log 2>&1
terraform validate -no-color > validate.log 2>&1
echo DONE > "C:\Users\competitor\2026-terraform\07\1과제\_init.done"
