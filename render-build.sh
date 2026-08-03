#!/usr/bin/env bash
set -o errexit

apt-get update
apt-get install -y libproj-dev proj-bin

bundle install
bundle exec rails assets:precompile
bundle exec rake assets:clean