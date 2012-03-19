#!/bin/bash

mobundle -I lib -PB bin/sets -m App::sets -m Log::Log4perl::Tiny > sets
chmod +x sets
