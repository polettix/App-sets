#!/bin/bash

version=$(git tag | tail -1 | sed 's/^v//')

V=$version dzil build

(
   cd "App-Sets-$version"
   mobundle -I lib -PB bin/sets \
      -m App::Sets \
      -m App::Sets::Parser \
      -m App::Sets::Iterator \
      -m App::Sets::Operations \
      -m App::Sets::Sort \
      -m Log::Log4perl::Tiny
) > sets
chmod +x sets

dzil clean
