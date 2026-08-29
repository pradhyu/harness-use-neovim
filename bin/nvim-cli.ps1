#!/usr/bin/env pwsh
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
nvim -l "$scriptDir\nvim-cli.lua" @args
