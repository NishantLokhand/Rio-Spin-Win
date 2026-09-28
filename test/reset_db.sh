#!/bin/bash
# Recreates the local test database with stub + migrations + seed + test users
set -e
P="psql -h /var/tmp/riopg -p 54322 -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = 'rio' and pid <> pg_backend_pid()" -c "drop database if exists rio" -c "create database rio"
for r in anon authenticated service_role authenticator; do $P -d postgres -c "drop role if exists $r" 2>/dev/null || true; done
cd "$(dirname "$0")/.."
$P -d rio -f test/local_supabase_stub.sql
for f in supabase/migrations/*.sql; do
  case "$f" in *storage*) continue;; esac
  $P -d rio -f "$f"
done
$P -d rio -f supabase/seed.sql
$P -d rio -f test/test_users.sql
echo "DB ready"
