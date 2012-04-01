#!/bin/bash

mobundle -I lib -PB bin/sets \
   -m App::Sets \
   -m App::Sets::Parser \
   -m App::Sets::Iterator \
   -m Log::Log4perl::Tiny \
   > sets
chmod +x sets
