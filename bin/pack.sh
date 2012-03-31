#!/bin/bash

mobundle -I lib -PB bin/sets -m App::Sets -m Log::Log4perl::Tiny > sets
chmod +x sets
