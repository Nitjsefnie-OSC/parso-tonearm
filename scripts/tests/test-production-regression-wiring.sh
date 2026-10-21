#!/usr/bin/env bash
# Proves CI/worker validation runs the production harness and that CLAUDE.md names the real command.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
grep -q 'run-production-regression.sh' scripts/ci-validate.sh
grep -q '^tonearm-production-regression:' Makefile
grep -q 'make tonearm-production-regression' CLAUDE.md
grep -q 'TonearmProductionRegressionTests' scripts/run-production-regression.sh
# a production-path test and a visual-screen test must both exist
grep -q 'testQueueActionsReachPlayerAdapter' Tests/ProductionRegression/ProductionRegressionTests.swift
grep -q 'testQueueRenderMatchesBaseline' Tests/ProductionRegression/ProductionRegressionTests.swift
ls Tests/ProductionRegression/Baselines/queue-initial.txt >/dev/null
echo 'production regression harness is wired into validation'
